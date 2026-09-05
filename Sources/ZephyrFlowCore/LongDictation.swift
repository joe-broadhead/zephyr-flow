import Foundation

/// Human-selected policy (JOE-2251): bounded chunking, ten-minute maximum.
/// These constants define the implementation target, not device qualification.
public enum LongDictationPolicy {
    public static let maximumSeconds = 600
    public static let sampleRate = 16_000
    public static let maximumSamples = maximumSeconds * sampleRate
    public static let chunkSamples = 30 * sampleRate
    public static let overlapSamples = 2 * sampleRate
}

/// Append-only blocks preserve the beginning of the recording. The rolling
/// partial window is a copy of the tail, never the authoritative final buffer.
/// Retained PCM is bounded at 38.4 MB (decimal) plus array/block overhead and
/// temporary windows; native model/decode memory is additional and unqualified.
public struct LongDictationAudioBuffer: Sendable {
    private var blocks: [[Float]] = []
    private let maximumSamples: Int
    private let blockSamples: Int
    public private(set) var sampleCount = 0
    public private(set) var rejectedSamples: UInt64 = 0
    public var reachedLimit: Bool { sampleCount == maximumSamples }

    public init(maximumSamples: Int = LongDictationPolicy.maximumSamples, blockSamples: Int = 16_000) {
        precondition(maximumSamples > 0 && maximumSamples <= LongDictationPolicy.maximumSamples)
        precondition(blockSamples > 0 && blockSamples <= LongDictationPolicy.chunkSamples)
        self.maximumSamples = maximumSamples
        self.blockSamples = blockSamples
    }

    /// Returns admitted samples. Excess is counted, never silently substituted
    /// for the oldest audio. Callers must surface/stop at the product limit.
    @discardableResult
    public mutating func append(_ samples: [Float]) -> Int {
        let accepted = min(samples.count, maximumSamples - sampleCount)
        let (sum, overflow) = rejectedSamples.addingReportingOverflow(UInt64(samples.count - accepted))
        rejectedSamples = overflow ? .max : sum
        var offset = 0
        while offset < accepted {
            if blocks.isEmpty || blocks[blocks.count - 1].count == blockSamples { blocks.append([]) }
            let index = blocks.count - 1
            let count = min(blockSamples - blocks[index].count, accepted - offset)
            blocks[index].append(contentsOf: samples[offset..<(offset + count)])
            offset += count
        }
        sampleCount += accepted
        return accepted
    }

    /// Materializes only the requested window; finalization must process one
    /// chunk at a time rather than flattening the entire ten-minute recording.
    public func samples(in range: Range<Int>) -> [Float]? {
        guard range.lowerBound >= 0, range.upperBound <= sampleCount else { return nil }
        var output: [Float] = []
        output.reserveCapacity(range.count)
        var offset = range.lowerBound
        while offset < range.upperBound {
            let block = offset / blockSamples
            let index = offset % blockSamples
            let count = min(blocks[block].count - index, range.upperBound - offset)
            output.append(contentsOf: blocks[block][index..<(index + count)])
            offset += count
        }
        return output
    }

    public func recentSamples(maximum: Int = StreamingPartialWindow.windowSamples) -> [Float] {
        guard maximum > 0 else { return [] }
        return samples(in: max(0, sampleCount - maximum)..<sampleCount) ?? []
    }
}

public enum FinalDecodeChunkPlan {
    /// Half-open ranges in the original 16 kHz recording. Adjacent windows
    /// overlap exactly; their union is the complete admitted sample range.
    public static func ranges(sampleCount: Int) -> [Range<Int>]? {
        guard sampleCount >= 0, sampleCount <= LongDictationPolicy.maximumSamples else { return nil }
        guard sampleCount > 0 else { return [] }
        var result: [Range<Int>] = []
        var start = 0
        while start < sampleCount {
            let end = min(sampleCount, start + LongDictationPolicy.chunkSamples)
            result.append(start..<end)
            if end == sampleCount { break }
            start = end - LongDictationPolicy.overlapSamples
        }
        return result
    }
}

