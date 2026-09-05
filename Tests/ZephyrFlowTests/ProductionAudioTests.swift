#if canImport(XCTest)
    import AVFoundation
    import XCTest
    @testable import ZephyrFlow
    @testable import ZephyrFlowCore

    // In-memory native adapter tests. No AVAudioEngine, microphone, permissions,
    // model files, network or personal application state are touched.
    final class ProductionAudioTests: XCTestCase {
        func testCaptureSnapshotOwnsSamplesAfterBufferReuse() throws {
            let format = try XCTUnwrap(
                AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
            buffer.frameLength = 4
            let channel = try XCTUnwrap(buffer.floatChannelData?[0])
            for index in 0..<4 { channel[index] = Float(index) / 4 }

            let samples = AudioCapture.makeFloatArray(buffer)
            for index in 0..<4 { channel[index] = -1 }

            XCTAssertEqual(samples, [0, 0.25, 0.5, 0.75])
            XCTAssertEqual(AudioCapture.makeFloatArray(buffer), [-1, -1, -1, -1])
        }

        func testCaptureSnapshotUsesFirstChannelWithoutHalvingFrames() throws {
            let format = try XCTUnwrap(
                AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
            buffer.frameLength = 4
            let first = try XCTUnwrap(buffer.floatChannelData?[0])
            let second = try XCTUnwrap(buffer.floatChannelData?[1])
            for index in 0..<4 {
                first[index] = 0.25
                second[index] = -0.75
            }
            XCTAssertEqual(AudioCapture.makeFloatArray(buffer), [0.25, 0.25, 0.25, 0.25])
        }

        func testConverterProducesFiniteMonoSamplesFromOwnedPCM() throws {
            let converter = SessionAudioConverter()
            let input = AudioChunk(
                sessionID: SessionID(token: "synthetic-audio", sequence: 1, createdAtUptimeNanos: 0),
                sequence: 0, startSample: 0, sampleRate: 48_000, channelCount: 1,
                samples: Array(repeating: 0.25, count: 4800))
            let output = try XCTUnwrap(converter.convert(input))
            XCTAssertFalse(output.isEmpty)
            XCTAssertTrue(output.allSatisfy(\.isFinite))
            XCTAssertLessThanOrEqual(output.count, 1600 + 32)
            XCTAssertTrue(converter.flush().allSatisfy(\.isFinite))
        }

        func testConverterRetainsShortEndOfStreamTail() throws {
            for rate in [44_100.0, 48_000.0] {
                let converter = SessionAudioConverter()
                let input = AudioChunk(
                    sessionID: SessionID(token: "synthetic-tail", sequence: 1, createdAtUptimeNanos: 0),
                    sequence: 0, startSample: 0, sampleRate: rate, channelCount: 1,
                    samples: Array(repeating: 0.25, count: 4800))
                let first = try XCTUnwrap(converter.convert(input))
                let tail = converter.flush()
                XCTAssertFalse(tail.isEmpty, "the native resampler buffers a short final block")
                let expected = Double(input.samples.count) * SessionAudioConverter.targetSampleRate / rate
                XCTAssertEqual(Double(first.count + tail.count), expected, accuracy: 1)
                XCTAssertTrue(tail.allSatisfy(\.isFinite))
                XCTAssertTrue(converter.flush().isEmpty, "a second flush must not duplicate the tail")
            }
        }
    }
#else
    #error("XCTest requires full Xcode; use swift run ZephyrFlowCoreTests on CommandLineTools-only machines.")
#endif
