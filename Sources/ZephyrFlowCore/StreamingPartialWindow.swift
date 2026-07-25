import Foundation

/// Pure policy for rolling-window progressive decode (Whisper path).
/// Kept in Core so it is unit-testable without WhisperKit / AppKit.
public enum StreamingPartialWindow: Sendable {
    /// Product sample rate for Whisper PCM (Hz).
    public static let sampleRate = 16_000

    /// Minimum audio before attempting a partial (~1 s).
    public static let minPartialSamples = sampleRate

    /// Rolling window length for partials (~15 s).
    public static let windowSamples = sampleRate * 15

    /// Spacing between partial attempts.
    public static let intervalNanoseconds: UInt64 = 1_200_000_000

    /// How long finalize will wait for an in-flight partial decode to finish.
    public static let finalizeWaitNanoseconds: UInt64 = 3_000_000_000

    public static func canRunPartial(sampleCount: Int) -> Bool {
        sampleCount >= minPartialSamples
    }

    /// Most recent `windowSamples` (or all samples if shorter).
    public static func sliceForPartial(_ samples: [Float]) -> [Float] {
        guard samples.count > windowSamples else { return samples }
        return Array(samples.suffix(windowSamples))
    }
}
