#if canImport(XCTest)
import XCTest
@testable import ZephyrFlowCore

/// M0 contract tests (JOE-2240/2241/2242/2267/2275). A new `StageOutcomeCategory`
/// case without a policy row fails these switches at compile time.
final class M0ContractTests: XCTestCase {

    // JOE-2240
    func testOutcomePolicyExhaustiveAndFailClosed() {
        for outcome in StageOutcomeCategory.allCases {
            _ = OutcomePolicy.policy(for: outcome) // exhaustive by construction
        }
        XCTAssertEqual(OutcomePolicy.policy(for: .secureTarget), .failClosed)
        XCTAssertFalse(OutcomePolicy.policy(for: .partial).maySaveHistory)
        XCTAssertFalse(OutcomePolicy.policy(for: .partial).mayWriteClipboard)
        XCTAssertFalse(OutcomePolicy.policy(for: .truncated).showsSuccessUI)
        XCTAssertFalse(OutcomePolicy.policy(for: .deadlineExceeded).showsSuccessUI)
        XCTAssertTrue(OutcomePolicy.policy(for: .completed).showsSuccessUI)
        // Exactly one outcome may display green success (completed)
        let successCount = StageOutcomeCategory.allCases.filter {
            OutcomePolicy.policy(for: $0).showsSuccessUI
        }.count
        XCTAssertEqual(successCount, 1)
    }

    func testTerminalGateExactlyOnce() async {
        let gate = SessionTerminalGate()
        XCTAssertTrue(await gate.record(.completed))
        XCTAssertFalse(await gate.record(.failed))
        XCTAssertEqual(await gate.terminalState?.outcome, .completed)
    }

    // JOE-2241
    func testSensitivityFailClosed() {
        XCTAssertFalse(SessionSensitivity.unknown.allowsAutomaticSideEffects)
        XCTAssertFalse(SessionSensitivity.secure.allowsAutomaticSideEffects)
        XCTAssertFalse(SessionSensitivity.secure.allowsHistory)
        XCTAssertFalse(SessionSensitivity.secure.allowsClipboardFallback)
        XCTAssertTrue(SessionSensitivity.normal.allowsAutomaticSideEffects)
        XCTAssertEqual(SensitivityAssessment.unknown.sensitivity, .unknown)
    }

    // JOE-2242
    func testStateMachineTableAndAbsorption() {
        let sm = SessionStateMachine()
        func tr(_ s: SessionState, _ e: SessionEvent) -> SessionTransition { sm.transition(from: s, event: e) }
        XCTAssertEqual(tr(.idle, .begin), .to(.preparing))
        XCTAssertEqual(tr(.preparing, .cancel), .to(.cancelled))
        XCTAssertEqual(tr(.capturing, .stop), .to(.draining))
        XCTAssertEqual(tr(.draining, .drainFinished), .to(.transcribing))
        XCTAssertEqual(tr(.transcribing, .transcriptionFinished), .to(.transforming))
        XCTAssertEqual(tr(.transforming, .transformationFinished), .to(.resolvingTarget))
        XCTAssertEqual(tr(.resolvingTarget, .targetValidationSucceeded), .to(.inserting))
        XCTAssertEqual(tr(.resolvingTarget, .targetUnknown), .to(.secureTarget))
        XCTAssertEqual(tr(.inserting, .insertionSucceeded), .to(.completed))
        XCTAssertEqual(tr(.capturing, .deadlineViolated), .to(.deadlineExceeded))
        for terminal in SessionState.allCases where terminal.isTerminal {
            for event in SessionEvent.allCases {
                XCTAssertEqual(tr(terminal, event), .illegal)
            }
        }
        // every working non-terminal state can progress via some event
        for s in SessionState.allCases where !s.isTerminal && s != .idle {
            var canProgress = false
            for e in SessionEvent.allCases {
                if case .to = tr(s, e) { canProgress = true }
            }
            XCTAssertTrue(canProgress, "state \(s) cannot progress")
        }
    }

    // JOE-2267
    func testTargetSnapshotRejectsZephyrAndUnknownConfidence() {
        let sid = SessionID(token: "t", sequence: 1, createdAtUptimeNanos: 0)
        let identity = TargetSnapshot.Identity(
            pid: 500, bundleID: "com.zephyr.ZephyrFlow",
            processStartUptimeNanos: 1, windowID: nil, appVersion: nil)
        let snap = TargetSnapshot(sessionID: sid, capturedAtUptimeNanos: 1,
                                  target: identity, element: nil,
                                  settable: false, editable: false, enabled: false,
                                  selectionRange: nil, sensitivity: .unknown)
        XCTAssertFalse(snap.isUsableTarget(zephyrPIDs: [500], ignoredSystemPIDs: []))
        XCTAssertTrue(snap.isUsableTarget(zephyrPIDs: [999], ignoredSystemPIDs: []))
        XCTAssertEqual(snap.targetConfidence, .unknown)
    }

    // JOE-2275
    func testLossClassesAndLanguageGating() {
        XCTAssertTrue(FlowLossClass.verbatim.allowedForSecureSessions)
        XCTAssertTrue(FlowLossClass.conservative.allowedForSecureSessions)
        XCTAssertFalse(FlowLossClass.structural.allowedForSecureSessions)
        XCTAssertFalse(FlowLossClass.semantic.allowedForSecureSessions)
        XCTAssertTrue(FlowLossClass.semantic.requiresExplicitConsent)
        XCTAssertTrue(FlowLanguageContext(language: "en-US").isEnglishQualified)
        XCTAssertFalse(FlowLanguageContext(language: "de").isEnglishQualified)
        XCTAssertFalse(FlowLanguageContext(language: "en", forceConservative: true).isEnglishQualified)
    }
}

#endif
