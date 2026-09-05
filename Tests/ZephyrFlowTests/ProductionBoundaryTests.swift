#if canImport(XCTest)
    import ApplicationServices
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

    private final class NativeAccessProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0
        private var peak = 0
        private var completed = 0

        func enter() {
            lock.withLock {
                active += 1
                peak = max(peak, active)
            }
        }

        func leave() {
            lock.withLock {
                active -= 1
                completed += 1
            }
        }

        var counts: (active: Int, peak: Int, completed: Int) {
            lock.withLock { (active, peak, completed) }
        }
    }

    final class ProductionBoundaryTests: XCTestCase {
        func testConventionalHotkeyAdapterReleasesWhenModifiersGoFirstWithoutPostingEvents() throws {
            let flags = CGEventFlags([.maskControl, .maskAlternate]).rawValue
            XCTAssertEqual(flags, UInt64(HotkeyConfig.controlOptionSpace.modifiers))
            XCTAssertEqual(
                HotkeyEdgeStream.conventionalModifierMask,
                CGEventFlags([.maskControl, .maskAlternate, .maskShift, .maskCommand]).rawValue)
            var stream = HotkeyEdgeStream(configIsFn: false, configKeyCode: 49)
            stream.setLifecycle(.healthy)
            func input(_ type: CGEventType, key: Int64 = 49, flags: UInt64, repeatKey: Bool = false) throws
                -> StandardHotkeyEvent
            {
                try XCTUnwrap(
                    HotkeyTapEngine.standardInput(type: type, keyCode: key, flags: flags, isAutorepeat: repeatKey))
            }
            XCTAssertEqual(
                stream.feedStandard(try input(.keyDown, flags: flags), requiredModifiers: flags, timestampNanos: 1),
                true)
            XCTAssertNil(
                stream.feedStandard(
                    try input(.keyDown, flags: flags, repeatKey: true), requiredModifiers: flags, timestampNanos: 2))
            XCTAssertEqual(
                stream.feedStandard(
                    try input(.flagsChanged, key: 59, flags: CGEventFlags.maskAlternate.rawValue),
                    requiredModifiers: flags, timestampNanos: 3), false)
            XCTAssertNil(
                stream.feedStandard(
                    try input(.flagsChanged, key: 59, flags: flags), requiredModifiers: flags, timestampNanos: 4))
            XCTAssertNil(stream.feedStandard(try input(.keyUp, flags: 0), requiredModifiers: flags, timestampNanos: 5))
            XCTAssertEqual(stream.presses, 1)
            XCTAssertEqual(stream.releases, 1)
            XCTAssertNil(HotkeyTapEngine.standardInput(type: .keyDown, keyCode: -1, flags: 0, isAutorepeat: false))
            XCTAssertNil(HotkeyTapEngine.standardInput(type: .keyUp, keyCode: Int64.max, flags: 0, isAutorepeat: false))
            XCTAssertNil(
                HotkeyTapEngine.standardInput(type: .mouseMoved, keyCode: 49, flags: flags, isAutorepeat: false))
        }

        func testConventionalShortcutRequiresFreshExactChordAndHonorsKeyFirstRelease() {
            let flags = UInt64(HotkeyConfig.controlOptionSpace.modifiers)
            var stream = HotkeyEdgeStream(configIsFn: false, configKeyCode: 49)
            stream.setLifecycle(.healthy)
            XCTAssertNil(
                stream.feedStandard(
                    .keyDown(keyCode: 49, flags: 0, isAutorepeat: false), requiredModifiers: flags, timestampNanos: 1))
            XCTAssertNil(stream.feedStandard(.flagsChanged(flags: flags), requiredModifiers: flags, timestampNanos: 2))
            XCTAssertNil(
                stream.feedStandard(
                    .keyDown(keyCode: 49, flags: flags, isAutorepeat: true), requiredModifiers: flags, timestampNanos: 3
                ))
            XCTAssertNil(
                stream.feedStandard(.keyUp(keyCode: 49, flags: flags), requiredModifiers: flags, timestampNanos: 4))
            XCTAssertNil(
                stream.feedStandard(
                    .keyDown(keyCode: 50, flags: flags, isAutorepeat: false), requiredModifiers: flags,
                    timestampNanos: 5))
            XCTAssertEqual(
                stream.feedStandard(
                    .keyDown(keyCode: 49, flags: flags, isAutorepeat: false), requiredModifiers: flags,
                    timestampNanos: 6), true)
            XCTAssertEqual(
                stream.feedStandard(.keyUp(keyCode: 49, flags: flags), requiredModifiers: flags, timestampNanos: 7),
                false)
            XCTAssertNil(stream.feedStandard(.flagsChanged(flags: 0), requiredModifiers: flags, timestampNanos: 8))
            XCTAssertEqual(stream.presses, 1)
            XCTAssertEqual(stream.releases, 1)
        }

        func testFnChordUsesNativeModifierMasksAndCannotStrandPriorHold() {
            for modifier in [CGEventFlags.maskControl, .maskAlternate, .maskShift, .maskCommand] {
                var stream = HotkeyEdgeStream(configIsFn: true)
                stream.setLifecycle(.healthy)
                let fn = CGEventFlags.maskSecondaryFn.rawValue
                XCTAssertFalse(
                    stream.feed(
                        .init(
                            source: .tap, down: true, keyCode: 63,
                            flags: fn | modifier.rawValue, isFnKey: true, timestampNanos: 1)))
                _ = stream.feed(
                    .init(source: .tap, down: false, keyCode: 63, flags: 0, isFnKey: true, timestampNanos: 2))
                XCTAssertTrue(
                    stream.feed(
                        .init(source: .tap, down: true, keyCode: 63, flags: fn, isFnKey: true, timestampNanos: 3)))
                XCTAssertTrue(
                    stream.feed(
                        .init(
                            source: .tap, down: true, keyCode: 63,
                            flags: fn | modifier.rawValue, isFnKey: true, timestampNanos: 4)))
                XCTAssertFalse(
                    stream.heldDown, "caller must emit logical state, not raw down, when a modifier breaks the chord")
                XCTAssertFalse(
                    stream.feed(
                        .init(
                            source: .tap, down: true, keyCode: 63,
                            flags: fn, isFnKey: true, timestampNanos: 5)),
                    "removing a modifier while Fn remains down cannot rearm")
                _ = stream.feed(
                    .init(
                        source: .tap, down: false, keyCode: 63,
                        flags: modifier.rawValue, isFnKey: true, timestampNanos: 6))
                XCTAssertEqual(stream.presses, 1)
                XCTAssertEqual(stream.releases, 1)
            }
        }

        func testNativeSensitivityReadsSameHandleRoleSubroleAndBooleanEnabledOnly() {
            var queried: [String] = []
            let evidence = AXSensitivityReader.readAttributes { name in
                queried.append(name)
                switch name {
                case kAXRoleAttribute: return (.success, "AXTextField" as CFString)
                case kAXSubroleAttribute: return (.success, "AXSecureTextField" as CFString)
                case kAXEnabledAttribute: return (.success, kCFBooleanTrue)
                default:
                    XCTFail("unexpected attribute query")
                    return (.attributeUnsupported, nil)
                }
            }
            XCTAssertEqual(queried, [kAXRoleAttribute, kAXSubroleAttribute, kAXEnabledAttribute])
            XCTAssertEqual(evidence.sensitivity, .secure)
        }

        func testMissingOptionalSubroleDiffersFromIPCFailureOrWrongType() {
            for error in [AXError.attributeUnsupported, .noValue, .cannotComplete, .apiDisabled, .failure] {
                let evidence = AXSensitivityReader.readAttributes { name in
                    switch name {
                    case kAXRoleAttribute: return (.success, "AXTextArea" as CFString)
                    case kAXSubroleAttribute: return (error, nil)
                    default: return (.success, kCFBooleanTrue)
                    }
                }
                XCTAssertEqual(
                    evidence.sensitivity, [.attributeUnsupported, .noValue].contains(error) ? .normal : .unknown)
            }
            for malformedAttribute in [kAXRoleAttribute, kAXSubroleAttribute, kAXEnabledAttribute] {
                let evidence = AXSensitivityReader.readAttributes { name in
                    if name == malformedAttribute { return (.success, Data([1]) as CFData) }
                    switch name {
                    case kAXRoleAttribute: return (.success, "AXTextField" as CFString)
                    case kAXSubroleAttribute: return (.attributeUnsupported, nil)
                    default: return (.success, kCFBooleanTrue)
                    }
                }
                XCTAssertEqual(evidence.sensitivity, .unknown)
            }
        }

        func testProcessStartIdentityPreservesIntegerMicrosecondsAndRejectsOverflow() {
            XCTAssertEqual(
                ProcessStartIdentity.nanoseconds(seconds: 1_725_566_789, microseconds: 123_456),
                1_725_566_789_123_456_000)
            XCTAssertNil(ProcessStartIdentity.nanoseconds(seconds: .max, microseconds: 0))
            XCTAssertNil(ProcessStartIdentity.nanoseconds(seconds: UInt64.max / 1_000_000_000, microseconds: 999_999))
            XCTAssertNil(ProcessStartIdentity.nanoseconds(seconds: 1, microseconds: 1_000_000))
            XCTAssertNil(ProcessStartIdentity.nanoseconds(seconds: 0, microseconds: 0))
        }

        func testProcessStartIdentityReadsOnlyOwnProcessAndIsStable() throws {
            // Read-only libproc query of this XCTest process, no target-app
            // AX messages, permissions, UI activation or process lifecycle work.
            let first = try XCTUnwrap(ProcessStartIdentity.read(pid: getpid()))
            XCTAssertEqual(ProcessStartIdentity.read(pid: getpid()), first)
            XCTAssertNil(ProcessStartIdentity.read(pid: 0))
            XCTAssertNil(ProcessStartIdentity.read(pid: -1))
        }

        func testAXHandleOwnerSerializesWithoutSendingAXMessages() {
            // Creating/hashing a handle does not query attributes, request
            // Accessibility trust, or send a write to any application.
            let owner = AXElementAccess(AXUIElementCreateApplication(getpid()))
            let probe = NativeAccessProbe()
            DispatchQueue.concurrentPerform(iterations: 32) { _ in
                _ = owner.withElement { element in
                    probe.enter()
                    defer { probe.leave() }
                    Thread.sleep(forTimeInterval: 0.001)
                    return CFHash(element)
                }
            }
            let counts = probe.counts
            XCTAssertEqual(counts.active, 0)
            XCTAssertEqual(counts.peak, 1)
            XCTAssertEqual(counts.completed, 32)
        }

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
