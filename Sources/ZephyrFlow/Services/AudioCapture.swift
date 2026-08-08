import Foundation
import AVFoundation
import Accelerate
import ZephyrFlowCore

/// Mutable producer sequence state owned by the tap callout thread only.
/// Isolated in a small box so the real-time path never touches actor state.
final class AudioProducerState: @unchecked Sendable {
    var sequence: UInt64 = 0
    var startSample: UInt64 = 0
    var overflowLogged = false
}

actor AudioCapture: AudioCaptureProtocol {
    static let shared = AudioCapture()

    private(set) var isCapturing = false

    private var engine: AVAudioEngine?
    private var channel: BoundedAudioChannel?
    private var sessionID: SessionID?
    private var producerState: AudioProducerState?
    private var latestLevels: [Float] = Array(repeating: 0.05, count: 24)
    private var peakRMS: Float = 0

    func levels() async -> [Float] { latestLevels }

    /// Diagnostics from the current/last capture session (JOE-2247).
    func captureStats() async -> (enqueued: UInt64, overflowDropped: UInt64, wrongSessionRejected: UInt64, peakRMS: Float) {
        let st = channel?.stats()
        return (st?.enqueued ?? 0, st?.overflowDropped ?? 0, st?.wrongSessionRejected ?? 0, peakRMS)
    }

    func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    }

    func start(sessionID: SessionID, channel: BoundedAudioChannel) async throws {
        if isCapturing {
            await stop()
        }

        let granted = await requestPermission()
        guard granted else { throw AudioCaptureError.permissionDenied }

        let engine = AVAudioEngine()
        let input = engine.inputNode

        // Resolve hardware format. Prefer outputFormat (post-graph); fall back to inputFormat.
        let outputFormat = input.outputFormat(forBus: 0)
        let inputFormat = input.inputFormat(forBus: 0)
        let format: AVAudioFormat
        if outputFormat.sampleRate > 0, outputFormat.channelCount > 0 {
            format = outputFormat
        } else if inputFormat.sampleRate > 0, inputFormat.channelCount > 0 {
            format = inputFormat
        } else {
            throw AudioCaptureError.noInputDevice
        }

        ZFLog.info(
            "AudioCapture start sr=\(format.sampleRate) ch=\(format.channelCount) common=\(format.commonFormat.rawValue)"
        )

        // No conversion here: the producer only own-copies raw PCM into the
        // bounded channel. Conversion happens in the exactly-one consumer in
        // delivery order (JOE-2247), keeping this path real-time cheap.
        self.channel = channel
        self.sessionID = sessionID
        self.engine = engine
        self.producerState = AudioProducerState()
        self.peakRMS = 0

        let bufferSize: AVAudioFrameCount = 4096
        let sessionID = sessionID
        let boundChannel = channel
        let producer = producerState

        input.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
            // AVAudioEngine reuses the tap buffer after this callback returns:
            // deep-copy first (owned samples), then enqueue the chunk. The
            // enqueue is lock-guarded and bounded; the callback never blocks
            // on engine/inference scheduling.
            guard let copy = Self.copyPCMBuffer(buffer) else { return }
            guard let self else { return }
            // Real-time safe: push owned samples into the bounded ring with NO
            // actor hop, then a Task hop only for level polling.
            if let producer {
                let seq = producer.sequence
                let start = producer.startSample
                producer.sequence &+= 1
                producer.startSample += UInt64(copy.frameLength)
                let chunk = AudioChunk(sessionID: sessionID, sequence: seq, startSample: start,
                                       sampleRate: copy.format.sampleRate,
                                       channelCount: Int(copy.format.channelCount),
                                       samples: Self.makeFloatArray(copy))
                if boundChannel.enqueue(chunk) != .accepted, !producer.overflowLogged {
                    producer.overflowLogged = true
                    ZFLog.info("AudioCapture channel non-enqueue (overflow/cross-session) — degraded")
                }
            }
            Task { await self.noteLevels(copy) }
        }

        engine.prepare()
        do {
            try engine.start()
            isCapturing = true
        } catch {
            input.removeTap(onBus: 0)
            self.engine = nil
            self.channel = nil
            self.sessionID = nil
            self.producerState = nil
            throw AudioCaptureError.engineStartFailed(error.localizedDescription)
        }
    }

    func stop() async {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning {
                engine.stop()
            }
        }
        engine = nil
        // Closing the channel ends the consumer stream exactly once; any
        // late producer attempt is counted, never delivered.
        channel?.close()
        channel = nil
        sessionID = nil
        producerState = nil
        isCapturing = false
        latestLevels = Array(repeating: 0.05, count: 24)
    }

    // MARK: - Private

    /// Deep-copy tap PCM so the audio thread can recycle the original buffer.
    nonisolated private static func copyPCMBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength

        let channels = Int(buffer.format.channelCount)

        if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            for ch in 0..<channels {
                memcpy(dst[ch], src[ch], frames * MemoryLayout<Float>.size)
            }
            return copy
        }

        if let src = buffer.int16ChannelData, let dst = copy.int16ChannelData {
            for ch in 0..<channels {
                memcpy(dst[ch], src[ch], frames * MemoryLayout<Int16>.size)
            }
            return copy
        }

        if let src = buffer.int32ChannelData, let dst = copy.int32ChannelData {
            for ch in 0..<channels {
                memcpy(dst[ch], src[ch], frames * MemoryLayout<Int32>.size)
            }
            return copy
        }

        // Interleaved / uncommon layouts: copy each AudioBuffer's bytes.
        let srcList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList)
        )
        let dstList = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for i in 0..<min(srcList.count, dstList.count) {
            guard let srcData = srcList[i].mData, let dstData = dstList[i].mData else { continue }
            let bytes = Int(srcList[i].mDataByteSize)
            guard bytes > 0 else { continue }
            memcpy(dstData, srcData, bytes)
            dstList[i].mDataByteSize = srcList[i].mDataByteSize
        }
        return copy
    }

    /// Level metering from the owned raw copy (first channel downmix); the
    /// UI meter never touches payload buffers beyond summary statistics.
    private func noteLevels(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        let samples = Self.makeFloatArray(buffer)
        guard !samples.isEmpty else { return }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        if rms > peakRMS { peakRMS = rms }
        let level = min(1.0, max(0.03, rms * 8))
        var next = latestLevels
        next.removeFirst()
        next.append(level)
        latestLevels = next
    }

    /// Copy a tap buffer into a flat mono float array (downmix by first
    /// channel for the meter / engine path).
    static func makeFloatArray(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return [] }
        if let ch = buffer.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: ch, count: frames))
        }
        if let ch = buffer.int16ChannelData?[0] {
            var out = [Float](repeating: 0, count: frames)
            for i in 0..<frames { out[i] = Float(ch[i]) / 32768.0 }
            return out
        }
        if let ch = buffer.int32ChannelData?[0] {
            var out = [Float](repeating: 0, count: frames)
            for i in 0..<frames { out[i] = Float(ch[i]) / 2147483648.0 }
            return out
        }
        return []
    }

}