/// Word timing is sample-based and local to the decoded window. It remains a
/// model hypothesis, not proof of semantic correctness. Conversion from native
/// floating timestamps must reject NaN/infinite/negative/out-of-window values.
public struct ChunkWordTiming: Sendable, Equatable {
    public let text: String
    public let samples: Range<Int>
    public init(text: String, samples: Range<Int>) {
        self.text = text
        self.samples = samples
    }
}

public struct DecodedAudioChunk: Sendable {
    public let samples: Range<Int>
    public let text: String
    /// nil means missing alignment; it must not be mistaken for silent audio.
    public let words: [ChunkWordTiming]?
    public init(samples: Range<Int>, text: String, words: [ChunkWordTiming]?) {
        self.samples = samples
        self.text = text
        self.words = words
    }
}

public enum ChunkStitchOutcome: Sendable, Equatable {
    case stitched(String)
    case incomplete(String, reason: String)
}

/// Conservative deterministic stitching: overlap words must match one-to-one
/// in text and sample timing. Ambiguous repetition, missing alignment, range
/// gaps or conflicting hypotheses preserve all chunk texts as an explicitly
/// incomplete result. Never delete words using suffix/prefix text matching alone.
public enum LongDictationStitcher {
    // Alignment tolerance is algorithmic, not a qualified accuracy budget.
    public static let timingToleranceSamples = LongDictationPolicy.sampleRate / 4

    public static func stitch(_ chunks: [DecodedAudioChunk], expectedSampleCount: Int) -> ChunkStitchOutcome {
        let fallback = chunks.map(\.text).joined(separator: "\n\n")
        func incomplete(_ reason: String) -> ChunkStitchOutcome { .incomplete(fallback, reason: reason) }
        guard let plan = FinalDecodeChunkPlan.ranges(sampleCount: expectedSampleCount), !plan.isEmpty,
            chunks.map(\.samples) == plan
        else { return incomplete("chunk coverage incomplete") }
        // A single window needs no seam operation; actual decoder completeness
        // must still be checked by the caller, including silence/failure cases.
        if chunks.count == 1 { return .stitched(chunks[0].text) }
        var merged: [ChunkWordTiming] = []
        var previousEnd = 0
        for chunk in chunks {
            guard let words = chunk.words else { return incomplete("word alignment missing") }
            let normalizedText = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedWords = words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizedText.utf8.elementsEqual(normalizedWords.utf8) else {
                return incomplete("alignment text mismatch")
            }
            var lastEnd = 0
            for word in words {
                guard !word.text.isEmpty, word.samples.lowerBound >= lastEnd,
                    word.samples.lowerBound >= 0, !word.samples.isEmpty, word.samples.upperBound <= chunk.samples.count
                else {
                    return incomplete("word timing invalid")
                }
                lastEnd = word.samples.upperBound
            }
            let absolute = words.map { word in
                ChunkWordTiming(
                    text: word.text,
                    samples: (word.samples.lowerBound + chunk.samples.lowerBound)..<(word.samples.upperBound
                        + chunk.samples.lowerBound))
            }
            if merged.isEmpty && previousEnd == 0 {
                merged = absolute
                previousEnd = chunk.samples.upperBound
                continue
            }
            let left = merged.filter { $0.samples.upperBound > chunk.samples.lowerBound }
            let right = absolute.filter { $0.samples.lowerBound < previousEnd }
            guard !left.isEmpty, !right.isEmpty else { return incomplete("overlap alignment anchor missing") }
            guard left.count == right.count else { return incomplete("overlap word count differs") }
            for (index, word) in left.enumerated() {
                let matches = right.indices.filter { candidate in
                    sameWord(word, right[candidate])
                }
                guard matches == [index] else { return incomplete("overlap alignment ambiguous") }
            }
            merged.append(contentsOf: absolute.dropFirst(right.count))
            previousEnd = chunk.samples.upperBound
        }
        return .stitched(merged.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func sameWord(_ left: ChunkWordTiming, _ right: ChunkWordTiming) -> Bool {
        left.text.trimmingCharacters(in: .whitespacesAndNewlines).utf8.elementsEqual(
            right.text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
            && abs(left.samples.lowerBound - right.samples.lowerBound) <= timingToleranceSamples
            && abs(left.samples.upperBound - right.samples.upperBound) <= timingToleranceSamples
    }
}
