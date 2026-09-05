#if canImport(XCTest)
    import XCTest
    @testable import ZephyrFlow
    @testable import ZephyrFlowCore

    @MainActor
    private final class SettingsLoginFixture {
        var data: Data?
        var failWrite = false
        var failRegister = false
        var failUnregister = false
        var requiresApproval = false
        var holdUnregister = false
        var pending: CheckedContinuation<Void, Never>?
        var status: LaunchAtLoginState = .notRegistered
        var events: [String] = []

        func release() {
            holdUnregister = false
            pending?.resume()
            pending = nil
        }

        func settings() -> SettingsStore {
            SettingsStore(
                persistence: .init(
                    read: { self.data },
                    write: { data in
                        self.events.append("write")
                        guard !self.failWrite else { return false }
                        self.data = data
                        return true
                    }, quarantine: { _, _ in self.events.append("quarantine") }))
        }

        func service() -> LaunchAtLoginService {
            LaunchAtLoginService(
                readStatus: { self.status },
                register: {
                    self.events.append("register")
                    if self.failRegister {
                        throw NSError(
                            domain: "synthetic", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "synthetic-private-detail"])
                    }
                    self.status = self.requiresApproval ? .requiresApproval : .registered
                },
                unregister: {
                    self.events.append("unregister")
                    if self.holdUnregister { await withCheckedContinuation { self.pending = $0 } }
                    if self.failUnregister { throw CocoaError(.featureUnsupported) }
                    self.status = .notRegistered
                })
        }
    }

    final class ProductionSettingsTests: XCTestCase {
        private enum FixtureError: Error { case timedOut }
        private func until(_ predicate: @Sendable () async -> Bool) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            while !(await predicate()) {
                if clock.now >= deadline { throw FixtureError.timedOut }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }

        func testSettingsArePublishedOnlyAfterAcknowledgedPersistence() async {
            await MainActor.run {
                let fixture = SettingsLoginFixture()
                let store = fixture.settings()
                let original = store.settings
                fixture.failWrite = true
                XCTAssertFalse(store.update { $0.saveHistory = true })
                XCTAssertEqual(store.settings, original)
                XCTAssertNotNil(store.persistenceError)
                fixture.failWrite = false
                XCTAssertTrue(store.update { $0.saveHistory = true })
                XCTAssertTrue(store.settings.saveHistory)
                XCTAssertNil(store.persistenceError)
                XCTAssertEqual(SettingsStorageCoordinator.load(data: fixture.data).settings, store.settings)
                let persisted = fixture.data
                XCTAssertFalse(store.update { $0.panelOriginX = .nan })
                XCTAssertEqual(fixture.data, persisted, "encoding failure precedes persistence")
                XCTAssertNil(store.settings.panelOriginX)
            }
        }

        func testTransactionCannotCommitAnUnverifiedOrOppositeState() {
            for enabled in [false, true] {
                for status in LaunchAtLoginState.allCases {
                    var transaction = LaunchAtLoginTransaction()
                    transaction.begin(desiredEnabled: enabled)
                    transaction.commit(verifiedStatus: status)
                    XCTAssertEqual(
                        transaction.state,
                        LaunchAtLoginTransaction.statusConverges(status: status, desiredEnabled: enabled)
                            ? .applied : .pending)
                }
            }
        }

        func testLoginWaitsForSystemVerificationAndRejectsConcurrentDroppedToggle() async throws {
            let (fixture, store, service) = await MainActor.run {
                let fixture = SettingsLoginFixture()
                fixture.status = .registered
                fixture.holdUnregister = true
                let store = fixture.settings()
                _ = store.update { $0.launchAtLogin = true }
                fixture.events.removeAll()
                return (fixture, store, fixture.service())
            }
            let operation = Task {
                await service.apply(enabled: false) { value in store.update { $0.launchAtLogin = value } }
            }
            addTeardownBlock {
                await fixture.release()
                _ = await operation.value
            }
            try await until { await fixture.pending != nil }
            let before = await store.settings.launchAtLogin
            XCTAssertTrue(before)
            let other = await service.apply(enabled: true) { value in store.update { $0.launchAtLogin = value } }
            XCTAssertEqual(other, .pending)
            let beforeEvents = await fixture.events
            XCTAssertEqual(beforeEvents, ["unregister"])
            await fixture.release()
            let state = await operation.value
            let saved = await store.settings.launchAtLogin
            let events = await fixture.events
            XCTAssertEqual(state, .applied)
            XCTAssertFalse(saved)
            XCTAssertEqual(events, ["unregister", "write"])
        }

        func testLoginFailuresAndApprovalNeverPersistDesiredSettingOrFrameworkPayload() async {
            for approval in [false, true] {
                let (fixture, store, service) = await MainActor.run {
                    let fixture = SettingsLoginFixture()
                    fixture.requiresApproval = approval
                    fixture.failRegister = !approval
                    return (fixture, fixture.settings(), fixture.service())
                }
                let state = await service.apply(enabled: true) { value in store.update { $0.launchAtLogin = value } }
                let settings = await store.settings
                let events = await fixture.events
                let message = await service.lastError
                XCTAssertEqual(state, .rolledBack)
                XCTAssertFalse(settings.launchAtLogin)
                XCTAssertEqual(events, ["register"])
                XCTAssertNotNil(message)
                XCTAssertFalse(message?.contains("synthetic-private-detail") == true)
            }
        }

        func testPersistenceFailureCompensatesSystemChangeOrReportsUnverifiedRollback() async {
            for compensationFails in [false, true] {
                let (fixture, store, service) = await MainActor.run {
                    let fixture = SettingsLoginFixture()
                    fixture.failWrite = true
                    fixture.failUnregister = compensationFails
                    return (fixture, fixture.settings(), fixture.service())
                }
                let state = await service.apply(enabled: true) { value in store.update { $0.launchAtLogin = value } }
                let events = await fixture.events
                let system = await service.systemStatus
                let reconcile = await service.needsReconciliation
                let saved = await store.settings.launchAtLogin
                XCTAssertEqual(
                    state, .rolledBack, "desired setting is rolled back, not a guarantee about external state")
                XCTAssertEqual(events, ["register", "write", "unregister"])
                XCTAssertFalse(saved)
                XCTAssertEqual(system, compensationFails ? .registered : .notRegistered)
                XCTAssertEqual(reconcile, compensationFails)
            }
        }
    }
#else
    #error("XCTest requires full Xcode; use swift run ZephyrFlowCoreTests on CommandLineTools-only machines.")
#endif
