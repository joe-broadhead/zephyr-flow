import Foundation
import AVFoundation
import Accelerate
import ZephyrFlowCore

actor AudioCapture: AudioCaptureProtocol {
    static let shared = AudioCapture()

    private(set) var isCapturing = false

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var onBuffer: (@Sendable ([Float]) -> Void)?
    private var latestLevels: [Float] = Array(repeating: 0.05, count: 24)
    private let targetSampleRate: Double = 16_000
    private var framesDelivered: Int = 0
    private var peakRMS: Float = 0

    func levels() async -> [Float] { latestLevels }

    /// Diagnostics from the current/last capture session.
    func captureStats() async -> (frames: Int, peakRMS: Float) {
        (framesDelivered, peakRMS)
    }

    func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    }

    func start(onBuffer: @escaping @Sendable ([Float]) -> Void) async throws {
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

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioCaptureError.engineStartFailed("Could not create 16 kHz mono float format")
        }

        guard let converter = AVAudioConverter(from: format, to: targetFormat) else {
            throw AudioCaptureError.engineStartFailed(
                "Could not convert \(format.sampleRate) Hz / \(format.channelCount) ch → 16 kHz mono"
            )
        }

        self.converter = converter
        self.onBuffer = onBuffer
        self.engine = engine
        self.framesDelivered = 0
        self.peakRMS = 0

        let bufferSize: AVAudioFrameCount = 4096

        input.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
            // AVAudioEngine reuses the tap buffer after this callback returns.
            // Own the PCM before any async hop or the samples are garbage/silence.
            guard let copy = Self.copyPCMBuffer(buffer) else { return }
            guard let self else { return }
            Task { await self.handleOwnedBuffer(copy) }
        }

        engine.prepare()
        do {
            try engine.start()
            isCapturing = true
        } catch {
            input.removeTap(onBus: 0)
            self.engine = nil
            self.converter = nil
            self.onBuffer = nil
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
        converter = nil
        onBuffer = nil
        isCapturing = false
        latestLevels = Array(repeating: 0.05, count: 24)
        ZFLog.info(
            "AudioCapture stop frames16k=\(framesDelivered) peakRMS=\(String(format: "%.5f", peakRMS))"
        )
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

    private func handleOwnedBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let onBuffer else { return }
        guard buffer.frameLength > 0 else { return }

        let ratio = targetSampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: targetSampleRate,
                channels: 1,
                interleaved: false
            )!,
            frameCapacity: capacity
        ) else { return }

        var error: NSError?
        var consumed = false
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .error {
            ZFLog.debug("Audio converter error: \(error?.localizedDescription ?? "unknown")")
            return
        }

        guard let channel = converted.floatChannelData?[0] else { return }
        let frameCount = Int(converted.frameLength)
        guard frameCount > 0 else { return }

        var samples = [Float](repeating: 0, count: frameCount)
        samples.withUnsafeMutableBufferPointer { dest in
            dest.baseAddress!.update(from: channel, count: frameCount)
        }

        framesDelivered += frameCount
        updateLevels(from: samples)
        onBuffer(samples)
    }

    private func updateLevels(from samples: [Float]) {
        guard !samples.isEmpty else { return }

        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        if rms > peakRMS { peakRMS = rms }

        let level = min(1.0, max(0.03, rms * 8))
        var next = latestLevels
        next.removeFirst()
        next.append(level)
        if next.count >= 2 {
            let i = next.count - 1
            next[i] = next[i] * 0.7 + next[i - 1] * 0.3
        }
        latestLevels = next
    }
}
