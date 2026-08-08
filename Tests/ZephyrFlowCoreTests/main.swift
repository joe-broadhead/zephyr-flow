import Foundation
import ZephyrFlowCore

@main
struct CoreTests {
    static func main() async {
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok {
                print("  ✓ \(name)")
            } else {
                print("  ✗ \(name)\(detail.isEmpty ? "" : " — \(detail)")")
                failed += 1
            }
        }

        print("ZephyrFlowCore tests\n")

        let processor = FlowProcessor()

        // Raw
        do {
            let out = await processor.process("  um hello world  ", style: .raw)
            check("raw passthrough trims", out == "um hello world", out)
        }

        // Clean fillers
        do {
            let out = await processor.process("um I think uh we should, you know, ship it", style: .clean)
            check("clean strips um", !out.lowercased().contains("um"), out)
            check("clean strips uh", !out.lowercased().split(separator: " ").contains("uh"), out)
            check("clean strips you know", !out.lowercased().contains("you know"), out)
            check("clean keeps ship", out.lowercased().contains("ship"), out)
            check("clean capitalizes", out.first?.isUppercase == true, out)
        }

        // Empty
        do {
            let out = await processor.process("   ", style: .clean)
            check("empty → empty", out.isEmpty)
        }

        // Bullets
        do {
            let out = await processor.process("Buy milk. Call mom. Ship the release.", style: .bullets)
            let lines = out.split(separator: "\n")
            check("bullets has multiple lines", lines.count >= 2, out)
            check("bullets prefix", lines.allSatisfy { $0.hasPrefix("•") }, out)
        }

        // Professional
        do {
            let out = await processor.process("I can't ship this yet", style: .professional)
            check("professional expands can't", out.lowercased().contains("cannot"), out)
            check("professional drops contraction", !out.contains("can't"), out)
        }

        // Summary
        do {
            let input = "We need to ship today. The build is green. Stakeholders are waiting for the demo this afternoon."
            let out = await processor.process(input, style: .summary)
            check("summary non-empty", !out.isEmpty, out)
            check("summary not longer", out.count <= input.count, out)
        }

        // Settings defaults (privacy posture)
        do {
            let s = AppSettings.default
            check("local only default", s.localOnlyMode)
            check("downloads on by default", s.allowModelDownloads)
            check("mayDownload follows allow flag", s.mayDownloadModels)
            check("default model whisper tiny", s.preferredModel == .whisperTiny)
            check("default hotkey fn", s.hotkey.specialKey == .fn)
            check("debug logging off", !s.debugLogging)
            check("save history default on", s.saveHistory)
        }

        // Download gate (model files only — independent of Local Only audio policy)
        do {
            var s = AppSettings.default
            s.allowModelDownloads = false
            check("mayDownload off when flag off", !s.mayDownloadModels)
            s.allowModelDownloads = true
            s.localOnlyMode = true
            check("localOnly still allows model download flag", s.mayDownloadModels)
        }

        // Codable round-trip
        do {
            let original = AppSettings.default
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
            check("settings round-trip", original == decoded)
        } catch {
            check("settings round-trip", false, error.localizedDescription)
        }

        // InsertionResult
        check("inserted succeeds", InsertionResult.inserted.succeeded)
        check("copied message", InsertionResult.copiedToClipboard.userMessage == "Copied to clipboard")
        check("failed fails", !InsertionResult.failed("x").succeeded)

        // Streaming partial window policy (Whisper progressive decode)
        do {
            check(
                "partial needs >= 1s audio",
                !StreamingPartialWindow.canRunPartial(sampleCount: StreamingPartialWindow.minPartialSamples - 1)
            )
            check(
                "partial ok at 1s",
                StreamingPartialWindow.canRunPartial(sampleCount: StreamingPartialWindow.minPartialSamples)
            )
            let short = [Float](repeating: 0.1, count: 100)
            let slicedShort = StreamingPartialWindow.sliceForPartial(short)
            check("short slice is identity", slicedShort.count == short.count)

            let longCount = StreamingPartialWindow.windowSamples + 500
            var long = [Float](repeating: 0, count: longCount)
            long[longCount - 1] = 0.99
            let sliced = StreamingPartialWindow.sliceForPartial(long)
            check("long slice capped", sliced.count == StreamingPartialWindow.windowSamples)
            check("long slice keeps newest", abs(sliced.last! - 0.99) < 0.0001)
            check("interval positive", StreamingPartialWindow.intervalNanoseconds > 0)
        }

