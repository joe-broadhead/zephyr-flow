#if canImport(XCTest)
    import XCTest
    @testable import ZephyrFlow
    @testable import ZephyrFlowCore

    private final class ObservedHistoryFileSystem: HistoryFileSystem, @unchecked Sendable {
        // Test fault/call counters only, synchronized; native calls are made
        // outside the lock against one fixture's private temporary root.
        private let lock = NSLock()
        private var calls = 0
        private var readFails = false
        private let real = RealHistoryFileSystem()
        var count: Int { lock.withLock { calls } }
        func failReads(_ value: Bool) { lock.withLock { readFails = value } }
        private func record() { lock.withLock { calls += 1 } }
        func fileExists(_ url: URL) -> Bool {
            record()
            return real.fileExists(url)
        }
        func createDirectory(_ url: URL) throws {
            record()
            try real.createDirectory(url)
        }
        func readData(_ url: URL) throws -> Data {
            record()
            if lock.withLock({ readFails }) { throw HistoryRepositoryError.permissionDenied }
            return try real.readData(url)
        }
        func writeAtomic(data: Data, to url: URL) throws {
            record()
            try real.writeAtomic(data: data, to: url)
        }
        func move(_ from: URL, to: URL) throws {
            record()
            try real.move(from, to: to)
        }
        func remove(_ url: URL) throws {
            record()
            try real.remove(url)
        }
        func setPermissions(_ url: URL, mode: Int) throws {
            record()
            try real.setPermissions(url, mode: mode)
        }
    }

    private actor HistoryKeyFixture {
        private(set) var calls = 0
        private var held: Bool
        private var missing = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        init(held: Bool = false) { self.held = held }
        func setMissing(_ value: Bool) { missing = value }
        func load() async -> HistoryCryptoKey? {
            calls += 1
            if held { await withCheckedContinuation { waiters.append($0) } }
            return missing ? nil : HistoryCryptoKey(keyID: "synthetic", material: Data(repeating: 7, count: 32))
        }
        func release() {
            held = false
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }

    final class ProductionHistoryTests: XCTestCase {
        private enum FixtureError: Error { case timedOut }
        private func until(_ predicate: @Sendable () async -> Bool) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            while !(await predicate()) {
                if clock.now >= deadline { throw FixtureError.timedOut }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }

        private func fixture(key: HistoryKeyFixture, fs: ObservedHistoryFileSystem = ObservedHistoryFileSystem()) throws
            -> (ActorHistoryRepository, HistoryStoragePreparation, URL)
        {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("zf-history-init-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let url = root.appendingPathComponent("history.json")
            let repository = ActorHistoryRepository(fileURL: url, fileSystem: fs)
            let preparation = HistoryStoragePreparation(repository: repository) { await key.load() }
            addTeardownBlock {
                await key.release()
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: .seconds(5))
                while await preparation.isInitializing {
                    if clock.now >= deadline { throw FixtureError.timedOut }
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
                try FileManager.default.removeItem(at: root)
            }
            return (repository, preparation, url)
        }

        func testHistoryOffDoesNotTouchStorageOrKeyProviderEvenAfterFailedRead() async throws {
            let key = HistoryKeyFixture()
            let fs = ObservedHistoryFileSystem()
            let (repository, preparation, url) = try fixture(key: key, fs: fs)
            let disabled = await preparation.prepareForSession(saveHistory: false)
            XCTAssertTrue(disabled)
            XCTAssertEqual(fs.count, 0)
            let keyCalls = await key.calls
            XCTAssertEqual(keyCalls, 0)
            try JSONEncoder().encode(HistoryDocument(entries: [])).write(to: url)
            fs.failReads(true)
            let enabled = await preparation.prepareForSession(saveHistory: true)
            XCTAssertFalse(enabled)
            let state = await repository.storageState
            XCTAssertEqual(state, .storageReadFailure)
            let count = fs.count
            let offAgain = await preparation.prepareForSession(saveHistory: false)
            XCTAssertTrue(offAgain)
            XCTAssertEqual(fs.count, count)
            fs.failReads(false)
            let retried = await preparation.prepareForSession(saveHistory: true)
            XCTAssertTrue(retried)
            let encryptedState = await repository.storageState
            XCTAssertEqual(encryptedState, .readyEncrypted)
        }

        func testCancelledAndExpiredWaitersReturnWhileOneInitializerRetainsOwnership() async throws {
            let key = HistoryKeyFixture(held: true)
            let fs = ObservedHistoryFileSystem()
            let (_, preparation, _) = try fixture(key: key, fs: fs)
            let waiter = Task { await preparation.prepareForAccess() }
            addTeardownBlock {
                waiter.cancel()
                await key.release()
                _ = await waiter.value
            }
            try await until { await key.calls == 1 }
            waiter.cancel()
            let result = await waiter.value
            XCTAssertFalse(result)
            let initializing = await preparation.isInitializing
            XCTAssertTrue(initializing)
            let timedOut = await preparation.prepareForAccess(timeoutNanos: 1_000_000)
            XCTAssertFalse(timedOut)
            let keyCalls = await key.calls
            XCTAssertEqual(keyCalls, 1)
            XCTAssertEqual(fs.count, 0, "repository load must wait for encryption configuration")
            await key.release()
            try await until { !(await preparation.isInitializing) }
            let ready = await preparation.prepareForAccess()
            XCTAssertTrue(ready)
            let callsAfterReady = await key.calls
            XCTAssertEqual(callsAfterReady, 1)
        }

        func testHistoryViewUsesSharedEncryptedInitializationAndCanRetryMissingKey() async throws {
            let key = HistoryKeyFixture()
            await key.setMissing(true)
            let (repository, preparation, _) = try fixture(key: key)
            let view = await HistoryViewModel(repository: repository, preparation: preparation)
            await view.reload()
            let failure = await view.lastError
            XCTAssertEqual(failure, AppStrings.key("history.preparation.failed"))
            let entries = await view.entries
            XCTAssertTrue(entries.isEmpty)
            await key.setMissing(false)
            await view.reload()
            let state = await repository.storageState
            let error = await view.lastError
            XCTAssertEqual(state, .readyEncrypted)
            XCTAssertNil(error)
        }
    }
#else
    #error("XCTest requires full Xcode; use swift run ZephyrFlowCoreTests on CommandLineTools-only machines.")
#endif
