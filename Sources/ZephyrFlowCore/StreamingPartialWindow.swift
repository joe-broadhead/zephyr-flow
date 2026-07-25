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

    /// Finalize waits for the in-flight partial via the engine single-flight gate
    /// (not a fixed short timeout — concurrent decode is unsafe).

    public static func canRunPartial(sampleCount: Int) -> Bool {
        sampleCount >= minPartialSamples
    }

    /// Most recent `windowSamples` (or all samples if shorter).
    public static func sliceForPartial(_ samples: [Float]) -> [Float] {
        guard samples.count > windowSamples else { return samples }
        return Array(samples.suffix(windowSamples))
    }
}