        // Insertion strategy resolver
        do {
            let term = InsertionStrategyResolver.strategies(
                bundleID: "com.apple.Terminal", role: nil, mode: .automatic
            )
            check("terminal leads with terminalPaste", term.first == .terminalPaste)
            let secure = InsertionStrategyResolver.strategies(
                bundleID: "com.apple.Notes", role: "AXSecureTextField", mode: .automatic
            )
            check("secure is copyOnly only", secure == [.copyOnly])
            let copyMode = InsertionStrategyResolver.strategies(
                bundleID: "com.apple.Notes", role: nil, mode: .alwaysCopy
            )
            check("alwaysCopy", copyMode == [.copyOnly])
        }

        // Flow guardrails
        do {
            check(
                "guard accepts same numbers",
                FlowGuardrails.accept(input: "pay 12000 now", output: "Pay 12,000 now.") != nil
            )
            check(
                "guard rejects novel number",
                FlowGuardrails.accept(input: "pay 100 now", output: "Pay 999 now.") == nil
            )
            check(
                "guard rejects preamble",
                FlowGuardrails.accept(input: "hello", output: "Sure, hello there") == nil
            )
        }

        // Settings defaults for new fields
        do {
            let s = AppSettings.default
            check("flow backend regex default", s.flowBackend == .regex)
            check("insertion automatic default", s.insertionMode == .automatic)
            check("panel not locked default", !s.panelPositionLocked)
        }

        // App version compare (update checker)
        do {
            check("parse v-prefix", AppVersion.parse("v1.2.3").map { $0 == (1, 2, 3) } == true)
            check("parse plain", AppVersion.parse("0.0.0").map { $0 == (0, 0, 0) } == true)
            check("newer patch", AppVersion.isNewer(candidate: "0.0.1", than: "0.0.0"))
            check("not newer same", !AppVersion.isNewer(candidate: "0.0.0", than: "0.0.0"))
            check("not older major", !AppVersion.isNewer(candidate: "0.9.9", than: "1.0.0"))
            check("newer minor", AppVersion.isNewer(candidate: "v1.1.0", than: "1.0.9"))
        }

