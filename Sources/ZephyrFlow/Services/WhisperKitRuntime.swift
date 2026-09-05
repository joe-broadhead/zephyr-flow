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

protocol WhisperTranscriptionRuntime: Sendable {
    func transcribe(samples: [Float], options: DecodingOptions) async throws -> String
}

/// Non-Sendable backend ownership is transferred to one runtime. It is never
/// exposed to the engine actor or used outside the runtime after transfer.
protocol WhisperTranscriptionBackend: AnyObject {
    func transcribe(samples: [Float], options: DecodingOptions) async throws -> String
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
        let tokenizerFolder = configuration.verifiedFolder.map {
            URL(fileURLWithPath: $0).appendingPathComponent("tokenizer", isDirectory: true)
        }
        // These are model-download controls. The dependency's tokenizer
        // fallback requires separate offline-load enforcement; do not claim
        // download:false by itself proves an offline tokenizer initialization.
        let pipeline = try await WhisperKit(
            model: configuration.model.rawValue,
            modelFolder: configuration.verifiedFolder,
            tokenizerFolder: tokenizerFolder,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: configuration.verifiedFolder == nil && configuration.allowDownload)
        return WhisperKitRuntime(backend: NativeWhisperBackend(pipeline))
    }

    func transcribe(samples: [Float], options: DecodingOptions) async throws -> String {
        let admitted = lock.withLock {
            guard !transcribing else { return false }
            transcribing = true
            return true
        }
        guard admitted else { throw WhisperEngineError.decodeBusy }
        defer { lock.withLock { transcribing = false } }
        return try await backend.transcribe(samples: samples, options: options)
    }
}

private final class NativeWhisperBackend: WhisperTranscriptionBackend {
    private let pipeline: WhisperKit

    init(_ pipeline: WhisperKit) { self.pipeline = pipeline }

    func transcribe(samples: [Float], options: DecodingOptions) async throws -> String {
        let results = try await pipeline.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ")
    }
}
