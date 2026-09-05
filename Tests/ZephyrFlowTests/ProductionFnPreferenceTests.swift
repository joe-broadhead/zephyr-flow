#if canImport(XCTest)
    import XCTest
    @testable import ZephyrFlow
    @testable import ZephyrFlowCore

    @MainActor
    private final class FnStorageFixture {
        var value: Any?
        var journal: Data?
        var legacy = false
        var events: [String] = []
        var rejectedJournalStates: Set<FnPreferenceStatus> = []
        var dropPreferenceWrites = false
        var throwAfterMutation = false
        private enum Failure: Error { case injected }

        func service() -> FnPreferenceOverrideService {
            FnPreferenceOverrideService(
                storage: .init(
                    readRecord: {
                        self.events.append("readJournal")
                        return self.journal
                    },
                    writeRecord: { data in
                        let record = try JSONDecoder().decode(FnPreferenceRecord.self, from: data)
                        self.events.append("journal-\(record.status.rawValue)")
                        if self.rejectedJournalStates.contains(record.status) { throw Failure.injected }
                        self.journal = data
                    }, hasLegacyMarker: { self.legacy },
                    readPreference: {
                        self.events.append("readPreference")
                        return self.value
                    },
                    writePreference: { value in
                        self.events.append("writePreference")
                        if !self.dropPreferenceWrites { self.value = value }
                        if self.throwAfterMutation {
                            self.throwAfterMutation = false
                            throw Failure.injected
                        }
                    }))
        }

        func seed(_ status: FnPreferenceStatus, original: Any?, version: Int = 2) throws {
            journal = try JSONEncoder().encode(
                FnPreferenceRecord(
                    version: version, status: status,
                    snapshot: FnPreferenceSnapshotCodec.capture(original)))
        }
    }

    final class ProductionFnPreferenceTests: XCTestCase {
        func testOptInFnAndNativePreparationAllRequiredBeforeAnyPreferenceAccess() async {
            await MainActor.run {
                for (optIn, fn, prepared) in [(false, true, true), (true, false, true), (true, true, false)] {
                    let fixture = FnStorageFixture()
                    let service = fixture.service()
                    XCTAssertFalse(service.apply(experimentalOptIn: optIn, isFn: fn, tapPrepared: prepared))
                    XCTAssertTrue(fixture.events.isEmpty)
                }
                let fixture = FnStorageFixture()
                XCTAssertTrue(fixture.service().recoverPriorLaunch())
                XCTAssertEqual(fixture.events, ["readJournal"], "no Fn-key read/write when no journal exists")
            }
        }

        func testExactAbsentIntegerBooleanStringAndNestedValuesRoundTrip() async throws {
            try await MainActor.run {
                let fixtures: [Any?] = [
                    nil, NSNumber(value: 2), NSNumber(value: true), NSNumber(value: false),
                    NSNumber(value: 1.25), "synthetic-unexpected", Data([0, 255]),
                    ["synthetic": [NSNumber(value: true), NSNumber(value: 1), "text"]],
                ]
                for original in fixtures {
                    let fixture = FnStorageFixture()
                    fixture.value = original
                    let snapshot = try FnPreferenceSnapshotCodec.capture(original)
                    let service = fixture.service()
                    XCTAssertTrue(service.apply(experimentalOptIn: true, isFn: true, tapPrepared: true))
                    XCTAssertEqual(service.record?.status, .applied)
                    let pending = try XCTUnwrap(fixture.events.firstIndex(of: "journal-pendingApply"))
                    let write = try XCTUnwrap(fixture.events.firstIndex(of: "writePreference"))
                    XCTAssertLessThan(pending, write)
                    XCTAssertTrue(service.restore(explicitRetry: true))
                    XCTAssertTrue(try FnPreferenceSnapshotCodec.matches(fixture.value, snapshot: snapshot))
                    XCTAssertTrue(service.settled)
                    XCTAssertFalse(
                        service.apply(experimentalOptIn: true, isFn: true, tapPrepared: true), "Reset must not reapply")
                    let writes = fixture.events.filter { $0 == "writePreference" }.count
                    XCTAssertTrue(service.restore(explicitRetry: true))
                    XCTAssertEqual(fixture.events.filter { $0 == "writePreference" }.count, writes)
                }
            }
        }

        func testPendingApplyCrashWindowAndRestoreJournalRecoverIdempotently() async throws {
            try await MainActor.run {
                for status in [FnPreferenceStatus.pendingApply, .applied, .pendingRestore] {
                    for mutated in [false, true] {
                        let fixture = FnStorageFixture()
                        try fixture.seed(status, original: "synthetic-original")
                        fixture.value = mutated ? NSNumber(value: 0) : "synthetic-original"
                        let service = fixture.service()
                        XCTAssertTrue(service.recoverPriorLaunch())
                        XCTAssertEqual(fixture.value as? String, "synthetic-original")
                        XCTAssertEqual(service.record?.status, .restored)
                        XCTAssertFalse(service.apply(experimentalOptIn: true, isFn: true, tapPrepared: true))
                        let events = fixture.events
                        XCTAssertTrue(service.recoverPriorLaunch())
                        XCTAssertEqual(fixture.events, events)
                    }
                }
            }
        }

        func testFailedJournalOrMutationAcknowledgmentDoesNotAuthorizeOrLoseSnapshot() async {
            await MainActor.run {
                let fixture = FnStorageFixture()
                fixture.value = "synthetic-original"
                fixture.rejectedJournalStates = [.pendingApply, .failedRestore]
                let service = fixture.service()
                XCTAssertFalse(service.apply(experimentalOptIn: true, isFn: true, tapPrepared: true))
                XCTAssertFalse(fixture.events.contains("writePreference"))
                XCTAssertTrue(service.recoveryRequired)
                fixture.rejectedJournalStates = []
                XCTAssertTrue(service.restore(explicitRetry: true))
                XCTAssertEqual(fixture.value as? String, "synthetic-original")

                for failAppliedJournal in [false, true] {
                    let next = FnStorageFixture()
                    next.value = "synthetic-original"
                    next.throwAfterMutation = !failAppliedJournal
                    next.rejectedJournalStates = failAppliedJournal ? [.applied] : []
                    let operation = next.service()
                    XCTAssertFalse(operation.apply(experimentalOptIn: true, isFn: true, tapPrepared: true))
                    XCTAssertEqual(next.value as? String, "synthetic-original")
                    XCTAssertEqual(operation.record?.status, .restored)
                    XCTAssertFalse(operation.apply(experimentalOptIn: true, isFn: true, tapPrepared: true))
                }
            }
        }

        func testFailedRestoreDisablesCaptureUntilExplicitVerifiedRetry() async throws {
            try await MainActor.run {
                let fixture = FnStorageFixture()
                try fixture.seed(.pendingRestore, original: NSNumber(value: false))
                fixture.value = NSNumber(value: 0)
                fixture.dropPreferenceWrites = true
                let service = fixture.service()
                XCTAssertFalse(service.recoverPriorLaunch(), "integer zero is not Boolean false")
                XCTAssertTrue(service.recoveryRequired)
                XCTAssertEqual(service.record?.status, .failedRestore)
                let restarted = fixture.service()
                let writes = fixture.events.filter { $0 == "writePreference" }.count
                XCTAssertFalse(restarted.recoverPriorLaunch())
                XCTAssertEqual(
                    fixture.events.filter { $0 == "writePreference" }.count, writes,
                    "failed recovery must not retry automatically")
                fixture.dropPreferenceWrites = false
                XCTAssertTrue(restarted.restore(explicitRetry: true))
                XCTAssertFalse(restarted.recoveryRequired)
                XCTAssertFalse(restarted.apply(experimentalOptIn: true, isFn: true, tapPrepared: true))
            }
        }

        func testUnrelatedLaterValueIsPreservedAndCannotReplaceRecoverySnapshot() async {
            await MainActor.run {
                let fixture = FnStorageFixture()
                fixture.value = "synthetic-original"
                let service = fixture.service()
                XCTAssertTrue(service.apply(experimentalOptIn: true, isFn: true, tapPrepared: true))
                let snapshot = service.record?.snapshot
                fixture.value = "synthetic-newer-value"
                let writes = fixture.events.filter { $0 == "writePreference" }.count
                XCTAssertFalse(service.restore(explicitRetry: true))
                XCTAssertTrue(service.recoveryRequired)
                XCTAssertEqual(service.record?.snapshot, snapshot)
                XCTAssertEqual(fixture.value as? String, "synthetic-newer-value")
                XCTAssertEqual(fixture.events.filter { $0 == "writePreference" }.count, writes)
            }
        }

        func testLegacyMissingPayloadMalformedOrForeignDomainRecordsNeverGuessAValue() async throws {
            try await MainActor.run {
                let legacy = FnPreferenceSnapshot(keyPresent: true, value: 2, cfTypeTag: "CFNumber")
                var foreign = try FnPreferenceSnapshotCodec.capture("synthetic")
                foreign.suiteName = "synthetic-unrelated-domain"
                let records: [Data] = [
                    try JSONEncoder().encode(FnPreferenceRecord(version: 1, status: .applied, snapshot: legacy)),
                    try JSONEncoder().encode(FnPreferenceRecord(version: 2, status: .applied, snapshot: foreign)),
                    try JSONEncoder().encode(FnPreferenceRecord(version: 99, status: .applied, snapshot: .none)),
                    Data("synthetic invalid json".utf8),
                ]
                for record in records {
                    let fixture = FnStorageFixture()
                    fixture.journal = record
                    fixture.value = NSNumber(value: 0)
                    let service = fixture.service()
                    XCTAssertFalse(service.recoverPriorLaunch())
                    XCTAssertTrue(service.recoveryRequired)
                    XCTAssertFalse(fixture.events.contains("writePreference"))
                }
                let legacyFixture = FnStorageFixture()
                legacyFixture.legacy = true
                XCTAssertFalse(legacyFixture.service().recoverPriorLaunch())
                XCTAssertFalse(legacyFixture.events.contains("writePreference"))
                XCTAssertThrowsError(try FnPreferenceSnapshotCodec.capture(Data(repeating: 1, count: 65_537)))
            }
        }
    }
#else
    #error("XCTest requires full Xcode; use swift run ZephyrFlowCoreTests on CommandLineTools-only machines.")
#endif
