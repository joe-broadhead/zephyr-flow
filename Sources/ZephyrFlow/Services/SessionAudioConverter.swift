import AVFoundation
import Foundation
import ZephyrFlowCore

/// Exactly-one consumer-side PCM conversion (JOE-2247). A session owns one
/// `SessionAudioConverter`; it converts each owned `AudioChunk` to 16 kHz
/// mono float for the selected engine. Not Sendable: used from the single
/// delivery task only.
final class SessionAudioConverter {
    static let targetSampleRate: Double = 16_000

    private var converter: AVAudioConverter?
    private var lastFormatKey: String?

    /// Convert a chunk into 16 kHz mono float samples.
    func convert(_ chunk: AudioChunk) -> [Float]? {
        let sourceKey = "\(chunk.sampleRate)/\(chunk.channelCount)"
        if lastFormatKey != sourceKey || converter == nil {
            guard
                let source = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: chunk.sampleRate,
                    channels: AVAudioChannelCount(chunk.channelCount),
                    interleaved: false),
                let target = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: Self.targetSampleRate,
                    channels: 1,
                    interleaved: false),
                let newConverter = AVAudioConverter(from: source, to: target)
            else {
                return nil
            }
            converter = newConverter
            lastFormatKey = sourceKey
        }
        guard let converter, chunk.channelCount > 0, !chunk.samples.isEmpty else {
            return nil
        }

        // Wrap the owned mono-most samples as an AVAudioPCMBuffer.
        let channels = Int32(chunk.channelCount)
        let frames = chunk.samples.count / Int(max(channels, 1))
        guard frames > 0,
            let source = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: chunk.sampleRate,
                channels: AVAudioChannelCount(chunk.channelCount),
                interleaved: false),
            let inBuf = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(frames))
        else {
            return nil
        }
        inBuf.frameLength = AVAudioFrameCount(frames)
        // Fill each channel from the flat samples. A mono chunk
        // (channelCount == 1, the AudioCapture producer contract) is a
        // contiguous first-channel array; no striding is needed. Multichannel
        // chunks use the strided planar view.
        if chunk.channelCount == 1 {
            guard let data = inBuf.floatChannelData?[0] else { return nil }
            for i in 0..<frames {
                data[i] = chunk.samples[i]
            }
        } else {
            for ch in 0..<chunk.channelCount {
                guard let data = inBuf.floatChannelData?[Int(ch)] else { continue }
                for i in 0..<frames {
                    data[i] = chunk.samples[i * chunk.channelCount + ch]
                }
            }
        }

        let ratio = Self.targetSampleRate / chunk.sampleRate
        let capacity = AVAudioFrameCount(Double(frames) * ratio) + 32
        guard
            let outBuf = AVAudioPCMBuffer(
                pcmFormat: AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: Self.targetSampleRate,
                    channels: 1,
                    interleaved: false)!,
                frameCapacity: capacity)
        else { return nil }

        var error: NSError?
        let input = ConverterInput(buffer: inBuf)
        let status = converter.convert(to: outBuf, error: &error) { _, outStatus in
            input.nextBuffer(status: outStatus)
        }
        guard status != .error, outBuf.frameLength > 0,
            let channel = outBuf.floatChannelData?[0]
        else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(outBuf.frameLength)))
    }

    /// Review REQ-6: drain any buffered tail the AVAudioConverter holds at
    /// end-of-stream (resampling can buffer partial output across chunks).
    /// Call ONCE after the final chunk; returns the residual 16 kHz mono
    /// samples (possibly empty). Round-5 NIT 8: drains REPEATEDLY until the
    /// converter reports end-of-stream/no-data (a fixed single-capacity call
    /// could leave buffered output behind), with a bounded iteration/sample
    /// budget so a misbehaving converter cannot loop forever.
    func flush() -> [Float] {
        guard let converter else { return [] }
        let capacity = AVAudioFrameCount(4096)
        guard
            let fmt = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Self.targetSampleRate,
                channels: 1,
                interleaved: false)
        else { return [] }
        var all: [Float] = []
        var iterations = 0
        let maxIterations = 64
        while iterations < maxIterations {
            iterations += 1
            guard
                let outBuf = AVAudioPCMBuffer(
                    pcmFormat: fmt, frameCapacity: capacity)
            else { break }
            var error: NSError?
            let status = converter.convert(to: outBuf, error: &error) { _, outStatus in
                // Round-6 NIT 2: tell the converter this is the final call so
                // it drains buffered output and reports end-of-stream in its
                // RETURN status (observed below).
                outStatus.pointee = .endOfStream
                return nil
            }
            if status == .error {
                break
            }
            // A short or end-of-stream output buffer can contain the final
            // samples. Account for it BEFORE interpreting terminal status.
            // Short output alone is not evidence that the converter is drained.
            if outBuf.frameLength > 0, let channel = outBuf.floatChannelData?[0] {
                all.append(
                    contentsOf: UnsafeBufferPointer(
                        start: channel, count: Int(outBuf.frameLength)))
            }
            if status == .endOfStream || outBuf.frameLength == 0 { break }
        }
        return all
    }
}

/// A narrowly scoped bridge for AVAudioConverter's Sendable input callback.
/// The application never mutates the PCM after handing it to this object.
/// The lock guards one-time delivery to the native converter; the application
/// neither reads nor mutates the handed-off buffer from another task/thread.
private final class ConverterInput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: AVAudioPCMBuffer?

    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func nextBuffer(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.withLock {
            guard let buffer else {
                status.pointee = .noDataNow
                return nil
            }
            self.buffer = nil
            status.pointee = .haveData
            return buffer
        }
    }
}