        // ===== M0 contract tests =====
        // JOE-2240: outcome taxonomy policy is exhaustive and fail-closed
        do {
            var successOutcomes = 0
            for outcome in StageOutcomeCategory.allCases {
                let policy = OutcomePolicy.policy(for: outcome)
                if policy.showsSuccessUI { successOutcomes += 1 }
            }
            check("only completed shows success UI", successOutcomes == 1)
            check("completed full policy", OutcomePolicy.policy(for: .completed).entersReleaseEvidence)
            check("partial never persists", !OutcomePolicy.policy(for: .partial).maySaveHistory
                  && !OutcomePolicy.policy(for: .partial).mayWriteClipboard)
            check("truncated never success", !OutcomePolicy.policy(for: .truncated).showsSuccessUI)
            check("secureTarget fail-closed", OutcomePolicy.policy(for: .secureTarget) == .failClosed)
            check("deadlineExceeded not success", !OutcomePolicy.policy(for: .deadlineExceeded).showsSuccessUI)
            check("degraded not success but persists", !OutcomePolicy.policy(for: .degraded).showsSuccessUI
                  && OutcomePolicy.policy(for: .degraded).maySaveHistory)
        }
        // exactly-one terminal gate
        do {
            let gate = SessionTerminalGate()
            let first = await gate.record(.completed)
            let second = await gate.record(.failed)
            check("terminal gate exactly once", first && !second)
            check("terminal gate is terminal", await gate.isTerminal)
            let gate2 = SessionTerminalGate()
            check("gate2 not terminal", !(await gate2.isTerminal))
        }
        // JOE-2241: sensitivity fail-closed
        do {
            check("unknown fails closed", !SessionSensitivity.unknown.allowsAutomaticSideEffects)
            check("secure fails closed", !SessionSensitivity.secure.allowsAutomaticSideEffects)
            check("secure no history", !SessionSensitivity.secure.allowsHistory)
            check("secure no clipboard", !SessionSensitivity.secure.allowsClipboardFallback)
            check("secure no payload", !SessionSensitivity.secure.allowsPayloadDiagnostics)
            check("normal allows side effects", SessionSensitivity.normal.allowsAutomaticSideEffects)
            check("unknown assessment canonical", SensitivityAssessment.unknown.sensitivity == .unknown)
        }
        // JOE-2242: state machine transition table
        do {
            let sm = SessionStateMachine()
            func tr(_ s: SessionState, _ e: SessionEvent) -> SessionTransition { sm.transition(from: s, event: e) }
            check("idle begin -> preparing", tr(.idle, .begin) == .to(.preparing))
            check("preparing cancel -> cancelled", tr(.preparing, .cancel) == .to(.cancelled))
            check("preparing release prevents capture", tr(.preparing, .stop) == .illegal || tr(.preparing, .stop) == .to(.cancelled))
            check("capturing stop -> draining", tr(.capturing, .stop) == .to(.draining))
            check("capturing duplicate begin stays", tr(.capturing, .begin) == .stay)
            check("draining finish -> transcribing", tr(.draining, .drainFinished) == .to(.transcribing))
            check("transcribing finished -> transforming", tr(.transcribing, .transcriptionFinished) == .to(.transforming))
            check("transforming finished -> resolving", tr(.transforming, .transformationFinished) == .to(.resolvingTarget))
            check("resolving ok -> inserting", tr(.resolvingTarget, .targetValidationSucceeded) == .to(.inserting))
            check("resolving secure -> secureTarget", tr(.resolvingTarget, .targetSecure) == .to(.secureTarget))
            check("resolving unknown fails closed", tr(.resolvingTarget, .targetUnknown) == .to(.secureTarget))
            check("inserting ok -> completed", tr(.inserting, .insertionSucceeded) == .to(.completed))
            check("deadline on capturing", tr(.capturing, .deadlineViolated) == .to(.deadlineExceeded))
            // terminal absorbing
            var absorbingOK = true
            for terminal in SessionState.allCases where terminal.isTerminal {
                for event in SessionEvent.allCases where tr(terminal, event) != .illegal { absorbingOK = false }
            }
            check("terminal states absorb all events", absorbingOK)
            // every non-terminal state can progress or is intentionally idle
            var progressOK = true
            for s in SessionState.allCases where !s.isTerminal && s != .idle {
                var canProgress = false
                for e in SessionEvent.allCases {
                    if case .to = tr(s, e) { canProgress = true }
                }
                if !canProgress { progressOK = false }
            }
            check("every working state can progress", progressOK)
            // happy path
            var happy: [SessionState] = [.idle]
            for (e, expect) in [(SessionEvent.begin, SessionState.preparing),
                                (.readyToCapture, .capturing),
                                (.stop, .draining),
                                (.drainFinished, .transcribing),
                                (.transcriptionFinished, .transforming),
                                (.transformationFinished, .resolvingTarget),
                                (.targetValidationSucceeded, .inserting),
                                (.insertionSucceeded, .completed)] {
                if case .to(let ns) = tr(happy.last!, e) { happy.append(ns) }
            }
            check("happy path reaches completed", happy.last == .completed && happy.count == 9)
        }
        // JOE-2267: TargetSnapshot contract
        do {
            let sid = SessionID(token: "t", sequence: 1, createdAtUptimeNanos: 0)
            let ident = TargetSnapshot.Identity(pid: 4242, bundleID: "com.example.App",
                                                processStartUptimeNanos: 99, windowID: 77, appVersion: "1.0")
            let snap = TargetSnapshot(sessionID: sid, capturedAtUptimeNanos: 5, target: ident,
                                      element: nil, settable: true, editable: true, enabled: true,
                                      selectionRange: 2..<5,
                                      sensitivity: SensitivityAssessment.unknown)
            check("snapshot rejects zephyr pid", !snap.isUsableTarget(zephyrPIDs: [4242], ignoredSystemPIDs: []))
            check("snapshot rejects ignored system pid",
                  !TargetSnapshot(sessionID: sid, capturedAtUptimeNanos: 0, target: TargetSnapshot.Identity(pid: 1, bundleID: nil, processStartUptimeNanos: nil, windowID: nil, appVersion: nil), element: nil, settable: false, editable: false, enabled: false, selectionRange: nil, sensitivity: .unknown).isUsableTarget(zephyrPIDs: [], ignoredSystemPIDs: [1]))
            check("no element -> unknown confidence", snap.targetConfidence == .unknown)
            check("snapshot immutable range", snap.selectionRange == 2..<5)
        }
        // JOE-2275: loss classes + language gating
        do {
            check("secure allows verbatim", FlowLossClass.verbatim.allowedForSecureSessions)
            check("secure allows conservative", FlowLossClass.conservative.allowedForSecureSessions)
            check("secure blocks structural", !FlowLossClass.structural.allowedForSecureSessions)
            check("secure blocks semantic", !FlowLossClass.semantic.allowedForSecureSessions)
            check("semantic needs consent", FlowLossClass.semantic.requiresExplicitConsent)
            check("en qualified", FlowLanguageContext(language: "en-US").isEnglishQualified)
            check("de not qualified", !FlowLanguageContext(language: "de").isEnglishQualified)
            check("forced conservative", !FlowLanguageContext(language: "en", forceConservative: true).isEnglishQualified)
        }

