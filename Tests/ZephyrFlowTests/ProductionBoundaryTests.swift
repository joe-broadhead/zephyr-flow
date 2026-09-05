#if canImport(XCTest)
    import XCTest
    @testable import ZephyrFlow
    @testable import ZephyrFlowCore

    @MainActor
    private final class IsolatedReadFixture {
        var settingsReads = 0
        var permissionReads = 0
        var settings = AppSettings.default
        var permissions = PermissionStatus(microphone: true, accessibility: false, speechRecognition: true)
    }

    final class ProductionBoundaryTests: XCTestCase {
        func testSpeechCallbackCopiesOnlySendableValuesAndControlledError() async {
            let callback = AppleSpeechCallback(
                text: "synthetic partial", isFinal: false,
                error: NSError(
                    domain: "synthetic", code: 42,
                    userInfo: [
                        NSLocalizedDescriptionKey: "synthetic private description",
                        "payload": "synthetic private metadata",
                    ]))
            let delivered = await Task.detached { callback }.value
            XCTAssertEqual(delivered.text, "synthetic partial")
            XCTAssertFalse(delivered.isFinal)
            XCTAssertEqual(delivered.errorCode, 42)
            XCTAssertEqual(
                delivered.errorMessage,
                "Speech recognition failed. Try again or choose another on-device engine.")
        }

        func testSpeechCallbackHandlesMissingResultsAndOversizedErrorCodes() {
            let empty = AppleSpeechCallback(text: nil, isFinal: false, error: nil)
            XCTAssertNil(empty.text)
            XCTAssertNil(empty.errorCode)
            XCTAssertNil(empty.errorMessage)

            let failure = AppleSpeechCallback(
                text: nil, isFinal: false, error: NSError(domain: "synthetic", code: Int.max))
            XCTAssertEqual(failure.errorCode, Int32.max)
            let disabled = AppleSpeechCallback(
                text: nil, isFinal: false, error: NSError(domain: "kLSRErrorDomain", code: 201))
            XCTAssertTrue(disabled.errorMessage?.contains("System Settings") == true)
        }

        func testSettingsAdapterReadsOnItsOwnerFromDetachedCaller() async {
            let fixture = await MainActor.run { IsolatedReadFixture() }
            let repository: any SettingsRepository = await MainActor.run {
                SettingsStoreRepository(read: {
                    MainActor.assertIsolated()
                    fixture.settingsReads += 1
                    return fixture.settings
                })
            }
            let initialReads = await fixture.settingsReads
            XCTAssertEqual(initialReads, 0, "construction must not load a settings store")

            let value = await Task.detached { await repository.current }.value
            XCTAssertEqual(value, AppSettings.default)
            let reads = await fixture.settingsReads
            XCTAssertEqual(reads, 1)
        }

        func testPermissionAdapterReadsOnItsOwnerWithoutSystemQueries() async {
            let fixture = await MainActor.run { IsolatedReadFixture() }
            let provider: any PermissionProviding = await MainActor.run {
                PrivacyPermissionProvider(read: {
                    MainActor.assertIsolated()
                    fixture.permissionReads += 1
                    return fixture.permissions
                })
            }
            let initialReads = await fixture.permissionReads
            XCTAssertEqual(initialReads, 0, "construction must not query system permissions")

            let values = await Task.detached {
                let microphone = await provider.microphoneGranted
                let accessibility = await provider.accessibilityTrusted
                let speech = await provider.speechRecognitionGranted
                return [microphone, accessibility, speech]
            }.value
            XCTAssertEqual(values, [true, false, true])
            let reads = await fixture.permissionReads
            XCTAssertEqual(reads, 3)
        }
    }
#else
    #error("XCTest requires full Xcode; use swift run ZephyrFlowCoreTests on CommandLineTools-only machines.")
#endif
