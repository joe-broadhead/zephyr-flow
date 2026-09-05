import Foundation
import WhisperKit
import ZephyrFlowCore

struct WhisperRuntimeConfiguration: Sendable {
    let model: ModelIdentifier
    let verifiedFolder: String?
    let allowDownload: Bool
}

typealias WhisperRuntimeFactory =
    @Sendable (WhisperRuntimeConfiguration) async throws -> any WhisperTranscriptionRuntime

struct WhisperChunkTranscript: Sendable {
    let text: String
    let words: [ChunkWordTiming]?
}

protocol WhisperTranscriptionRuntime: Sendable {
    func transcribe(samples: [Float], options: DecodingOptions) async throws -> String
    func transcribeChunk(samples: [Float], options: DecodingOptions) async throws -> WhisperChunkTranscript
}

extension WhisperTranscriptionRuntime {
    func transcribeChunk(samples: [Float], options: DecodingOptions) async throws -> WhisperChunkTranscript {
        // String-only fixtures have no alignment; never fabricate timing.
        WhisperChunkTranscript(text: try await transcribe(samples: samples, options: options), words: nil)
    }
}

/// Non-Sendable backend ownership is transferred to one runtime. It is never
/// exposed to the engine actor or used outside the runtime after transfer.
protocol WhisperTranscriptionBackend: AnyObject {
    func transcribe(samples: [Float], options: DecodingOptions) async throws -> String
    func transcribeChunk(samples: [Float], options: DecodingOptions) async throws -> WhisperChunkTranscript
}

extension WhisperTranscriptionBackend {
    func transcribeChunk(samples: [Float], options: DecodingOptions) async throws -> WhisperChunkTranscript {
        WhisperChunkTranscript(text: try await transcribe(samples: samples, options: options), words: nil)
    }
}

/// The SDK pipeline is not Sendable. This owner admits exactly one native call
/// at a time, holds no lock over an await, and releases admission only when the
/// native call actually returns (not when its caller times out or cancels).
final class WhisperKitRuntime: WhisperTranscriptionRuntime, @unchecked Sendable {
    private let backend: any WhisperTranscriptionBackend
    private let lock = NSLock()
    private var transcribing = false

    init(backend: any WhisperTranscriptionBackend) { self.backend = backend }

    static func load(_ configuration: WhisperRuntimeConfiguration) async throws -> any WhisperTranscriptionRuntime {
        if let folder = configuration.verifiedFolder {
            let tokenizerFolder = URL(fileURLWithPath: folder).appendingPathComponent("tokenizer", isDirectory: true)
            let tokenizer = try LocalWhisperTokenizer.load(from: tokenizerFolder, model: configuration.model)
            let pipeline = try await LocalTokenizerWhisperKit(
                folder: folder, model: configuration.model, tokenizer: tokenizer)
            try await pipeline.prewarmModels()
            try await pipeline.loadModels()
            return WhisperKitRuntime(backend: NativeWhisperBackend(pipeline))
        }
        // This legacy acquisition-only path may fetch model/tokenizer files
        // under explicit download consent. It is never a local-only fallback.
        guard configuration.allowDownload else {
            throw WhisperEngineError.modelLoadFailed("A verified local artifact is required before loading.")
        }
        let pipeline = try await WhisperKit(
            model: configuration.model.rawValue,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: configuration.allowDownload)
        return WhisperKitRuntime(backend: NativeWhisperBackend(pipeline))
    }

    func transcribe(samples: [Float], options: DecodingOptions) async throws -> String {
        try admit()
        defer { lock.withLock { transcribing = false } }
        return try await backend.transcribe(samples: samples, options: options)
    }

    func transcribeChunk(samples: [Float], options: DecodingOptions) async throws -> WhisperChunkTranscript {
        try admit()
        defer { lock.withLock { transcribing = false } }
        return try await backend.transcribeChunk(samples: samples, options: options)
    }

    private func admit() throws {
        let admitted = lock.withLock {
            guard !transcribing else { return false }
            transcribing = true
            return true
        }
        guard admitted else { throw WhisperEngineError.decodeBusy }
    }
}

private final class NativeWhisperBackend: WhisperTranscriptionBackend {
    private let pipeline: WhisperKit

    init(_ pipeline: WhisperKit) { self.pipeline = pipeline }

    func transcribe(samples: [Float], options: DecodingOptions) async throws -> String {
        let results = try await pipeline.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ")
    }

    func transcribeChunk(samples: [Float], options: DecodingOptions) async throws -> WhisperChunkTranscript {
        let results = try await pipeline.transcribe(audioArray: samples, decodeOptions: options)
        return WhisperChunkAlignment.snapshot(
            text: results.map(\.text).joined(separator: " "),
            segments: results.flatMap(\.segments), sampleCount: samples.count)
    }
}

/// Copies value-only alignment out of the native results while runtime
/// ownership is held. Native allocation/IPC bounds are not established here.
enum WhisperChunkAlignment {
    static func snapshot(text: String, segments: [TranscriptionSegment], sampleCount: Int) -> WhisperChunkTranscript {
        guard sampleCount > 0, sampleCount <= LongDictationPolicy.chunkSamples,
            !segments.isEmpty, segments.allSatisfy({ $0.words != nil })
        else {
            return WhisperChunkTranscript(text: text, words: nil)
        }
        var words: [ChunkWordTiming] = []
        for segment in segments {
            for word in segment.words ?? [] {
                let start = Double(word.start) * Double(LongDictationPolicy.sampleRate)
                let end = Double(word.end) * Double(LongDictationPolicy.sampleRate)
                guard start.isFinite, end.isFinite, start >= 0, end > start, end <= Double(sampleCount),
                    !word.word.isEmpty, words.count < 8_192
                else {
                    return WhisperChunkTranscript(text: text, words: nil)
                }
                let lower = Int(start.rounded(.down))
                let upper = Int(end.rounded(.up))
                guard lower >= (words.last?.samples.upperBound ?? 0), upper <= sampleCount else {
                    return WhisperChunkTranscript(text: text, words: nil)
                }
                words.append(ChunkWordTiming(text: word.word, samples: lower..<upper))
            }
        }
        return WhisperChunkTranscript(text: text, words: words)
    }
}