        // ===== JOE-2246: session control model =====
        do {
            // release during a blocked fake model load prevents capture
            var c = SessionControlModel()
            let sid = c.begin(nowNanos: 0)
            check("begin allocates SessionID and enters preparing", sid != nil && c.state == .preparing)
            let stopEffect = c.stop()
            check("stop during preparing cancels", stopEffect == .transitioned(.cancelled))
            let capture = c.stage(.readyToCapture)
            var rejected = false
            if case .rejected = capture { rejected = true }
            check("release before capture prevents later capture", rejected)
            check("terminal outcome cancelled", c.terminal == .cancelled)
        }
        do {
            // idempotent duplicate begin/stop/cancel; exactly-one outcome
            var c = SessionControlModel()
            _ = c.begin()
            check("duplicate begin is no-op", c.begin() == nil)
            _ = c.stage(.readyToCapture)
            check("stop during capturing -> draining", c.stop() == .transitioned(.draining))
            check("duplicate stop is no-op", c.stop() == .idempotentNoop)
            _ = c.stage(.drainFinished)
            _ = c.stage(.transcriptionFinished)
            _ = c.stage(.transformationFinished)
            _ = c.stage(.targetValidationSucceeded)
            let done = c.stage(.insertionSucceeded)
            var completed = false
            if case .accepted(let st) = done, st == .completed { completed = true }
            check("happy path completes", completed)
            check("terminal recorded once", c.terminal == .completed)
            check("duplicate cancel is idempotent after terminal", c.cancel() == .idempotentNoop)
            var lateRejected = false
            if case .rejected = c.stage(.insertionFailed) { lateRejected = true }
            check("late events rejected after terminal", lateRejected)
        }
        do {
            // stale callback from session A cannot mutate session B
            var c1 = SessionControlModel()
            let a = c1.begin()!
            c1.cancel()
            check("cancelled session is not current", !c1.isCurrent(a))
            var c2 = SessionControlModel()
            let a2 = c2.begin()!
            _ = c2.cancel()
            let b2 = c2.begin()
            check("new session B begins after terminal", b2 != nil)
            check("B is current", b2 != nil && c2.isCurrent(b2!))
            check("A stale callback rejected", a2 != b2 && !c2.isCurrent(a2))
        }
        do {
            // shutdown rejects new sessions and reports abandonment
            var c = SessionControlModel()
            _ = c.begin()
            let eff = c.shutdown()
            check("shutdown abandons active session", eff == .transitioned(.abandonedDuringShutdown))
            check("shutdown terminal recorded", c.terminal == .abandonedDuringShutdown)
            check("shutdown rejects new sessions", c.begin() == nil)
            let again = c.shutdown()
            check("shutdown idempotent", again == .idempotentNoop)
        }
        do {
            // 10,000 randomized press/release/cancel edges preserve invariants
            var seed: UInt64 = 0xD1B54A32D192ED03
            func nextRand() -> UInt64 {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return seed >> 33
            }
            var c = SessionControlModel()
            var invalid = false
            var terminalCount = 0
            for _ in 0..<10_000 {
                let r = Int(nextRand() % 3)
                switch r {
                case 0: _ = c.begin()
                case 1: _ = c.stop()
                default: _ = c.cancel()
                }
                if c.terminal != nil {
                    terminalCount += 1
                    // duplicates after terminal must never produce .illegal
                    if c.cancel() == .illegal || c.stop() == .illegal { invalid = true }
                    // terminal is absorbing: stage events are rejected or ignored
                    if case .accepted = c.stage(.insertionSucceeded) { invalid = true }
                    c = SessionControlModel() // fresh cycle (new session)
                }
            }
            check("10k randomized edges keep invariants", !invalid && terminalCount > 0)
        }


