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

        // ===== JOE-2276: flow capability contract + honest naming =====
        do {
            let cap = FlowCapability.enhancedRules
            check("capability id is the canonical rules id", cap.id == FlowCapability.rulesCapabilityId)
            check("rules backend has no network", cap.networkUse == .none)
            check("rules backend has no weights", !cap.requiresModelWeights)
            check("deterministic rules pass the gate", cap.passesRulesGate)
            check("capability version declared", cap.version == "1.0")
            check("enhanced styles via capability", cap.eligibility(for: .professional) == .enhancedEligible
                  && cap.eligibility(for: .bullets) == .enhancedEligible
                  && cap.eligibility(for: .summary) == .enhancedEligible)
            check("clean/raw stay deterministic passthrough", cap.eligibility(for: .clean) == .passthroughOnly
                  && cap.eligibility(for: .raw) == .passthroughOnly)
            check("loss classes preserved", cap.lossClasses == Set(FlowLossClass.allCases))
        }
        do {
            // a future semantic backend cannot masquerade as rules
            let fakeSemantic = FlowCapability(
                id: "io.zephyr-flow.flow.semantic.llm.v1",
                version: "0.1",
                networkUse: .onDeviceDownloadsOnly,
                requiresModelWeights: true,
                isDeterministic: false,
                styles: [.clean, .professional, .bullets, .summary, .raw],
                enhancedStyles: [.professional, .bullets, .summary],
                lossClasses: Set(FlowLossClass.allCases),
                languages: ["en"],
                cancellation: .cooperative,
                resourceRequirement: .required(megabytes: 4096),
                entryGate: .semanticModelRequiresEvidence)
            check("semantic backend fails rules gate", !fakeSemantic.passesRulesGate && !fakeSemantic.isRulesCompatible)
            check("semantic backend requires evidence gate", fakeSemantic.entryGate == FlowBackendEntryGate.semanticModelRequiresEvidence)
        }
        do {
            // legacy settings value "neural" migrates to .enhanced; no public case
            check("legacy raw value decodes to enhanced", FlowBackend(rawValue: "neural") == .enhanced)
            // no enum CASE named .neural exists (compile-time); labels stay honest
            check("case labels are honest", FlowBackend.allCases.map { String(describing: $0) }.sorted() == ["auto", "enhanced", "regex"])
        }

        // ===== JOE-2247: bounded ordered audio channel =====
        do {
            let sid = SessionID(token: "1", sequence: 1, createdAtUptimeNanos: 0)
            let ch = BoundedAudioChannel(sessionID: sid, capacity: 64)
            var produced: [UInt64] = []
            for i in 0..<1000 {
                let chunk = AudioChunk(sessionID: sid, sequence: UInt64(i), startSample: UInt64(i) * 512,
                                       sampleRate: 16000, channelCount: 1, samples: [Float(i)])
                produced.append(chunk.sequence)
                _ = ch.enqueue(chunk)
            }
            var seen: [UInt64] = []
            var seq = AudioChunkSequencer()
            let consumer = Task {
                for await c in ch.chunks { seen.append(c.sequence); _ = seq.accept(c) }
            }
            ch.close()
            consumer.cancel()
            let stats = ch.stats()
            check("channel capacity respected (memory bounded)", stats.capacity == 64 && stats.enqueued == 64
                  && ch.occupancy == 64)
            // with no consumer, overflow must have dropped the excess (64 of them)
            check("overflow counted not silent", stats.overflowDropped == 936 && !seq.isDegraded)
        }
        do {
            let a = SessionID(token: "1", sequence: 1, createdAtUptimeNanos: 0)
            let b = SessionID(token: "2", sequence: 1, createdAtUptimeNanos: 0)
            let ch = BoundedAudioChannel(sessionID: a, capacity: 8)
            _ = ch.enqueue(AudioChunk(sessionID: b, sequence: 0, startSample: 0, sampleRate: 16000, channelCount: 1, samples: [0]))
            check("cross-session chunk rejected and counted", ch.stats().wrongSessionRejected == 1 && ch.isDegraded)
            _ = ch.close()
            _ = ch.enqueue(AudioChunk(sessionID: a, sequence: 0, startSample: 0, sampleRate: 16000, channelCount: 1, samples: [0]))
            check("closed channel counted", ch.stats().closedDropped == 1)
        }
        do {
            // determinism: exact order on the sequencer, gap and reorder detection
            var seq = AudioChunkSequencer()
            let sid = SessionID(token: "1", sequence: 1, createdAtUptimeNanos: 0)
            let c0 = AudioChunk(sessionID: sid, sequence: 0, startSample: 0, sampleRate: 16000, channelCount: 1, samples: [0])
            let c1 = AudioChunk(sessionID: sid, sequence: 1, startSample: 16, sampleRate: 16000, channelCount: 1, samples: [0])
            let c3 = AudioChunk(sessionID: sid, sequence: 3, startSample: 48, sampleRate: 16000, channelCount: 1, samples: [0])
            check("exact order accepted", seq.accept(c0) && seq.accept(c1))
            check("gap fast-forward counted", !seq.accept(c3) && seq.gaps == 1 && seq.nextExpected == 4)
            let c2 = AudioChunk(sessionID: sid, sequence: 2, startSample: 32, sampleRate: 16000, channelCount: 1, samples: [0])
            check("reordered counted", !seq.accept(c2) && seq.reordered == 1 && seq.isDegraded)
        }

        // ===== JOE-2259: secure/unknown review-only sessions =====
        do {
            let sid = SessionID(token: "r", sequence: 1, createdAtUptimeNanos: 0)
            let review = SecureSessionReview(sessionID: sid, text: "private draft", nowNanos: 1000, deadlineNanosAhead: 30_000)
            check("review holds content in memory only", review.text == "private draft")
            check("not expired before deadline", !review.expired(nowNanos: 1000 + 29_999))
            check("expired at deadline", review.expired(nowNanos: 1000 + 30_000))
            review.clear(reason: .deadlineExpired)
            check("content cleared on deadline", review.text == nil && review.clearReason == .deadlineExpired)
            let again = review.consumeForExplicitCopy(decision: SessionSensitivityDecision(sensitivity: .secure, source: .noEvidence, upgradedBeforeInsertion: false), nowNanos: 5000)
            check("cleared review cannot be copied", again == nil)
        }
        do {
            let sid = SessionID(token: "r", sequence: 2, createdAtUptimeNanos: 0)
            let review = SecureSessionReview(sessionID: sid, text: "private", nowNanos: 0, deadlineNanosAhead: 30_000)
            let decision = SessionSensitivityDecision(sensitivity: .secure, source: .noEvidence, upgradedBeforeInsertion: false)
            let taken = review.consumeForExplicitCopy(decision: decision, nowNanos: 1_500_000_000)
            check("explicit copy returns content once", taken?.text == "private" && taken?.audit.sensitivity == .secure)
            check("consumed review has no content", review.text == nil && review.clearReason == .consumedByExplicitCopy)
            check("second copy attempt refused", review.consumeForExplicitCopy(decision: decision, nowNanos: 2_000_000_000) == nil)
        }
        do {
            // conservative flow policy: professional/bullets/summary route to clean
            check("secure routes professional to clean", SensitiveSessionPolicy.conservativeStyle(for: .professional) == .clean)
            check("secure routes bullets to clean", SensitiveSessionPolicy.conservativeStyle(for: .bullets) == .clean)
            check("secure keeps clean", SensitiveSessionPolicy.conservativeStyle(for: .clean) == .clean)
            check("secure keeps raw", SensitiveSessionPolicy.conservativeStyle(for: .raw) == .raw)
            // automatic side effects fail closed for secure/unknown
            check("no auto paste for secure", !SensitiveSessionPolicy.autoPasteAllowed(sensitivity: .secure))
            check("no auto paste for unknown", !SensitiveSessionPolicy.autoPasteAllowed(sensitivity: .unknown))
            check("no history for unknown", !SensitiveSessionPolicy.historyWriteAllowed(sensitivity: .unknown))
            check("normal allows history", SensitiveSessionPolicy.historyWriteAllowed(sensitivity: .normal))
        }

        // ===== JOE-2268: deterministic target revalidation =====
        do {
            let sid = SessionID(token: "tv", sequence: 1, createdAtUptimeNanos: 0)
            func snapshot(_ sid: SessionID, secure: Bool = false, window: UInt32 = 77,
                          role: String = "AXTextField") -> TargetSnapshot {
                TargetSnapshot(
                    sessionID: sid, capturedAtUptimeNanos: 10_000,
                    target: .init(pid: 42, bundleID: "com.example.Editor",
                                  processStartUptimeNanos: 900, windowID: window, appVersion: "1.0"),
                    element: .init(role: secure ? "AXSecureTextField" : role, subrole: nil, resolutionToken: "el-1"),
                    settable: true, editable: true, enabled: true, selectionRange: nil,
                    sensitivity: .init(sensitivity: secure ? .secure : .normal,
                                       source: secure ? .accessibilityRole : .targetMetadata,
                                       capturedAtNanos: 10_000))
            }
            func ctx(pid: Int32 = 42, bundle: String? = "com.example.Editor",
                     start: UInt64? = 900, window: UInt32? = 77,
                     role: String = "AXTextField", token: String? = "el-1",
                     settable: Bool = true, editable: Bool = true, enabled: Bool = true,
                     sens: SessionSensitivity = .normal, now: UInt64 = 10_100) -> TargetValidationContext {
                TargetValidationContext(pid: pid, bundleID: bundle, processStartUptimeNanos: start,
                                        windowID: window,
                                        element: .init(role: role, subrole: nil, resolutionToken: token),
                                        settable: settable, editable: editable, enabled: enabled,
                                        sensitivity: .init(sensitivity: sens, source: .accessibilityRole,
                                                           capturedAtNanos: now),
                                        nowNanos: now)
            }

            var v = TargetValidationSession(sessionID: sid, snapshot: snapshot(sid), deadlineNanosAhead: 5_000)
            v.start(nowNanos: 10_000)
            check("2268 validated on identical context", v.validate(context: ctx(), nowNanos: 10_100) == .validated)
            check("2268 single-shot idempotent", v.validate(context: ctx(), nowNanos: 10_200) == .validated)
            check("2268 effective sensitivity normal", v.effectiveSensitivity == .normal && !v.upgradedBeforeInsertion)

            func outcome(_ snap: TargetSnapshot, _ context: TargetValidationContext?,
                         deadline: UInt64 = 5_000, startAt: UInt64 = 10_000, at: UInt64 = 10_100) -> (TargetValidationOutcome, TargetValidationReason?) {
                var s = TargetValidationSession(sessionID: sid, snapshot: snap, deadlineNanosAhead: deadline)
                s.start(nowNanos: startAt)
                _ = s.validate(context: context, nowNanos: at)
                return (s.outcome!, s.reason)
            }

            check("2268 window replaced => targetChanged",
                  outcome(snapshot(sid), ctx(window: 78)).0 == .targetChanged)
            check("2268 element token replaced => targetChanged",
                  outcome(snapshot(sid), ctx(token: "el-2")).0 == .targetChanged)
            check("2268 focus switched => targetChanged",
                  outcome(snapshot(sid), ctx(role: "AXTextArea")).0 == .targetChanged)
            check("2268 process gone => targetGone",
                  outcome(snapshot(sid), ctx(pid: 99, start: 300)).0 == .targetGone)
            check("2268 pid reuse => targetGone",
                  outcome(snapshot(sid), ctx(pid: 42, start: 901)).0 == .targetGone)
            check("2268 bundle changed => targetChanged",
                  outcome(snapshot(sid), ctx(pid: 1, bundle: "com.other.Editor", start: 900)).0 == .targetChanged)
            check("2268 not settable => notEditable",
                  outcome(snapshot(sid), ctx(settable: false)).0 == .notEditable)
            check("2268 secure reclass => secureTarget",
                  outcome(snapshot(sid), ctx(sens: .secure)).0 == .secureTarget)
            check("2268 unknown current => secureTarget",
                  outcome(snapshot(sid), ctx(sens: .unknown)).0 == .secureTarget)
            check("2268 no AX evidence => targetUnknown",
                  outcome(snapshot(sid), nil).0 == .targetUnknown)
            check("2268 secure captured never downgraded",
                  outcome(snapshot(sid, secure: true), ctx()).0 == .secureTarget)
            check("2268 deadline exceeded", outcome(snapshot(sid), ctx(), deadline: 5_000,
                                                    at: 10_000 + 5_001).0 == .deadlineExceeded)

            // most restrictive sensitivity helper
            check("2268 mostRestrictive normal<secure<unknown",
                  SessionSensitivity.mostRestrictive(.normal, .secure) == .secure
                    && SessionSensitivity.mostRestrictive(.secure, .unknown) == .unknown
                    && SessionSensitivity.mostRestrictive(.normal, .normal) == .normal)
        }
        // TargetRestoreMonitor: bounded observable restore (no blind sleep)
        do {
            var m = TargetRestoreMonitor(deadlineNanosAhead: 1_000, maxAttempts: 3)
            m.start(nowNanos: 0)
            if case .polling(let attempt, let remaining) = m.poll(isFrontmost: false, nowNanos: 100) {
                check("2268 restore polls within budget", attempt == 1 && remaining <= 900)
            } else {
                check("2268 restore polls within budget", false)
            }
            if case .restored = m.poll(isFrontmost: true, nowNanos: 200) {
                check("2268 restore restored once frontmost", true)
            } else {
                check("2268 restore restored once frontmost", false)
            }
            var d = TargetRestoreMonitor(deadlineNanosAhead: 1_000, maxAttempts: 3)
            d.start(nowNanos: 0)
            _ = d.poll(isFrontmost: false, nowNanos: 900)
            if case .deadlineExceeded = d.poll(isFrontmost: false, nowNanos: 1001) {
                check("2268 restore deadline exceeded", true)
            } else {
                check("2268 restore deadline exceeded", false)
            }
            var a = TargetRestoreMonitor(deadlineNanosAhead: 10_000, maxAttempts: 2)
            a.start(nowNanos: 0)
            _ = a.poll(isFrontmost: false, nowNanos: 100)
            if case .rejected(attempt: 2) = a.poll(isFrontmost: false, nowNanos: 200) {
                check("2268 restore attempt cap rejected", true)
            } else {
                check("2268 restore attempt cap rejected", false)
            }
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
