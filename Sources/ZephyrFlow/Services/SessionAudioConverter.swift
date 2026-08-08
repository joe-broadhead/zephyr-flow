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
        // fill each channel from a strided view of the flat samples
        for ch in 0..<chunk.channelCount {
            guard let data = inBuf.floatChannelData?[Int(ch)] else { continue }
            for i in 0..<frames {
                data[i] = chunk.samples[i * chunk.channelCount + ch]
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
        var consumed = false
        let status = converter.convert(to: outBuf, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inBuf
        }
        guard status != .error, outBuf.frameLength > 0,
            let channel = outBuf.floatChannelData?[0]
        else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(outBuf.frameLength)))
    }
}