        // ===== JOE-2258: authoritative sensitivity policy =====
        do {
            // session-start evidence present, pre-insertion evidence missing => unknown (fail closed)
            let start = SensitivityAssessment(sensitivity: .normal, source: .accessibilityRole, capturedAtNanos: 1)
            let d = SessionSensitivityDecision.resolve(sessionStart: start, preInsertion: nil)
            check("no pre-insertion evidence fails closed to unknown", d.sensitivity == .unknown)
            check("fail-closed decision forbids auto insertion", !SensitivityPolicy.allowance(sensitivity: d.sensitivity, surface: .automaticInsertion))
        }
        do {
            // most-restrictive wins: normal at start, secure at insertion
            let start = SensitivityAssessment(sensitivity: .normal, source: .accessibilityRole, capturedAtNanos: 1)
            let sec = SensitivityAssessment(sensitivity: .secure, source: .accessibilityRole, capturedAtNanos: 2)
            let inside = SessionSensitivityDecision.resolve(sessionStart: start, preInsertion: sec)
            check("upgrade to secure before insertion", inside.sensitivity == .secure && inside.upgradedBeforeInsertion)
            check("secure forbids auto insert/clipboard/history",
                  !SensitivityPolicy.allowance(sensitivity: .secure, surface: .automaticInsertion)
                    && !SensitivityPolicy.allowance(sensitivity: .secure, surface: .clipboardFallback)
                    && !SensitivityPolicy.allowance(sensitivity: .secure, surface: .history))
            check("secure allows anonymous metrics", SensitivityPolicy.allowance(sensitivity: .secure, surface: .metrics))
        }
        do {
            check("unknown blocks automatic insertion", !SensitivityPolicy.allowance(sensitivity: .unknown, surface: .automaticInsertion))
            check("unknown blocks clipboard fallback", !SensitivityPolicy.allowance(sensitivity: .unknown, surface: .clipboardFallback))
            check("unknown blocks history", !SensitivityPolicy.allowance(sensitivity: .unknown, surface: .history))
            check("unknown blocks support bundle", !SensitivityPolicy.allowance(sensitivity: .unknown, surface: .supportBundle))
            check("normal allows insertion", SensitivityPolicy.allowance(sensitivity: .normal, surface: .automaticInsertion))
            let restricted = SessionSensitivityDecision(sensitivity: .unknown, source: .noEvidence, upgradedBeforeInsertion: false)
            let surfaces = SensitivityPolicy.restrictedSurfaces(for: restricted)
            check("restricted surfaces exhaustive & metrics preserved",
                  !surfaces.contains(where: { $0 == .metrics })
                    && surfaces.contains(.automaticInsertion)
                    && surfaces.contains(.history)
                    && surfaces.contains(.logs)
                    && surfaces.count == 7)
        }

        do {
            // exhaustive 3 sensitivity x 9 surface policy matrix
            var matrixOK = true
            for sens in SessionSensitivity.allCases {
                for surface in SessionPolicySurface.allCases {
                    let decision = SessionSensitivityDecision(sensitivity: sens, source: .noEvidence, upgradedBeforeInsertion: false)
                    let allowed = TranscriptStageGate.gate(decision: decision, surface: surface) == .allowed
                    switch sens {
                    case .normal:
                        if !allowed { matrixOK = false }
                    case .secure, .unknown:
                        let hardProhibited = surface == .automaticInsertion || surface == .clipboardFallback
                            || surface == .history || surface == .supportBundle || surface == .logs
                            || surface == .flowModes || surface == .uiPreview
                        if hardProhibited && allowed { matrixOK = false }
                        if (surface == .metrics || surface == .audioRetention) && !allowed { matrixOK = false }
                    }
                }
            }
            check("3x9 policy matrix exhaustive", matrixOK)
            // explicit copy is separate from automatic clipboard; audit is content-free
            let secure = SessionSensitivityDecision(sensitivity: .secure, source: .accessibilityRole, upgradedBeforeInsertion: true)
            check("explicit copy still allowed on secure", TranscriptStageGate.explicitCopyAllowed(decision: secure))
            let audit = TranscriptStageGate.recordExplicitCopy(decision: secure, now: Date(timeIntervalSince1970: 0))
            check("audit record content-free", audit.sensitivity == .secure && audit.timestampMillis == 0)
        }

        print("")
        if failed == 0 {
            print("All tests passed.")
            exit(0)
        } else {
            print("\(failed) test(s) failed.")
            exit(1)
        }
    }
}
