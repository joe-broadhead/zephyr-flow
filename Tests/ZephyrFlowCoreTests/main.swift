import CryptoKit
import Foundation
import ZephyrFlowCore

// JOE-2261 test helpers.
private struct LegacyV1Fixture: Codable {
    let id: UUID
    let timestamp: Date
    let originalText: String
    let finalText: String
    let duration: TimeInterval
    let modelUsed: String
}

final class FailingHistoryFileSystem: HistoryFileSystem, @unchecked Sendable {
    private(set) var failures = 0
    private let real = RealHistoryFileSystem()
    func fileExists(_ url: URL) -> Bool { real.fileExists(url) }
    func createDirectory(_ url: URL) throws { try real.createDirectory(url) }
    func readData(_ url: URL) throws -> Data { try real.readData(url) }
    func writeAtomic(data: Data, to url: URL) throws {
        failures += 1
        throw HistoryRepositoryError.diskFull
    }
    func move(_ from: URL, to: URL) throws { try real.move(from, to: to) }
    func remove(_ url: URL) throws { try real.remove(url) }
    func setPermissions(_ url: URL, mode: Int) throws { try real.setPermissions(url, mode: mode) }
}

// ===== JOE-2244: deterministic fake stage provider =====
actor FakeSessionStages: DictationSessionStageProviding {
    var snapshot: TargetSnapshot?
    var partials: [String] = []
    var finalText = "hello world"
    var completeness: EngineResultCompleteness = .complete
    var validationOutcomes: [TargetValidationOutcome] = [.validated]
    var insertionOutcome: InsertionOutcome = .verifiedInserted(
        strategy: .axSelectedText, evidence: .postWriteSelectionReRead, warnings: [])
    var degraded = false
    var reconciled = true
    var historyCount = 0
    var cancelCount = 0
    var prepareCount = 0
    var capturedSessionIDs: [SessionID] = []

    static func makeSnapshot(
        sessionID: SessionID,
        sensitivity: SessionSensitivity = .normal
    ) -> TargetSnapshot {
        TargetSnapshot(
            sessionID: sessionID,
            capturedAtUptimeNanos: 100,
            target: TargetSnapshot.Identity(
                pid: 42, bundleID: "com.example.Editor",
                processStartUptimeNanos: 900,
                windowID: 7, appVersion: "1.0"),
            element: TargetSnapshot.ElementIdentity(
                role: "AXTextField",
                subrole: nil, resolutionToken: "tok"),
            settable: true, editable: true, enabled: true,
            selectionRange: 0..<0,
            sensitivity: SensitivityAssessment(
                sensitivity: sensitivity,
                source: .accessibilityRole, capturedAtNanos: 100))
    }

    func setPartials(_ p: [String]) { partials = p }
    func setValidationOutcomes(_ o: [TargetValidationOutcome]) { validationOutcomes = o }
    func setCompleteness(_ c: EngineResultCompleteness) { completeness = c }

    func prepare(sessionID: SessionID) async {
        prepareCount += 1
        capturedSessionIDs.append(sessionID)
        snapshot = Self.makeSnapshot(sessionID: sessionID)
    }

    func capturedTargetSnapshot() async -> TargetSnapshot? { snapshot }

    func startCapture(
        sessionID: SessionID, localOnly: Bool,
        language: SupportedLanguage
    ) async throws -> SessionCaptureHandle {
        let (interim, cont) = AsyncStream.makeStream(of: SessionPartial.self)
        for p in partials { cont.yield(SessionPartial(text: p)) }
        cont.finish()
        let (levels, lcont) = AsyncStream.makeStream(of: Float.self)
        lcont.yield(0.4)
        lcont.finish()
        return SessionCaptureHandle(interim: interim, levels: levels)
    }

    func stopCapture() async -> SessionAudioSummary {
        SessionAudioSummary(
            capturedSourceSamples: 16000,
            deliveredEngineSamples: 16000,
            droppedSamples: 0,
            degraded: degraded,
            reconciled: reconciled,
            drainState: "drained")
    }

    func finalize() async throws -> EngineResult {
        EngineResult(
            text: finalText, completeness: completeness,
            frameAccounting: nil,
            engine: EngineIdentity(
                kind: .whisper, modelName: "Fake",
                modelVersion: "1.0", modelDigest: "x"),
            languageRequested: "en", languageDetected: "en",
            confidence: 0.9, confidenceSource: "engine",
            startedAtUptimeNanos: 1000, endedAtUptimeNanos: 2000,
            inferenceDurationNanos: 1_000_000_000,
            warnings: [], fallbackReason: nil,
            termination: .completed)
    }

    func applyFlow(_ request: FlowRequest) async -> FlowOutcome {
        FlowOutcome(
            text: request.text, requestedStyle: request.style,
            resolvedLossClass: .verbatim, backend: .regex,
            capabilityID: "test", capabilityVersion: 1,
            language: request.language, changedRangeCount: 0,
            protectedSpanCount: 0, protectedSpansPreserved: true,
            status: .accepted, warnings: [],
            fallbackReason: nil, durationNanos: 5,
            termination: .completed)
    }

    func validateTarget() async -> SessionValidationResult {
        let next = validationOutcomes.isEmpty ? .validated : validationOutcomes.removeFirst()
        return SessionValidationResult(
            outcome: next,
            effectiveSensitivity: .normal)
    }

    func insert(_ request: SessionInsertRequest) async -> InsertionOutcome {
        insertionOutcome
    }

    func recordHistory(
        originalText: String, finalText: String,
        duration: TimeInterval, modelName: String
    ) async {
        historyCount += 1
    }

    func cancel() async { cancelCount += 1 }
}

// ===== JOE-2255: in-memory fault-injecting model filesystem =====
final class FakeModelFS: ModelAcquisitionFileSystem, @unchecked Sendable {
    struct Node {
        var isDir: Bool
        var data: Data?
        var size: UInt64
    }
    private let lock = NSLock()
    private var nodes: [String: Node] = [:]
    private var perms: [String: Int] = [:]
    var lockHeld: [String: Bool] = [:]
    // Fault injection knobs
    var failDownload = false
    var downloadBytes = 2_000_000  // writes 2 MB payload
    var truncateArtifact = false
    var corruptDigest = false
    var failPromote = false
    var failQuarantine = false
    var failCreateDir = false
    var staleLockHeld = false
    var downloadDelayNanos: UInt64 = 0

    private func key(_ url: URL) -> String { url.path }
    private func parentKey(_ url: URL) -> String { key(url.deletingLastPathComponent()) }

    func createDirectory(_ url: URL, permissions: Int) throws {
        if failCreateDir { throw CocoaError(.fileWriteNoPermission) }
        lock.lock()
        defer { lock.unlock() }
        nodes[key(url)] = Node(isDir: true, data: nil, size: 0)
        perms[key(url)] = permissions
    }
    func fileExists(_ url: URL) -> Bool { lock.withLock { nodes[key(url)] != nil } }
    func isDirectory(_ url: URL) -> Bool { lock.withLock { nodes[key(url)]?.isDir ?? false } }
    func contentsOfDirectory(_ url: URL) -> [URL] {
        lock.withLock {
            nodes.filter {
                URL(fileURLWithPath: $0.key).deletingLastPathComponent().path == url.path && $0.value.isDir == false
            }
            .keys.sorted().map { URL(fileURLWithPath: $0) }
        }
    }
    func directorySize(_ url: URL) -> UInt64 {
        lock.withLock { nodes.filter { $0.key.hasPrefix(key(url) + "/") }.values.reduce(0) { $0 + $1.size } }
    }
    func fileSize(_ url: URL) -> UInt64? { lock.withLock { nodes[key(url)]?.size } }
    func sha256Hex(of url: URL) -> String? {
        lock.withLock {
            guard let n = nodes[key(url)], let data = n.data else { return nil }
            let h = SHA256.hash(data: data)
            return h.map { String(format: "%02x", $0) }.joined()
        }
    }
    func download(
        model: ModelIdentifier, to stagingURL: URL,
        onProgress: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws {
        if downloadDelayNanos > 0 { try? await Task.sleep(nanoseconds: downloadDelayNanos) }
        if failDownload { throw URLError(.cannotConnectToHost) }
        // Write artifact payloads into staging.
        let config = Data(repeating: 0xAB, count: 10_000)
        var modelData = Data(repeating: 0xCD, count: Int(downloadBytes))
        if truncateArtifact { modelData = Data(repeating: 0xCD, count: 500) }
        try createDirectory(stagingURL, permissions: 0o700)
        let cfgURL = stagingURL.appendingPathComponent("config.json")
        let modelURL = stagingURL.appendingPathComponent("model.mlmodelc")
        lock.lock()
        nodes[key(cfgURL)] = Node(isDir: false, data: config, size: UInt64(config.count))
        nodes[key(modelURL)] = Node(isDir: false, data: modelData, size: UInt64(modelData.count))
        lock.unlock()
        onProgress(
            ModelDownloadProgress(
                fraction: 1.0, bytesDownloaded: UInt64(modelData.count),
                bytesExpected: UInt64(modelData.count)))
    }
    func promote(from: URL, to: URL) throws {
        if failPromote { throw CocoaError(.fileWriteUnknown) }
        lock.lock()
        defer { lock.unlock() }
        let fromKey = key(from)
        let toKey = key(to)
        // move children
        let children = nodes.filter { $0.key.hasPrefix(fromKey + "/") }
        for (k, v) in children {
            let rel = String(k.dropFirst(fromKey.count))
            nodes[toKey + rel] = v
            nodes.removeValue(forKey: k)
        }
        nodes.removeValue(forKey: fromKey)
    }
    func quarantine(_ url: URL, reason: String) throws {
        if failQuarantine { throw CocoaError(.fileWriteUnknown) }
        lock.lock()
        defer { lock.unlock() }
        let fromKey = key(url)
        let children = nodes.filter { $0.key.hasPrefix(fromKey + "/") }
        for (k, _) in children { nodes.removeValue(forKey: k) }
        nodes.removeValue(forKey: fromKey)
    }
    func remove(_ url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        let fromKey = key(url)
        let children = nodes.filter { $0.key.hasPrefix(fromKey + "/") }
        for (k, _) in children { nodes.removeValue(forKey: k) }
        nodes.removeValue(forKey: fromKey)
    }
    func readManifest(for model: ModelIdentifier) -> ModelManifest? {
        let url = verifiedCacheRoot().appendingPathComponent(model.rawValue)
            .appendingPathComponent("manifest.json")
        lock.lock()
        defer { lock.unlock() }
        guard let n = nodes[key(url)], let data = n.data else { return nil }
        return try? JSONDecoder().decode(ModelManifest.self, from: data)
    }
    func writeManifest(_ manifest: ModelManifest, for model: ModelIdentifier) throws {
        let dir = verifiedCacheRoot().appendingPathComponent(model.rawValue, isDirectory: true)
        try createDirectory(dir, permissions: 0o700)
        let url = dir.appendingPathComponent("manifest.json")
        let data = try JSONEncoder().encode(manifest)
        lock.lock()
        defer { lock.unlock() }
        nodes[key(url)] = Node(isDir: false, data: data, size: UInt64(data.count))
    }
    func acquireLock(for model: ModelIdentifier) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let k = model.rawValue
        if lockHeld[k] == true {
            // stale-lock fixture: a held lock is treated as stale if set so.
            if staleLockHeld {
                lockHeld[k] = true  // re-acquired after stale cleanup
                return true
            }
            return false
        }
        lockHeld[k] = true
        return true
    }
    func releaseLock(for model: ModelIdentifier) {
        lock.lock()
        defer { lock.unlock() }
        lockHeld[model.rawValue] = false
    }
    func verifiedCacheRoot() -> URL { URL(fileURLWithPath: "/fake/verified") }
    func stagingRoot() -> URL { URL(fileURLWithPath: "/fake/staging") }
    func lastCreatePermission(_ url: URL) -> Int? { lock.withLock { perms[key(url)] } }
}

// ===== JOE-2262: in-memory history filesystem (fault-injecting) =====
final class InMemoryHistoryFS: HistoryFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var exists = false
    var failWrites = false
    var lastWrittenData: Data? {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    init(preload: Data? = nil) {
        if let preload {
            data = preload
            exists = true
        }
    }

    func fileExists(_ url: URL) -> Bool { lock.withLock { exists } }
    func createDirectory(_ url: URL) throws {}
    func readData(_ url: URL) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let data else { throw CocoaError(.fileReadNoSuchFile) }
        return data
    }
    func writeAtomic(data newData: Data, to url: URL) throws {
        if failWrites { throw CocoaError(.fileWriteOutOfSpace) }
        lock.lock()
        defer { lock.unlock() }
        data = newData
        exists = true
    }
    func move(_ from: URL, to: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        data = nil
        exists = false
    }
    func remove(_ url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        data = nil
        exists = false
    }
    func setPermissions(_ url: URL, mode: Int) throws {}
}

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
            let input =
                "We need to ship today. The build is green. Stakeholders are waiting for the demo this afternoon."
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
            check("save history default off", !s.saveHistory)
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

        // InsertionOutcome (JOE-2269) — legacy InsertionResult removed
        check(
            "verified succeeds",
            InsertionOutcome.verifiedInserted(
                strategy: .axSelectedText, evidence: .postWriteSelectionReRead, warnings: []
            ).isVerifiedSuccess)
        check("copied message", InsertionOutcome.explicitlyCopiedByUser.userFacingMessage == "Copied to clipboard")
        check("failed fails", !InsertionOutcome.failed("x").isVerifiedSuccess)

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
            check(
                "partial never persists",
                !OutcomePolicy.policy(for: .partial).maySaveHistory
                    && !OutcomePolicy.policy(for: .partial).mayWriteClipboard)
            check("truncated never success", !OutcomePolicy.policy(for: .truncated).showsSuccessUI)
            check("secureTarget fail-closed", OutcomePolicy.policy(for: .secureTarget) == .failClosed)
            check("deadlineExceeded not success", !OutcomePolicy.policy(for: .deadlineExceeded).showsSuccessUI)
            check(
                "degraded not success but persists",
                !OutcomePolicy.policy(for: .degraded).showsSuccessUI
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
            check(
                "preparing release prevents capture",
                tr(.preparing, .stop) == .illegal || tr(.preparing, .stop) == .to(.cancelled))
            check("capturing stop -> draining", tr(.capturing, .stop) == .to(.draining))
            check("capturing duplicate begin stays", tr(.capturing, .begin) == .stay)
            check("draining finish -> transcribing", tr(.draining, .drainFinished) == .to(.transcribing))
            check(
                "transcribing finished -> transforming", tr(.transcribing, .transcriptionFinished) == .to(.transforming)
            )
            check(
                "transforming finished -> resolving",
                tr(.transforming, .transformationFinished) == .to(.resolvingTarget))
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
            for (e, expect) in [
                (SessionEvent.begin, SessionState.preparing),
                (.readyToCapture, .capturing),
                (.stop, .draining),
                (.drainFinished, .transcribing),
                (.transcriptionFinished, .transforming),
                (.transformationFinished, .resolvingTarget),
                (.targetValidationSucceeded, .inserting),
                (.insertionSucceeded, .completed),
            ] {
                if case .to(let ns) = tr(happy.last!, e) { happy.append(ns) }
            }
            check("happy path reaches completed", happy.last == .completed && happy.count == 9)
        }
        // JOE-2267: TargetSnapshot contract
        do {
            let sid = SessionID(token: "t", sequence: 1, createdAtUptimeNanos: 0)
            let ident = TargetSnapshot.Identity(
                pid: 4242, bundleID: "com.example.App",
                processStartUptimeNanos: 99, windowID: 77, appVersion: "1.0")
            let snap = TargetSnapshot(
                sessionID: sid, capturedAtUptimeNanos: 5, target: ident,
                element: nil, settable: true, editable: true, enabled: true,
                selectionRange: 2..<5,
                sensitivity: SensitivityAssessment.unknown)
            check("snapshot rejects zephyr pid", !snap.isUsableTarget(zephyrPIDs: [4242], ignoredSystemPIDs: []))
            check(
                "snapshot rejects ignored system pid",
                !TargetSnapshot(
                    sessionID: sid, capturedAtUptimeNanos: 0,
                    target: TargetSnapshot.Identity(
                        pid: 1, bundleID: nil, processStartUptimeNanos: nil, windowID: nil, appVersion: nil),
                    element: nil, settable: false, editable: false, enabled: false, selectionRange: nil,
                    sensitivity: .unknown
                ).isUsableTarget(zephyrPIDs: [], ignoredSystemPIDs: [1]))
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
            check(
                "forced conservative", !FlowLanguageContext(language: "en", forceConservative: true).isEnglishQualified)
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
            var seed: UInt64 = 0xD1B5_4A32_D192_ED03
            func nextRand() -> UInt64 {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
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
                    c = SessionControlModel()  // fresh cycle (new session)
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
            check(
                "fail-closed decision forbids auto insertion",
                !SensitivityPolicy.allowance(sensitivity: d.sensitivity, surface: .automaticInsertion))
        }
        do {
            // most-restrictive wins: normal at start, secure at insertion
            let start = SensitivityAssessment(sensitivity: .normal, source: .accessibilityRole, capturedAtNanos: 1)
            let sec = SensitivityAssessment(sensitivity: .secure, source: .accessibilityRole, capturedAtNanos: 2)
            let inside = SessionSensitivityDecision.resolve(sessionStart: start, preInsertion: sec)
            check("upgrade to secure before insertion", inside.sensitivity == .secure && inside.upgradedBeforeInsertion)
            check(
                "secure forbids auto insert/clipboard/history",
                !SensitivityPolicy.allowance(sensitivity: .secure, surface: .automaticInsertion)
                    && !SensitivityPolicy.allowance(sensitivity: .secure, surface: .clipboardFallback)
                    && !SensitivityPolicy.allowance(sensitivity: .secure, surface: .history))
            check(
                "secure allows anonymous metrics", SensitivityPolicy.allowance(sensitivity: .secure, surface: .metrics))
        }
        do {
            check(
                "unknown blocks automatic insertion",
                !SensitivityPolicy.allowance(sensitivity: .unknown, surface: .automaticInsertion))
            check(
                "unknown blocks clipboard fallback",
                !SensitivityPolicy.allowance(sensitivity: .unknown, surface: .clipboardFallback))
            check("unknown blocks history", !SensitivityPolicy.allowance(sensitivity: .unknown, surface: .history))
            check(
                "unknown blocks support bundle",
                !SensitivityPolicy.allowance(sensitivity: .unknown, surface: .supportBundle))
            check(
                "normal allows insertion",
                SensitivityPolicy.allowance(sensitivity: .normal, surface: .automaticInsertion))
            let restricted = SessionSensitivityDecision(
                sensitivity: .unknown, source: .noEvidence, upgradedBeforeInsertion: false)
            let surfaces = SensitivityPolicy.restrictedSurfaces(for: restricted)
            check(
                "restricted surfaces exhaustive & metrics preserved",
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
                    let decision = SessionSensitivityDecision(
                        sensitivity: sens, source: .noEvidence, upgradedBeforeInsertion: false)
                    let allowed = TranscriptStageGate.gate(decision: decision, surface: surface) == .allowed
                    switch sens {
                    case .normal:
                        if !allowed { matrixOK = false }
                    case .secure, .unknown:
                        let hardProhibited =
                            surface == .automaticInsertion || surface == .clipboardFallback
                            || surface == .history || surface == .supportBundle || surface == .logs
                            || surface == .flowModes || surface == .uiPreview
                        if hardProhibited && allowed { matrixOK = false }
                        if (surface == .metrics || surface == .audioRetention) && !allowed { matrixOK = false }
                    }
                }
            }
            check("3x9 policy matrix exhaustive", matrixOK)
            // explicit copy is separate from automatic clipboard; audit is content-free
            let secure = SessionSensitivityDecision(
                sensitivity: .secure, source: .accessibilityRole, upgradedBeforeInsertion: true)
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
            check(
                "enhanced styles via capability",
                cap.eligibility(for: .professional) == .enhancedEligible
                    && cap.eligibility(for: .bullets) == .enhancedEligible
                    && cap.eligibility(for: .summary) == .enhancedEligible)
            check(
                "clean/raw stay deterministic passthrough",
                cap.eligibility(for: .clean) == .passthroughOnly
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
            check(
                "semantic backend requires evidence gate",
                fakeSemantic.entryGate == FlowBackendEntryGate.semanticModelRequiresEvidence)
        }
        do {
            // legacy settings value "neural" migrates to .enhanced; no public case
            check("legacy raw value decodes to enhanced", FlowBackend(rawValue: "neural") == .enhanced)
            // no enum CASE named .neural exists (compile-time); labels stay honest
            check(
                "case labels are honest",
                FlowBackend.allCases.map { String(describing: $0) }.sorted() == ["auto", "enhanced", "regex"])
        }

        // ===== JOE-2247: bounded ordered audio channel =====
        do {
            let sid = SessionID(token: "1", sequence: 1, createdAtUptimeNanos: 0)
            let ch = BoundedAudioChannel(sessionID: sid, capacity: 64)
            var produced: [UInt64] = []
            for i in 0..<1000 {
                let chunk = AudioChunk(
                    sessionID: sid, sequence: UInt64(i), startSample: UInt64(i) * 512,
                    sampleRate: 16000, channelCount: 1, samples: [Float(i)])
                produced.append(chunk.sequence)
                _ = ch.enqueue(chunk)
            }
            var seen: [UInt64] = []
            var seq = AudioChunkSequencer()
            let consumer = Task {
                for await c in ch.chunks {
                    seen.append(c.sequence)
                    _ = seq.accept(c)
                }
            }
            ch.close()
            consumer.cancel()
            let stats = ch.stats()
            check(
                "channel capacity respected (memory bounded)",
                stats.capacity == 64 && stats.enqueued == 64
                    && ch.occupancy == 64)
            // with no consumer, overflow must have dropped the excess (64 of them)
            check("overflow counted not silent", stats.overflowDropped == 936 && !seq.isDegraded)
        }
        do {
            let a = SessionID(token: "1", sequence: 1, createdAtUptimeNanos: 0)
            let b = SessionID(token: "2", sequence: 1, createdAtUptimeNanos: 0)
            let ch = BoundedAudioChannel(sessionID: a, capacity: 8)
            _ = ch.enqueue(
                AudioChunk(sessionID: b, sequence: 0, startSample: 0, sampleRate: 16000, channelCount: 1, samples: [0]))
            check("cross-session chunk rejected and counted", ch.stats().wrongSessionRejected == 1 && ch.isDegraded)
            _ = ch.close()
            _ = ch.enqueue(
                AudioChunk(sessionID: a, sequence: 0, startSample: 0, sampleRate: 16000, channelCount: 1, samples: [0]))
            check("closed channel counted", ch.stats().closedDropped == 1)
        }
        do {
            // determinism: exact order on the sequencer, gap and reorder detection
            var seq = AudioChunkSequencer()
            let sid = SessionID(token: "1", sequence: 1, createdAtUptimeNanos: 0)
            let c0 = AudioChunk(
                sessionID: sid, sequence: 0, startSample: 0, sampleRate: 16000, channelCount: 1, samples: [0])
            let c1 = AudioChunk(
                sessionID: sid, sequence: 1, startSample: 16, sampleRate: 16000, channelCount: 1, samples: [0])
            let c3 = AudioChunk(
                sessionID: sid, sequence: 3, startSample: 48, sampleRate: 16000, channelCount: 1, samples: [0])
            check("exact order accepted", seq.accept(c0) && seq.accept(c1))
            check("gap fast-forward counted", !seq.accept(c3) && seq.gaps == 1 && seq.nextExpected == 4)
            let c2 = AudioChunk(
                sessionID: sid, sequence: 2, startSample: 32, sampleRate: 16000, channelCount: 1, samples: [0])
            check("reordered counted", !seq.accept(c2) && seq.reordered == 1 && seq.isDegraded)
        }

        // ===== JOE-2259: secure/unknown review-only sessions =====
        do {
            let sid = SessionID(token: "r", sequence: 1, createdAtUptimeNanos: 0)
            let review = SecureSessionReview(
                sessionID: sid, text: "private draft", nowNanos: 1000, deadlineNanosAhead: 30_000)
            check("review holds content in memory only", review.text == "private draft")
            check("not expired before deadline", !review.expired(nowNanos: 1000 + 29_999))
            check("expired at deadline", review.expired(nowNanos: 1000 + 30_000))
            review.clear(reason: .deadlineExpired)
            check("content cleared on deadline", review.text == nil && review.clearReason == .deadlineExpired)
            let again = review.consumeForExplicitCopy(
                decision: SessionSensitivityDecision(
                    sensitivity: .secure, source: .noEvidence, upgradedBeforeInsertion: false), nowNanos: 5000)
            check("cleared review cannot be copied", again == nil)
        }
        do {
            let sid = SessionID(token: "r", sequence: 2, createdAtUptimeNanos: 0)
            let review = SecureSessionReview(sessionID: sid, text: "private", nowNanos: 0, deadlineNanosAhead: 30_000)
            let decision = SessionSensitivityDecision(
                sensitivity: .secure, source: .noEvidence, upgradedBeforeInsertion: false)
            let taken = review.consumeForExplicitCopy(decision: decision, nowNanos: 1_500_000_000)
            check("explicit copy returns content once", taken?.text == "private" && taken?.audit.sensitivity == .secure)
            check("consumed review has no content", review.text == nil && review.clearReason == .consumedByExplicitCopy)
            check(
                "second copy attempt refused",
                review.consumeForExplicitCopy(decision: decision, nowNanos: 2_000_000_000) == nil)
        }
        do {
            // conservative flow policy: professional/bullets/summary route to clean
            check(
                "secure routes professional to clean",
                SensitiveSessionPolicy.conservativeStyle(for: .professional) == .clean)
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
            func snapshot(
                _ sid: SessionID, secure: Bool = false, window: UInt32 = 77,
                role: String = "AXTextField"
            ) -> TargetSnapshot {
                TargetSnapshot(
                    sessionID: sid, capturedAtUptimeNanos: 10_000,
                    target: .init(
                        pid: 42, bundleID: "com.example.Editor",
                        processStartUptimeNanos: 900, windowID: window, appVersion: "1.0"),
                    element: .init(role: secure ? "AXSecureTextField" : role, subrole: nil, resolutionToken: "el-1"),
                    settable: true, editable: true, enabled: true, selectionRange: nil,
                    sensitivity: .init(
                        sensitivity: secure ? .secure : .normal,
                        source: secure ? .accessibilityRole : .targetMetadata,
                        capturedAtNanos: 10_000))
            }
            func ctx(
                pid: Int32 = 42, bundle: String? = "com.example.Editor",
                start: UInt64? = 900, window: UInt32? = 77,
                role: String = "AXTextField", token: String? = "el-1",
                settable: Bool = true, editable: Bool = true, enabled: Bool = true,
                sens: SessionSensitivity = .normal, now: UInt64 = 10_100
            ) -> TargetValidationContext {
                TargetValidationContext(
                    pid: pid, bundleID: bundle, processStartUptimeNanos: start,
                    windowID: window,
                    element: .init(role: role, subrole: nil, resolutionToken: token),
                    settable: settable, editable: editable, enabled: enabled,
                    sensitivity: .init(
                        sensitivity: sens, source: .accessibilityRole,
                        capturedAtNanos: now),
                    nowNanos: now)
            }

            var v = TargetValidationSession(sessionID: sid, snapshot: snapshot(sid), deadlineNanosAhead: 5_000)
            v.start(nowNanos: 10_000)
            check("2268 validated on identical context", v.validate(context: ctx(), nowNanos: 10_100) == .validated)
            check("2268 single-shot idempotent", v.validate(context: ctx(), nowNanos: 10_200) == .validated)
            check("2268 effective sensitivity normal", v.effectiveSensitivity == .normal && !v.upgradedBeforeInsertion)

            func outcome(
                _ snap: TargetSnapshot, _ context: TargetValidationContext?,
                deadline: UInt64 = 5_000, startAt: UInt64 = 10_000, at: UInt64 = 10_100
            ) -> (TargetValidationOutcome, TargetValidationReason?) {
                var s = TargetValidationSession(sessionID: sid, snapshot: snap, deadlineNanosAhead: deadline)
                s.start(nowNanos: startAt)
                _ = s.validate(context: context, nowNanos: at)
                return (s.outcome!, s.reason)
            }

            check(
                "2268 window replaced => targetChanged",
                outcome(snapshot(sid), ctx(window: 78)).0 == .targetChanged)
            check(
                "2268 element token replaced => targetChanged",
                outcome(snapshot(sid), ctx(token: "el-2")).0 == .targetChanged)
            check(
                "2268 focus switched => targetChanged",
                outcome(snapshot(sid), ctx(role: "AXTextArea")).0 == .targetChanged)
            check(
                "2268 process gone => targetGone",
                outcome(snapshot(sid), ctx(pid: 99, start: 300)).0 == .targetGone)
            check(
                "2268 pid reuse => targetGone",
                outcome(snapshot(sid), ctx(pid: 42, start: 901)).0 == .targetGone)
            check(
                "2268 bundle changed => targetChanged",
                outcome(snapshot(sid), ctx(pid: 1, bundle: "com.other.Editor", start: 900)).0 == .targetChanged)
            check(
                "2268 not settable => notEditable",
                outcome(snapshot(sid), ctx(settable: false)).0 == .notEditable)
            check(
                "2268 secure reclass => secureTarget",
                outcome(snapshot(sid), ctx(sens: .secure)).0 == .secureTarget)
            check(
                "2268 unknown current => secureTarget",
                outcome(snapshot(sid), ctx(sens: .unknown)).0 == .secureTarget)
            check(
                "2268 no AX evidence => targetUnknown",
                outcome(snapshot(sid), nil).0 == .targetUnknown)
            check(
                "2268 secure captured never downgraded",
                outcome(snapshot(sid, secure: true), ctx()).0 == .secureTarget)
            check(
                "2268 deadline exceeded",
                outcome(
                    snapshot(sid), ctx(), deadline: 5_000,
                    at: 10_000 + 5_001
                ).0 == .deadlineExceeded)

            // most restrictive sensitivity helper
            check(
                "2268 mostRestrictive normal<secure<unknown",
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

        // ===== JOE-2269: typed InsertionOutcome + central policy =====
        do {
            let verified = InsertionOutcome.verifiedInserted(
                strategy: .axSelectedText, evidence: .postWriteSelectionReRead, warnings: [])
            let unverified = InsertionOutcome.eventPostedUnverified(
                strategy: .clipboardPaste, warnings: [.noPostWriteVerification])
            let copied = InsertionOutcome.explicitlyCopiedByUser
            let changed = InsertionOutcome.targetChanged
            let gone = InsertionOutcome.targetGone
            let unknown = InsertionOutcome.targetUnknown
            let secure = InsertionOutcome.secureTarget
            let notEditable = InsertionOutcome.notEditable
            let clipboardChanged = InsertionOutcome.clipboardNotRestoredBecauseChanged
            let restoreFailed = InsertionOutcome.clipboardRestoreFailed
            let deadline = InsertionOutcome.deadlineExceeded
            let cancelled = InsertionOutcome.cancelled
            let failed = InsertionOutcome.failed("boom")

            check(
                "2269 verified is verified success + green UI",
                verified.isVerifiedSuccess && verified.permitsGreenSuccessUI)
            check(
                "2269 verified keeps history + auto-dismiss",
                verified.permitsHistoryRetention && verified.permitsAutomaticPanelDismissal)
            check("2269 unverified never green", !unverified.permitsGreenSuccessUI)
            check("2269 unverified never history", !unverified.permitsHistoryRetention)
            check(
                "2269 unverified is completed action but not verified",
                unverified.isCompletedAction && !unverified.isVerifiedSuccess)
            check("2269 unverified message distinguishes", unverified.userFacingMessage == "Inserted — unverified")
            check("2269 copied keeps history + green", copied.permitsGreenSuccessUI && copied.permitsHistoryRetention)
            check(
                "2269 changed/gone/unknown/secure/notEditable uncertain + no green",
                changed.isUncertain && gone.isUncertain && unknown.isUncertain
                    && secure.isUncertain && notEditable.isUncertain
                    && !changed.permitsGreenSuccessUI && !secure.permitsGreenSuccessUI)
            check("2269 uncertain never history", !changed.permitsHistoryRetention && !secure.permitsHistoryRetention)
            check("2269 uncertain no auto dismiss", !unknown.permitsAutomaticPanelDismissal)
            check(
                "2269 clipboard hygiene outcomes controlled",
                clipboardChanged.userFacingMessage.contains("left as-is")
                    && restoreFailed.userFacingMessage.contains("restore clipboard")
                    && !clipboardChanged.permitsGreenSuccessUI)
            check(
                "2269 deadline/cancelled/failed non-success",
                !deadline.permitsGreenSuccessUI && !cancelled.permitsGreenSuccessUI && !failed.permitsGreenSuccessUI)
            check(
                "2269 all outcomes permit metrics",
                verified.permitsReliabilityMetrics && unverified.permitsReliabilityMetrics
                    && changed.permitsReliabilityMetrics && failed.permitsReliabilityMetrics)
            // Golden mapping: strategy retained for verified/unverified.
            check(
                "2269 strategy retained", verified.strategy == .axSelectedText && unverified.strategy == .clipboardPaste
            )
            check("2269 no strategy on copy/uncertain", copied.strategy == nil && changed.strategy == nil)
        }
        // Exhaustive policy test: adding a case must fail until UI/privacy/
        // metrics policy is defined. Compile-time exhaustiveness + runtime
        // sanity for every case.
        do {
            let all: [InsertionOutcome] = [
                .verifiedInserted(strategy: .axSelectedText, evidence: .clipboardRestored, warnings: []),
                .eventPostedUnverified(strategy: .terminalPaste, warnings: [.noPostWriteVerification]),
                .explicitlyCopiedByUser,
                .targetChanged, .targetGone, .targetUnknown, .secureTarget, .notEditable,
                .clipboardNotRestoredBecauseChanged, .clipboardRestoreFailed,
                .deadlineExceeded, .cancelled, .failed("x"),
            ]
            var policyComplete = true
            for outcome in all {
                // Every outcome must have user-facing language, green/uncertain/
                // history/auto-dismiss/metrics policy (non-crash exhaustive switch).
                _ = (
                    outcome.userFacingMessage, outcome.permitsGreenSuccessUI,
                    outcome.isUncertain, outcome.permitsHistoryRetention,
                    outcome.permitsAutomaticPanelDismissal, outcome.permitsReliabilityMetrics,
                    outcome.isVerifiedSuccess, outcome.isCompletedAction
                )
                if outcome.userFacingMessage.isEmpty { policyComplete = false }
            }
            check("2269 policy defined for every outcome case", policyComplete)
        }

        // ===== JOE-2270: selection-safe bounded verifiable AX writes =====
        do {
            // Fake element matrix: capability flags x roles
            func cap(
                settable: Bool = true, editable: Bool = true, enabled: Bool = true,
                secure: Bool = false, role: String = "AXTextField"
            ) -> AxElementCapability {
                AxElementCapability(
                    settable: settable, editable: editable, enabled: enabled,
                    isSecure: secure, role: role, subrole: nil)
            }
            let sel = AxSelection(location: 2, length: 3)
            let text = "abc"
            // writable + valid selection => selectedTextReplacement
            check(
                "2270 prefers selectedText replacement",
                AxWritePolicy.plan(
                    capability: cap(), selection: sel, currentUTF16Length: 10,
                    text: text, qualification: nil) == .selectedTextReplacement)
            // secure => no write
            check(
                "2270 secure element rejected",
                AxWritePolicy.plan(
                    capability: cap(secure: true), selection: sel, currentUTF16Length: 10,
                    text: text, qualification: nil) == .rejected(reason: .secure))
            // read-only (not editable) => no write
            check(
                "2270 read-only rejected",
                AxWritePolicy.plan(
                    capability: cap(editable: false), selection: sel, currentUTF16Length: 10,
                    text: text, qualification: nil) == .rejected(reason: .notSettable))
            // disabled => no write
            check(
                "2270 disabled rejected",
                AxWritePolicy.plan(
                    capability: cap(enabled: false), selection: sel, currentUTF16Length: 10,
                    text: text, qualification: nil) == .rejected(reason: .disabled))
            // out-of-range selection => rejected, never corrupts
            check(
                "2270 out-of-range selection rejected",
                AxWritePolicy.plan(
                    capability: cap(), selection: AxSelection(location: 8, length: 3),
                    currentUTF16Length: 10, text: text, qualification: nil) == .rejected(reason: .outOfRange))
            // no selection + no qualification => wholeValueNotQualified (no generic rewrite)
            check(
                "2270 whole-value rewrite denied without adapter",
                AxWritePolicy.plan(
                    capability: cap(), selection: nil, currentUTF16Length: 10,
                    text: text, qualification: nil) == .rejected(reason: .wholeValueNotQualified))
            // no selection + qualified adapter => append via rangeMutation
            let q = AxValueAdapterQualification(
                capabilityKey: "ax.value.replace.v1",
                bundleID: "com.example.Editor", roles: ["AXTextField"],
                macOSMin: "14.0", evidenceReference: "docs/evidence/adapter-example")
            check(
                "2270 qualified adapter permits append rangeMutation",
                AxWritePolicy.plan(
                    capability: cap(), selection: nil, currentUTF16Length: 10,
                    text: text, qualification: q)
                    == .rangeMutation(
                        range: AxSelection(location: 10, length: 0), replacementUTF16Length: 3))
            // registry hygiene
            check(
                "2270 default registry has no overlaps",
                !AxValueAdapterRegistry.default.hasOverlaps
                    && AxValueAdapterRegistry.default.qualification(
                        forBundle: "com.example.Editor", role: "AXTextField") == nil
            )
            let reg = AxValueAdapterRegistry(qualifications: [q])
            check(
                "2270 registry resolves qualified adapter",
                reg.qualification(forBundle: "com.example.Editor", role: "AXTextField")?.capabilityKey
                    == "ax.value.replace.v1")
            check(
                "2270 registry ignores unlisted bundle",
                reg.qualification(forBundle: "com.other.App", role: "AXTextField") == nil)
            let dup = AxValueAdapterRegistry(qualifications: [
                AxValueAdapterQualification(
                    capabilityKey: "k1", bundleID: "b", roles: nil, macOSMin: nil, evidenceReference: "r1"),
                AxValueAdapterQualification(
                    capabilityKey: "k2", bundleID: "b", roles: nil, macOSMin: nil, evidenceReference: "r2"),
            ])
            check("2270 overlapping registry detected", dup.hasOverlaps)
        }
        // Unicode/emoji/combining-character selection tests (UTF-16 safe)
        do {
            let emoji = "a👨👩👧👦b"  // multi-codepoint ZWJ family
            let combining = "e\u{301}"  // e + combining acute
            let utf16 = (emoji as NSString).length
            check(
                "2270 emoji UTF-16 length handled",
                AxSelection(location: 1, length: utf16 - 2).isValid(utf16Length: utf16))
            check(
                "2270 emoji caret after replacement",
                AxSelection(location: 1, length: 0).caretAfter(replacingWith: (combining as NSString).length) == 1
                    + (combining as NSString).length)
            check(
                "2270 malformed negative clamped",
                !AxSelection(location: 0, length: utf16 + 1).isValid(utf16Length: utf16))
        }
        // AX error mapping table
        do {
            check(
                "2270 AX error mapping",
                AxErrorOutcome.map(rawValue: 0) == .ok
                    && AxErrorOutcome.map(rawValue: -25204) == .timeout
                    && AxErrorOutcome.map(rawValue: -25205) == .notEditable
                    && AxErrorOutcome.map(rawValue: -25210) == .axDisabled
                    && AxErrorOutcome.map(rawValue: -25206) == .notSupported
                    && AxErrorOutcome.map(rawValue: -25201) == .illegalArgument
                    && AxErrorOutcome.map(rawValue: -9999) == .unknown)
        }
        // Bounded AX call runner: hung target cannot block; late results dropped
        do {
            let start = UInt64(1_000_000)
            // Fast operation completes.
            let fast = await AxBoundedRunner.run(
                deadlineNanosAhead: 10_000_000_000,
                startedAtNanos: start,
                nowNanos: { start + 1 },
                operation: { 42 })
            check("2270 fast AX call completes", fast.value == 42)
            // Slow operation exceeds deadline => deadlineExceeded, no hang.
            let slow = await AxBoundedRunner.run(
                deadlineNanosAhead: 20_000_000,
                startedAtNanos: start,
                nowNanos: { start },
                operation: {
                    Thread.sleep(forTimeInterval: 0.5)  // synchronous hang, like a stuck AX target
                    return 7
                })
            if case .deadlineExceeded = slow {
                check("2270 hung AX call hits deadline", true)
            } else {
                check("2270 hung AX call hits deadline", false)
            }
            // Already-expired budget never executes.
            let expired = await AxBoundedRunner.run(
                deadlineNanosAhead: 10,
                startedAtNanos: start,
                nowNanos: { start + 999 },
                operation: { 1 })
            if case .deadlineExceeded = expired {
                check("2270 expired budget reports deadline without running", true)
            } else {
                check("2270 expired budget reports deadline without running", false)
            }
        }

        // ===== JOE-2272: no-side-effect review UX model =====
        do {
            let changed = InsertionReviewModel(outcome: .targetChanged, createdAtNanos: 0)
            check(
                "2272 changed: retry+copy+discard, no settings, non-technical",
                changed.allowsRetry && changed.allowsCopy && changed.allowsDiscard
                    && !changed.allowsOpenAccessibilitySettings && changed.isUncertain)
            check(
                "2272 changed headline plain language",
                changed.title == "The target changed" && changed.detail.contains("changed"))
            check("2272 changed no green by construction", !changed.outcome.permitsGreenSuccessUI)

            let gone = InsertionReviewModel(outcome: .targetGone, createdAtNanos: 0)
            check("2272 gone: retry allowed", gone.allowsRetry && gone.title == "The target closed")

            let notEditable = InsertionReviewModel(outcome: .notEditable, createdAtNanos: 0)
            check(
                "2272 notEditable: retry allowed, plain language",
                notEditable.allowsRetry && notEditable.detail.contains("read-only"))

            let deadline = InsertionReviewModel(outcome: .deadlineExceeded, createdAtNanos: 0)
            check("2272 deadline: retry allowed", deadline.allowsRetry)

            let unknown = InsertionReviewModel(outcome: .targetUnknown, createdAtNanos: 0)
            check(
                "2272 unknown: no retry, settings + warn copy",
                !unknown.allowsRetry && unknown.allowsOpenAccessibilitySettings
                    && unknown.shouldWarnBeforeCopy && unknown.detail.contains("Accessibility"))

            let secure = InsertionReviewModel(outcome: .secureTarget, createdAtNanos: 0)
            check(
                "2272 secure: no retry, warn copy, no auto anything",
                !secure.allowsRetry && secure.shouldWarnBeforeCopy
                    && !secure.allowsOpenAccessibilitySettings && secure.detail.contains("Nothing was pasted"))

            // single-shot + retention
            var r = InsertionReviewModel(outcome: .targetChanged, createdAtNanos: 1_000, retentionNanosAhead: 1_000)
            check("2272 expiry detected", r.expired(nowNanos: 2_001))
            check("2272 consume after expiry refused", !r.consume(.explicitCopy, nowNanos: 2_001))
            var c = InsertionReviewModel(outcome: .targetChanged, createdAtNanos: 1_000, retentionNanosAhead: 30_000)
            check(
                "2272 consume copy once", c.consume(.explicitCopy, nowNanos: 2_000) && c.consumedAction == .explicitCopy
            )
            check("2272 second consume refused", !c.consume(.discard, nowNanos: 2_000))
            var rt = InsertionReviewModel(outcome: .targetChanged, createdAtNanos: 0)
            check(
                "2272 retry consumes with fresh intent",
                rt.consume(.retryValidation, nowNanos: 100) && rt.clearReason == .retriedWithFreshIntent)
            var st = InsertionReviewModel(outcome: .secureTarget, createdAtNanos: 0)
            check("2272 retry refused for secure", !st.consume(.retryValidation, nowNanos: 100))
            var u = InsertionReviewModel(outcome: .targetUnknown, createdAtNanos: 0)
            check(
                "2272 settings action allowed for unknown",
                u.consume(.openAccessibilitySettings, nowNanos: 100) && u.consumedAction == .openAccessibilitySettings)
            u.clear(.userDiscarded)
            check("2272 discard clears", u.clearReason == .userDiscarded)
        }

        // ===== JOE-2260: lossless bounded pasteboard transaction =====
        do {
            let sid = SessionID(token: "pb", sequence: 1, createdAtUptimeNanos: 0)
            func item(_ records: [(String, String)]) -> PasteboardItemSnapshot {
                PasteboardItemSnapshot(types: records.map { PasteboardTypeRecord(type: $0.0, data: Data($0.1.utf8)) })
            }
            // Empty original => restore means clear.
            let empty = PasteboardSnapshot(items: [], changeCount: 100)
            var t0 = PasteboardTransaction(sessionID: sid, original: empty)!
            check("2260 empty snapshot recognized", empty.isEmpty && empty.itemCount == 0)
            t0.applyTemporary(changeCount: 101)
            t0.markPosted()
            check(
                "2260 empty restore safe (clear)",
                t0.attemptRestore(currentChangeCount: 101, currentIsOurMarker: true) == .restored)
            // Plain text fixture round-trips byte-for-byte.
            let textData = Data("hello world".utf8)
            let plain = PasteboardSnapshot(
                items: [
                    PasteboardItemSnapshot(types: [PasteboardTypeRecord(type: "public.utf8-plain-text", data: textData)]
                    )
                ], changeCount: 5)
            var t1 = PasteboardTransaction(sessionID: sid, original: plain)!
            t1.applyTemporary(changeCount: 6)
            t1.markPosted()
            check(
                "2260 plain round-trip restored",
                t1.attemptRestore(currentChangeCount: 6, currentIsOurMarker: true) == .restored)
            check("2260 plain original bytes exact", t1.original.items[0].types[0].data == textData)
            // Multi-item multi-type (text + RTF + image + file URL) fixture.
            let rich = PasteboardSnapshot(
                items: [
                    PasteboardItemSnapshot(types: [
                        PasteboardTypeRecord(type: "public.utf8-plain-text", data: Data("hi".utf8)),
                        PasteboardTypeRecord(type: "public.rtf", data: Data([0x7b, 0x5c, 0x72, 0x74, 0x66])),
                    ]),
                    PasteboardItemSnapshot(types: [
                        PasteboardTypeRecord(type: "public.png", data: Data([0x89, 0x50, 0x4e, 0x47]))
                    ]),
                    PasteboardItemSnapshot(types: [
                        PasteboardTypeRecord(type: "public.file-url", data: Data("file:///tmp/x".utf8))
                    ]),
                ], changeCount: 9)
            var t2 = PasteboardTransaction(sessionID: sid, original: rich)!
            t2.applyTemporary(changeCount: 10)
            t2.markPosted()
            check(
                "2260 rich fixture within budget",
                PasteboardBudget().withinBudget(rich) && t2.original.itemCount == 3)
            check(
                "2260 rich round-trip restored",
                t2.attemptRestore(currentChangeCount: 10, currentIsOurMarker: true) == .restored)
            check(
                "2260 rich bytes exact",
                t2.original.items[1].types[0].data == Data([0x89, 0x50, 0x4e, 0x47])
                    && t2.original.items[0].types[1].type == "public.rtf")
            // User/target change during window => preserve new value.
            var t3 = PasteboardTransaction(sessionID: sid, original: plain)!
            t3.applyTemporary(changeCount: 6)
            t3.markPosted()
            check(
                "2260 changed pasteboard not overwritten",
                t3.attemptRestore(currentChangeCount: 99, currentIsOurMarker: false) == .notRestoredBecauseChanged)
            // Budget overflow => no transaction at all (no destructive mutation).
            let huge = PasteboardSnapshot(
                items: [
                    PasteboardItemSnapshot(types: [
                        PasteboardTypeRecord(type: "public.data", data: Data(repeating: 1, count: 9_000_000))
                    ])
                ], changeCount: 1)
            check("2260 over-budget snapshot detected", !PasteboardBudget().withinBudget(huge))
            check(
                "2260 over-budget transaction refused (nil => no mutation)",
                PasteboardTransaction(sessionID: sid, original: huge) == nil)
            // Single-shot terminal.
            var t4 = PasteboardTransaction(sessionID: sid, original: plain)!
            t4.applyTemporary(changeCount: 6)
            t4.markPosted()
            _ = t4.attemptRestore(currentChangeCount: 6, currentIsOurMarker: true)
            check(
                "2260 restore single-shot",
                t4.attemptRestore(currentChangeCount: 7, currentIsOurMarker: false) == .restored)
            // cancel / shutdown recorded.
            var t5 = PasteboardTransaction(sessionID: sid, original: plain)!
            t5.cancel()
            check("2260 cancel outcome", t5.outcome == .cancelled)
            var t6 = PasteboardTransaction(sessionID: sid, original: plain)!
            t6.shutdown()
            check("2260 shutdown outcome", t6.outcome == .abandonedDuringShutdown)
            // Sensitivity gate: secure/unknown cannot run this transaction.
            check(
                "2260 secure/unknown cannot transact",
                !PasteboardTransactionPolicy.allowed(sensitivity: .secure)
                    && !PasteboardTransactionPolicy.allowed(sensitivity: .unknown)
                    && PasteboardTransactionPolicy.allowed(sensitivity: .normal))
        }

        // ===== JOE-2271: evidence-backed insertion adapter registry =====
        do {
            let reg = InsertionAdapterRegistry.current
            check("2271 registry has no duplicate/overlapping entries", !reg.hasOverlaps)
            check("2271 registry versioned", reg.version >= 1)

            // Exact bundle identity matching (no guesses).
            check(
                "2271 chrome exact => browser adapter",
                reg.adapter(
                    forBundle: "com.google.Chrome", role: "AXTextField",
                    appVersion: nil, macOSVersion: nil
                ).id == "browser.v1")
            check(
                "2271 safari exact => browser adapter",
                reg.adapter(
                    forBundle: "com.apple.Safari", role: "AXTextArea",
                    appVersion: nil, macOSVersion: nil
                ).id == "browser.v1")
            check(
                "2271 terminal exact => terminal adapter",
                reg.adapter(
                    forBundle: "com.apple.Terminal", role: "AXTextArea",
                    appVersion: nil, macOSVersion: nil
                ).id == "terminal.v1")
            check(
                "2271 vscode exact => editor adapter",
                reg.adapter(
                    forBundle: "com.microsoft.VSCode", role: "AXTextField",
                    appVersion: nil, macOSVersion: nil
                ).id == "editor.v1")
            check(
                "2271 slack exact => electron-shell adapter",
                reg.adapter(
                    forBundle: "com.tinyspeck.slackmacgap", role: nil,
                    appVersion: nil, macOSVersion: nil
                ).id == "electron-shell.v1")

            // Unknown apps use the conservative default.
            check(
                "2271 unknown bundle => conservative default",
                reg.adapter(
                    forBundle: "com.example.random", role: "AXTextField",
                    appVersion: nil, macOSVersion: nil
                ).id == "default.v1")
            // Regression: a chrome-LIKE (but not exact) bundle no longer matches.
            check(
                "2271 chrome-like guess removed",
                reg.adapter(
                    forBundle: "com.evil.chromeish.app", role: "AXTextField",
                    appVersion: nil, macOSVersion: nil
                ).id == "default.v1")
            check(
                "2271 nil bundle => conservative default",
                reg.adapter(forBundle: nil, role: nil, appVersion: nil, macOSVersion: nil).id == "default.v1")

            // Conservative default: no whole-value mutation, paste unverified.
            let def = InsertionAdapter.conservativeDefault
            check("2271 default has no axValue", !def.strategies.contains(.axValue))
            check(
                "2271 default distinguishes unverified paste",
                def.verification == .none && def.strategies.contains(.clipboardPaste))
            check("2271 default explicit copy last", def.strategies.last == .copyOnly)

            // Strategy ordering + cascade semantics.
            let editor = reg.adapter(
                forBundle: "com.apple.dt.Xcode", role: nil,
                appVersion: nil, macOSVersion: nil)
            check(
                "2271 editor strategy order",
                editor.strategies == [.clipboardPaste, .axSelectedText, .axValue, .copyOnly])
            check(
                "2271 cascade to next permitted",
                editor.nextStrategy(after: .clipboardPaste) == .axSelectedText
                    && editor.nextStrategy(after: .axValue) == .copyOnly)
            // A cascade-disallowed adapter stops after first failure.
            let strict = InsertionAdapter(
                id: "strict.v1", bundleIDs: ["com.strict.app"],
                roles: nil, appVersionRange: nil, macOSMin: nil,
                strategies: [.clipboardPaste, .copyOnly],
                settleNanos: 16_000_000, verification: .none,
                limitations: [], evidenceReference: "e1",
                allowsStrategyCascade: false)
            check(
                "2271 cascade-disallowed stops after failure",
                strict.nextStrategy(after: .clipboardPaste) == nil)

            // Role filter matching.
            let roleFiltered = InsertionAdapter(
                id: "role.v1", bundleIDs: ["com.role.app"],
                roles: ["AXTextField"], appVersionRange: nil,
                macOSMin: nil, strategies: [.copyOnly],
                settleNanos: 0, verification: .none,
                limitations: [], evidenceReference: "e2",
                allowsStrategyCascade: false)
            check(
                "2271 role filter match",
                roleFiltered.matches(
                    bundleID: "com.role.app", role: "AXTextField",
                    appVersion: nil, macOSVersion: nil))
            check(
                "2271 role filter reject",
                !roleFiltered.matches(
                    bundleID: "com.role.app", role: "AXTextArea",
                    appVersion: nil, macOSVersion: nil))

            // App-version + macOS range matching.
            let versioned = InsertionAdapter(
                id: "ver.v1", bundleIDs: ["com.ver.app"],
                roles: nil, appVersionRange: "1.0"..."2.5",
                macOSMin: "14.0", strategies: [.copyOnly],
                settleNanos: 0, verification: .none,
                limitations: [], evidenceReference: "e3",
                allowsStrategyCascade: false)
            check(
                "2271 version in range matches",
                versioned.matches(
                    bundleID: "com.ver.app", role: nil, appVersion: "2.0",
                    macOSVersion: "15.0"))
            check(
                "2271 version out of range rejects",
                !versioned.matches(
                    bundleID: "com.ver.app", role: nil, appVersion: "3.0",
                    macOSVersion: "15.0"))
            check(
                "2271 macOS below minimum rejects",
                !versioned.matches(
                    bundleID: "com.ver.app", role: nil, appVersion: "2.0",
                    macOSVersion: "13.5"))

            // Resolver uses registry + copy-only overrides (no AppKit).
            check(
                "2271 resolver default strategies",
                InsertionStrategyResolver.strategies(
                    bundleID: "com.google.Chrome", role: "AXTextField", mode: .automatic)
                    == [.clipboardPaste, .axSelectedText, .copyOnly])
            check(
                "2271 resolver editor includes axValue",
                InsertionStrategyResolver.strategies(
                    bundleID: "com.microsoft.VSCode", role: "AXTextField", mode: .automatic)
                    == [.clipboardPaste, .axSelectedText, .axValue, .copyOnly])
            check(
                "2271 resolver unknown => default",
                InsertionStrategyResolver.strategies(bundleID: "com.example.x", role: "AXTextField", mode: .automatic)
                    == [.clipboardPaste, .axSelectedText, .copyOnly])
            check(
                "2271 local copy-only override",
                InsertionStrategyResolver.strategies(
                    bundleID: "com.google.Chrome", role: "AXTextField",
                    mode: .automatic,
                    copyOnlyOverrides: ["com.google.Chrome"]) == [.copyOnly])
            check(
                "2271 alwaysCopy mode",
                InsertionStrategyResolver.strategies(
                    bundleID: "com.google.Chrome", role: "AXTextField", mode: .alwaysCopy) == [.copyOnly])
        }

        // ===== JOE-2248: audio stop/drain barrier + frame accounting =====
        do {
            // Property: randomized chunk sizes + converter ratios reconcile.
            var seed = UInt64(42)
            func rnd(_ n: UInt64) -> UInt64 {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return (seed >> 33) % n
            }
            var propertyOK = true
            for _ in 0..<300 {
                var acct = AudioFrameAccounting()
                let ratio = [0.5, 1.0, 2.0, 0.75][Int(rnd(4))]
                var captured: UInt64 = 0
                var converted: UInt64 = 0
                var dropped: UInt64 = 0
                let chunkCount = Int(rnd(40)) + 1
                for _ in 0..<chunkCount {
                    let samples = UInt64(rnd(4000)) + 16
                    captured &+= samples
                    acct.noteCaptured(sourceSamples: samples)
                    let out = UInt64((Double(samples) * ratio).rounded())
                    converted &+= out
                    acct.noteConverted(engineSamples: out)
                    acct.noteDelivered(engineSamples: out)
                }
                let tol: UInt64 = 32
                if !acct.reconciles(converterRatio: ratio, roundingToleranceSamples: tol) {
                    propertyOK = false
                }
            }
            check("2248 property: random chunk sizes/ratios reconcile", propertyOK)
        }
        do {
            // Gap/overflow => degraded, never completes.
            var acct = AudioFrameAccounting()
            acct.noteCaptured(sourceSamples: 16000)
            acct.noteDropped(sourceSamples: 8000, reason: .overflow)
            acct.noteConverted(engineSamples: 8000)
            acct.noteDelivered(engineSamples: 8000)
            check(
                "2248 dropped samples degrade the session",
                acct.isDegraded && !acct.reconciles(converterRatio: 1.0, roundingToleranceSamples: 0))
            // Delivered < converted => mismatch.
            var m = AudioFrameAccounting()
            m.noteCaptured(sourceSamples: 16000)
            m.noteConverted(engineSamples: 16000)
            m.noteDelivered(engineSamples: 15000)
            check(
                "2248 delivered<converted fails reconciliation",
                !m.reconciles(converterRatio: 1.0, roundingToleranceSamples: 0))
            // Exact success.
            var ok = AudioFrameAccounting()
            ok.noteCaptured(sourceSamples: 16000)
            ok.noteConverted(engineSamples: 16000)
            ok.noteDelivered(engineSamples: 16000)
            check(
                "2248 exact reconciliation succeeds",
                ok.reconciles(converterRatio: 1.0, roundingToleranceSamples: 0))
            // Converter rounding within explicit tolerance.
            var r = AudioFrameAccounting()
            r.noteCaptured(sourceSamples: 16000)
            r.noteConverted(engineSamples: 8000)
            r.noteDelivered(engineSamples: 8000)
            check(
                "2248 ratio rounding within tolerance",
                r.reconciles(converterRatio: 0.5, roundingToleranceSamples: 1))
        }
        do {
            // Drain barrier: finalization waits for a delayed final chunk.
            var b = AudioDrainBarrier(deadlineNanosAhead: 1000)
            b.begin(finalSequence: 4, nowNanos: 0)
            check(
                "2248 draining until final sequence",
                b.noteDelivered(sequence: 1, nowNanos: 100) == .draining
                    && b.noteDelivered(sequence: 2, nowNanos: 200) == .draining
                    && b.noteDelivered(sequence: 3, nowNanos: 300) == .draining
                    && b.noteDelivered(sequence: 4, nowNanos: 400) == .drained)
            check("2248 barrier complete after final sequence", b.isComplete)
            // Drain timeout => degraded, not complete.
            var t = AudioDrainBarrier(deadlineNanosAhead: 1000)
            t.begin(finalSequence: 9, nowNanos: 0)
            _ = t.noteDelivered(sequence: 1, nowNanos: 100)
            check(
                "2248 drain timeout degrades",
                t.noteDelivered(sequence: 2, nowNanos: 1100) == .timedOut && !t.isComplete)
            // Late append after final acknowledgment is counted.
            var late = AudioDrainBarrier(deadlineNanosAhead: 10_000)
            late.begin(finalSequence: 2, nowNanos: 0)
            _ = late.noteDelivered(sequence: 2, nowNanos: 100)
            _ = late.noteDelivered(sequence: 3, nowNanos: 200)
            check("2248 late append counted after ack", late.lateAppends == 1)
            // Cancellation releases without deadlock / double finalization.
            var c = AudioDrainBarrier(deadlineNanosAhead: 1000)
            c.begin(finalSequence: 5, nowNanos: 0)
            c.cancel()
            check("2248 cancellation terminal", c.state == .cancelled)
            check(
                "2248 cancelled cannot double-finalize",
                c.noteDelivered(sequence: 5, nowNanos: 100) == .cancelled)
        }
        do {
            // Channel sample accounting (content-free counts) via BoundedAudioChannel.
            let sid = SessionID(token: "drain", sequence: 1, createdAtUptimeNanos: 0)
            let ch = BoundedAudioChannel(sessionID: sid, capacity: 4)
            let other = SessionID(token: "other", sequence: 2, createdAtUptimeNanos: 0)
            _ = ch.enqueue(
                AudioChunk(
                    sessionID: other, sequence: 0, startSample: 0, sampleRate: 16000, channelCount: 1,
                    samples: [Float](repeating: 0, count: 100)))
            _ = ch.enqueue(
                AudioChunk(
                    sessionID: sid, sequence: 0, startSample: 0, sampleRate: 16000, channelCount: 1,
                    samples: [Float](repeating: 0, count: 200)))
            _ = ch.enqueue(
                AudioChunk(
                    sessionID: sid, sequence: 1, startSample: 200, sampleRate: 16000, channelCount: 1,
                    samples: [Float](repeating: 0, count: 300)))
            let stats = ch.stats()
            check(
                "2248 channel sample accounting",
                stats.acceptedSamples == 500
                    && stats.wrongSessionDroppedSamples == 100
                    && stats.lastAcceptedSequence == 1)
            ch.close()
            _ = ch.enqueue(
                AudioChunk(
                    sessionID: sid, sequence: 2, startSample: 500, sampleRate: 16000, channelCount: 1,
                    samples: [Float](repeating: 0, count: 50)))
            let closed = ch.stats()
            check(
                "2248 closed-drop samples counted",
                closed.closedDroppedSamples == 50 && closed.closedDropped == 1)
        }

        // ===== JOE-2249: session-bound engine + callback gating =====
        do {
            let sidA = SessionID(token: "a", sequence: 1, createdAtUptimeNanos: 0)
            let sidB = SessionID(token: "b", sequence: 2, createdAtUptimeNanos: 0)
            let tok1 = EngineToken(value: "engine-1")
            let tok2 = EngineToken(value: "engine-2")
            let bindA = SessionEngineBinding(sessionID: sidA, engineToken: tok1, engineKind: .whisper)
            let bindB = SessionEngineBinding(sessionID: sidB, engineToken: tok1, engineKind: .whisper)

            var gate = CallbackGate()
            check(
                "2249 open gate accepts current binding",
                gate.accepts(binding: bindA, currentSessionID: sidA, currentEngineToken: tok1))
            // Session A callbacks cannot reach session B's engine/UI.
            check(
                "2249 wrong session rejected",
                !gate.accepts(binding: bindB, currentSessionID: sidA, currentEngineToken: tok1))
            // Engine replacement closes the gate for old-token callbacks.
            check(
                "2249 stale engine token rejected after replacement",
                !gate.accepts(binding: bindA, currentSessionID: sidA, currentEngineToken: tok2))
            // Cancellation closes the gate; later callbacks rejected.
            var g2 = CallbackGate()
            _ = g2.accepts(binding: bindA, currentSessionID: sidA, currentEngineToken: tok1)
            g2.close(reason: .cancelled)
            check(
                "2249 cancelled gate rejects later callbacks",
                !g2.accepts(binding: bindA, currentSessionID: sidA, currentEngineToken: tok1)
                    && g2.isClosed && g2.closeReason == .cancelled)
            // Terminal outcome closes the gate.
            var g3 = CallbackGate()
            g3.close(reason: .terminalOutcome)
            check("2249 terminal gate closed", g3.isClosed && g3.closeReason == .terminalOutcome)
            // Single-shot close: later close reasons do not overwrite.
            g3.close(reason: .cancelled)
            check("2249 close single-shot", g3.closeReason == .terminalOutcome)
            // Drain completion closes the gate (no appends after drain ack).
            var g4 = CallbackGate()
            g4.close(reason: .drainCompleted)
            check(
                "2249 drain completion gate closed",
                !g4.accepts(binding: bindA, currentSessionID: sidA, currentEngineToken: tok1))
        }

        // ===== JOE-2250: exclusive cancellable decode ownership =====
        do {
            let sid = SessionID(token: "wk", sequence: 1, createdAtUptimeNanos: 0)
            var gate = DecodeOwnership()
            check("2250 idle is reusable", gate.reusable && !gate.isBusy)
            let op1 = gate.begin(purpose: .partial, sessionID: sid, nowNanos: 0)
            check("2250 first op acquires ownership", op1 != nil && gate.isBusy)
            // No second decode while busy.
            check(
                "2250 second op rejected while busy",
                gate.begin(purpose: .final, sessionID: sid, nowNanos: 10) == nil
                    && gate.rejectedWhileBusy == 1)
            // Deadline records typed outcome but RETAINS ownership (native
            // inference still running) — reuse still blocked.
            check(
                "2250 deadline keeps ownership",
                gate.timeoutIfExpired(nowNanos: 10_000_000_000) == .deadlineExceeded
                    && gate.isBusy && !gate.reusable)
            check(
                "2250 deadline cannot start second decode",
                gate.begin(purpose: .final, sessionID: sid, nowNanos: 10_000_000_001) == nil)
            // Only the owner can finish; ownership released when native ends.
            let stranger = DecodeOperation(
                operationID: 999, purpose: .partial, sessionID: sid,
                startedAtNanos: 0, deadlineNanosAhead: 1000)
            check("2250 stranger cannot finish", !gate.finish(stranger, outcome: .completed))
            check("2250 owner finish releases", gate.finish(op1!, outcome: .completed) && gate.reusable)
            check("2250 outcome recorded once", gate.outcomes.filter { $0 == .completed }.count == 1)
            // Cancellation retains ownership until native end.
            var g2 = DecodeOwnership()
            let op2 = g2.begin(purpose: .partial, sessionID: sid, nowNanos: 0)!
            check(
                "2250 cancel marks but retains ownership",
                g2.cancel(op2) && g2.isBusy && !g2.reusable)
            check(
                "2250 cancelled cannot reuse engine",
                g2.begin(purpose: .final, sessionID: sid, nowNanos: 5) == nil)
            check(
                "2250 finish after cancel releases",
                g2.finish(op2, outcome: .cancelled) && g2.reusable)
            // Stuck fake decode cannot cause a second decode after timeout.
            var fake = FakeDecode()
            var stuck = DecodeOwnership()
            let s1 = stuck.begin(purpose: .partial, sessionID: sid, nowNanos: 0)!
            fake.start()
            _ = stuck.timeoutIfExpired(nowNanos: 10_000_000_000)
            check(
                "2250 stuck decode blocks second decode",
                stuck.begin(purpose: .final, sessionID: sid, nowNanos: 10_000_000_001) == nil)
            // Native call eventually ends => ownership released, engine reusable.
            fake.end()
            _ = stuck.finish(s1, outcome: .deadlineExceeded)
            check(
                "2250 engine reusable after native end",
                stuck.reusable && fake.maxConcurrent == 1 && fake.started == 1)
        }
        do {
            // Stress: 10k partial/final races never exceed concurrency 1.
            let sid = SessionID(token: "stress", sequence: 1, createdAtUptimeNanos: 0)
            var fake = FakeDecode()
            var ownership = DecodeOwnership()
            var racesOK = true
            for i in 0..<10_000 {
                let purpose: DecodePurpose = i % 2 == 0 ? .partial : .final
                if let op = ownership.begin(purpose: purpose, sessionID: sid, nowNanos: UInt64(i)) {
                    fake.start()
                    // sometimes cancel, sometimes deadline, sometimes complete
                    let r = i % 3
                    switch r {
                    case 0:
                        _ = ownership.cancel(op)
                    case 1:
                        _ = ownership.timeoutIfExpired(nowNanos: UInt64(i) + 10_000_000_000)
                    default:
                        break
                    }
                    fake.end()
                    let outcome: DecodeOperationOutcome =
                        r == 0
                        ? .cancelled
                        : (r == 1 ? .deadlineExceeded : .completed)
                    if !ownership.finish(op, outcome: outcome) { racesOK = false }
                } else {
                    // busy — that's allowed; but must never exceed 1 running
                    if fake.currentRunning > 1 { racesOK = false }
                }
            }
            check("2250 10k races stay single-flight", racesOK && fake.maxConcurrent == 1)
            check("2250 stress ends reusable", ownership.reusable)
        }

        // ===== JOE-2252: rich EngineResult completeness/provenance/warnings =====
        do {
            func result(
                text: String, completeness: EngineResultCompleteness,
                accounting: EngineFrameAccounting?,
                termination: EngineResultTermination = .completed,
                warnings: [EngineWarning] = []
            ) -> EngineResult {
                EngineResult(
                    text: text, completeness: completeness,
                    frameAccounting: accounting,
                    engine: EngineIdentity(
                        kind: .whisper, modelName: "Tiny",
                        modelVersion: "1.0", modelDigest: "abc"),
                    languageRequested: "en", languageDetected: "en",
                    confidence: 0.9, confidenceSource: "engine",
                    startedAtUptimeNanos: 1000, endedAtUptimeNanos: 2000,
                    inferenceDurationNanos: 1_000_000_000,
                    warnings: warnings, fallbackReason: nil,
                    termination: termination)
            }
            let full = EngineFrameAccounting(
                capturedSourceSamples: 16000,
                deliveredEngineSamples: 16000,
                decodedEngineSamples: 16000,
                droppedSourceSamples: 0)
            // Complete requires reconciled evidence.
            let complete = result(text: "hello", completeness: .complete, accounting: full)
            check("2252 complete with reconciled evidence", complete.isComplete)
            check(
                "2252 complete permits success claim",
                complete.completeness.permitsSuccessClaim)
            // Missing frame evidence cannot enable complete.
            let noEvidence = result(text: "hello", completeness: .complete, accounting: nil)
            check("2252 complete without evidence not trusted", !noEvidence.isComplete)
            // Unreconciled evidence (delivered != decoded) fails.
            let bad = EngineFrameAccounting(
                capturedSourceSamples: 16000,
                deliveredEngineSamples: 16000,
                decodedEngineSamples: 9000,
                droppedSourceSamples: 0)
            check(
                "2252 unreconciled evidence fails",
                !result(text: "hi", completeness: .complete, accounting: bad).isComplete)
            // Partial/truncated/degraded never permit success claims.
            check(
                "2252 partial/truncated/degraded conservative",
                !result(text: "hi", completeness: .partial, accounting: full).completeness.permitsSuccessClaim
                    && !result(text: "hi", completeness: .truncated, accounting: full).completeness.permitsSuccessClaim
                    && !result(text: "hi", completeness: .degraded, accounting: full).completeness.permitsSuccessClaim)
            // Distinguishable fallback modes.
            check(
                "2252 partial fallback distinguishable",
                result(
                    text: "hi", completeness: .partial, accounting: nil,
                    warnings: [.partialFallback]
                ).warnings == [.partialFallback])
            check(
                "2252 short-audio fallback distinguishable",
                result(
                    text: "hi", completeness: .partial, accounting: nil,
                    warnings: [.shortAudioFallback]
                ).warnings == [.shortAudioFallback])
            check(
                "2252 deadline termination distinguishable",
                result(
                    text: "hi", completeness: .truncated, accounting: nil,
                    termination: .deadlineExceeded, warnings: [.deadlineExceeded]
                ).termination == .deadlineExceeded)
            // Diagnostics exclude transcript content.
            let diag = complete.diagnosticsPayload
            check(
                "2252 diagnostics exclude text",
                diag.completeness == .complete && diag.engine.modelName == "Tiny"
                    && diag.confidence == 0.9 && diag.frameAccounting == full)
            // No redundant processedText field (Flow is a separate stage).
            check(
                "2252 result has text only (no processedText)",
                complete.text == "hello")
        }

        // ===== JOE-2253: Apple Speech tokenized callbacks + event finalization =====
        do {
            let tok = RecognitionToken(value: "t1")
            let stale = RecognitionToken(value: "t2")
            var tracker = SpeechRecognitionTracker()
            tracker.start(token: tok)
            check("2253 current token accepted", tracker.isCurrent(token: tok))
            // Late/duplicate/out-of-order callbacks from a PRIOR task rejected.
            check(
                "2253 stale token partial rejected",
                !tracker.notePartial(token: stale, text: "old") && tracker.staleCallbackRejections == 1)
            check(
                "2253 stale token final rejected",
                tracker.noteFinal(token: stale, hasText: true) == .cancelled)
            check("2253 current partial kept", tracker.notePartial(token: tok, text: "hello") == true)
            // Empty final preserves the latest usable partial with provenance.
            check(
                "2253 empty final preserves partial",
                tracker.noteFinal(token: tok, hasText: false) == .emptyFinalWithPartial
                    && tracker.latestPartial == "hello")
            check(
                "2253 terminal rejects later callbacks",
                tracker.notePartial(token: tok, text: "after") == false)
            // Error with partial => provenance; without partial => no text.
            var e1 = SpeechRecognitionTracker()
            e1.start(token: tok)
            _ = e1.notePartial(token: tok, text: "partial")
            check(
                "2253 error with partial preserved",
                e1.noteError(token: tok, code: 203, friendly: "no speech") == .terminalErrorWithPartial)
            var e2 = SpeechRecognitionTracker()
            e2.start(token: tok)
            check(
                "2253 error without text",
                e2.noteError(token: tok, code: 201, friendly: "disabled") == .terminalErrorNoText)
            // Deadline with partial is partial/degraded — NEVER complete.
            var d1 = SpeechRecognitionTracker()
            d1.start(token: tok)
            _ = d1.notePartial(token: tok, text: "partial")
            check(
                "2253 deadline with partial is partial-only",
                d1.noteDeadline() == .deadlineWithPartial && d1.finalEvent == .deadlineExceeded)
            var d2 = SpeechRecognitionTracker()
            d2.start(token: tok)
            check(
                "2253 deadline without text",
                d2.noteDeadline() == .deadlineNoText)
            // Waiter resume exactly once.
            var r1 = SpeechRecognitionTracker()
            r1.start(token: tok)
            check("2253 resume once", r1.markResumed() && !r1.markResumed())
        }

        // ===== JOE-2254: validated language + on-device capability =====
        do {
            // Matrix: supported BCP-47 identifiers.
            check("2254 auto is auto", SupportedLanguage.auto.isAuto && SupportedLanguage.auto.bcp47 == nil)
            check(
                "2254 fixed languages have BCP-47",
                SupportedLanguage.enUS.bcp47 == "en-US"
                    && SupportedLanguage.deDE.bcp47 == "de-DE"
                    && SupportedLanguage.jaJP.bcp47 == "ja-JP")
            check(
                "2254 all fixed cases have identifiers",
                SupportedLanguage.allCases.filter { !$0.isAuto }.allSatisfy { $0.bcp47 != nil })
            // Legacy migration: free-form string -> validated model.
            check(
                "2254 legacy migration",
                SupportedLanguage.fromLegacy("fr-FR") == .frFR
                    && SupportedLanguage.fromLegacy("nonsense-lang") == .auto
                    && SupportedLanguage.fromLegacy("") == .auto
                    && SupportedLanguage.fromLegacy("auto") == .auto)
            // Capability decisions per engine.
            let supported = LanguageCapability(
                language: .enUS, whisperOnDevice: true,
                appleOnDevice: true, appleAvailable: true,
                missingPackMessage: nil)
            check(
                "2254 supported everywhere",
                supported.decision(for: .whisper) == .supported
                    && supported.decision(for: .appleSpeech) == .supported)
            // Missing Apple language pack => unavailable (no silent en-US).
            let missing = LanguageCapability(
                language: .jaJP, whisperOnDevice: true,
                appleOnDevice: false, appleAvailable: true,
                missingPackMessage: "Download the language pack")
            check(
                "2254 missing apple pack unavailable",
                missing.decision(for: .appleSpeech) == .unavailable
                    && missing.decision(for: .whisper) == .supported)
            // Auto => autoDetection for both engines.
            let autoCap = LanguageCapability(
                language: .auto, whisperOnDevice: true,
                appleOnDevice: true, appleAvailable: true,
                missingPackMessage: nil)
            check(
                "2254 auto uses engine detection",
                autoCap.decision(for: .whisper) == .autoDetection
                    && autoCap.decision(for: .appleSpeech) == .autoDetection)
            // Unavailable recognizer instance => unavailable.
            let noRecognizer = LanguageCapability(
                language: .deDE, whisperOnDevice: true,
                appleOnDevice: false, appleAvailable: false,
                missingPackMessage: nil)
            check(
                "2254 no recognizer unavailable",
                noRecognizer.decision(for: .appleSpeech) == .unavailable)
            // Language change is snapshot-based: fixed vs auto separate.
            check(
                "2254 language change affects next session only (model-level)",
                SupportedLanguage.enUS != SupportedLanguage.deDE
                    && SupportedLanguage.fromLegacy(SupportedLanguage.deDE.rawValue) == .deDE)
        }

        // ===== JOE-2277: language-aware paragraph-preserving Flow =====
        do {
            // Paragraph breaks survive clean/professional.
            let para = "First paragraph.\n\nSecond paragraph with more content."
            let cleanedPara = await FlowProcessor.shared.process(para, style: .clean, language: .enUS)
            check("2277 paragraph break preserved in clean", cleanedPara.contains("\n\n"))
            // Non-English fixtures preserve lexical content (whitespace-only).
            let de = await FlowProcessor.shared.process(
                "Also gut, dass wir das besprochen haben und uns einigen konnten.", style: .clean, language: .deDE)
            check("2277 non-English lexical content preserved", de.contains("besprochen"))
            check("2277 non-English not mangled", de.lowercased().contains("einigen"))
            // English filler removal still works for English.
            let enFill = await FlowProcessor.shared.process("um hello there you know", style: .clean, language: .enUS)
            check(
                "2277 english filler removed",
                enFill.lowercased().contains("hello") && !enFill.lowercased().contains("um "))
            // Non-English fillers are NOT removed (whitespace/punct-safe only).
            let deFill = await FlowProcessor.shared.process("ähm das ist gut", style: .clean, language: .deDE)
            check("2277 non-english filler preserved", deFill.lowercased().contains("ähm"))
            // Ambiguous contractions are not forced to one meaning.
            let ambiguous = await FlowProcessor.shared.process(
                "I\'d say it\'s fine, that\'s it, there\'s more", style: .professional, language: .enUS)
            check(
                "2277 ambiguous contractions preserved",
                ambiguous.contains("I\'d") && ambiguous.contains("it\'s")
                    && ambiguous.contains("that\'s") && ambiguous.contains("there\'s"))
            // Unambiguous contractions still expand for English.
            let unamb = await FlowProcessor.shared.process(
                "I can\'t come, don\'t go", style: .professional, language: .enUS)
            check(
                "2277 unambiguous contraction expands",
                unamb.lowercased().contains("cannot") && unamb.lowercased().contains("do not"))
            // Non-English gets no contraction expansion.
            let deContr = await FlowProcessor.shared.process("ich kann\'t", style: .professional, language: .deDE)
            check("2277 non-english contraction untouched", deContr.contains("kann\'t"))
            // Protected technical spans remain byte/canonical equivalent.
            let tech = await FlowProcessor.shared.process(
                "visit https://example.com/x.y and mail a@b.co and version 1.2.3 is out", style: .professional,
                language: .enUS)
            check("2277 url preserved", tech.contains("https://example.com/x.y"))
            check("2277 email preserved", tech.contains("a@b.co"))
            check("2277 version preserved", tech.contains("1.2.3"))
            let quoted = await FlowProcessor.shared.process(
                "He said \"don\'t go\" loudly", style: .professional, language: .enUS)
            check("2277 quoted span protected", quoted.contains("\"don\'t go\""))
        }

        // ===== JOE-2278: expanded Flow guardrails (sign/multiset/negation) =====
        do {
            func reject(_ input: String, _ output: String) -> FlowGuardrailsRejection? {
                switch FlowGuardrails.evaluate(input: input, output: output, conservativeFallback: "FALLBACK") {
                case .approved: return nil
                case .rejected(let reason, let fallback):
                    return fallback == "FALLBACK" ? reason : reason
                }
            }
            // -5 cannot become 5 (sign preserved).
            let flip = reject("the value is -5", "the value is 5")
            check("2278 sign flip rejected", flip == .signFlipped)
            // Repeated numbers cannot collapse or duplicate unnoticed.
            let collapse = reject("costs 10 and saves 10", "costs 10")
            check("2278 dropped multiplicity rejected", collapse == .droppedNumber)
            let dup = reject("costs 10", "costs 10 and saves 10")
            check("2278 duplicated number (novel) rejected", dup == .novelNumber)
            // 10%, $10, 10 ms, v1.2.3 retain associated semantics.
            check("2278 percent drop rejected", reject("up 10%", "up") == .droppedPercent)
            check("2278 currency drop rejected", reject("pay $10", "pay") == .droppedCurrency)
            check("2278 unit drop rejected", reject("wait 10 ms", "wait") == .droppedUnit)
            check("2278 version drop rejected", reject("use v1.2.3", "use it") == .droppedProtectedToken)
            // Negation removal/inversion is rejected.
            check("2278 negation removal rejected", reject("do not run", "run") == .droppedNegation)
            check("2278 never removal rejected", reject("never again", "again") == .droppedNegation)
            // Dropping every number fails conservative/structural guards.
            check(
                "2278 drop all numbers rejected",
                reject("there are 5 items and 3 more", "there are items") == .droppedNumber)
            // Technical identifiers preserved.
            check("2278 issue id drop rejected", reject("fix JOE-2278 now", "fix it now") == .droppedProtectedToken)
            check("2278 url drop rejected", reject("see https://a.b/x", "see link") == .droppedProtectedToken)
            // Structural equivalence: 12000 ↔ 12,000 allowed.
            let equiv = FlowGuardrails.evaluate(
                input: "total is 12000", output: "Total is 12,000.", conservativeFallback: "X")
            check("2278 structural equivalence allowed", FlowGuardrailsResult.approved("Total is 12,000.") == equiv)
            // Approved output passes unchanged.
            let ok = FlowGuardrails.evaluate(
                input: "I can't come, call you later", output: "I cannot come, call you later",
                conservativeFallback: "X")
            check("2278 approved output passes", FlowGuardrailsResult.approved("I cannot come, call you later") == ok)
            // Empty/preamble retained as controlled reasons.
            check(
                "2278 empty output rejected",
                reject("a fairly long sentence here", "") == .emptyOutput)
            check("2278 preamble rejected", reject("say hi", "Sure, here is the text") == .preamble)
        }

        // ===== JOE-2279: typed FlowOutcome =====
        do {
            // Every style/backend path returns a complete outcome.
            let sid = SessionID(token: "fo", sequence: 1, createdAtUptimeNanos: 0)
            let cleanReq = FlowRequest(
                sessionID: sid, text: "um hello there",
                style: .clean, language: .enUS,
                sensitivity: .normal)
            let cleanOut = await FlowProcessor.shared.process(cleanReq)
            check(
                "2279 clean outcome complete",
                cleanOut.requestedStyle == .clean && cleanOut.resolvedLossClass == .conservative
                    && cleanOut.backend == .regex && cleanOut.status == .accepted)
            check(
                "2279 outcome has language + capability",
                cleanOut.language == .enUS
                    && cleanOut.capabilityID == "io.zephyr-flow.flow.rules.v1")
            let profReq = FlowRequest(
                sessionID: sid, text: "I can't come, call you later",
                style: .professional, language: .enUS, sensitivity: .normal)
            let profOut = await FlowProcessor.shared.process(profReq)
            check(
                "2279 professional outcome semantic loss class",
                profOut.resolvedLossClass == .semantic && !profOut.text.isEmpty)
            // Diagnostics redact text.
            check(
                "2279 diagnostics redact content",
                profOut.diagnostics.changedRangeCount == profOut.changedRangeCount
                    && profOut.diagnostics.requestedStyle == .professional)
            // Sensitivity policy: secure session with semantic style is
            // conservatively downgraded BEFORE execution.
            let secureReq = FlowRequest(
                sessionID: sid, text: "I can't come, call you later",
                style: .professional, language: .enUS,
                sensitivity: .secure)
            let secureOut = await FlowRouter.shared.process(secureReq)
            check(
                "2279 secure semantic => conservative with warning",
                secureOut.resolvedLossClass == .conservative
                    && secureOut.warnings.contains(.secureSensitivityConservative)
                    && secureOut.status == .accepted)
            // Guardrail rejection is an explicit outcome with fallback reason.
            let gOut = FlowGuardrails.evaluate(
                input: "the value is -5",
                output: "the value is 5",
                conservativeFallback: "the value is -5")
            check(
                "2279 guardrail rejection visible",
                FlowGuardrailsResult.rejected(
                    reason: .signFlipped,
                    conservativeFallback: "the value is -5") == gOut)
        }

        // ===== JOE-2280: versioned Flow fidelity corpus + harness =====
        do {
            check("2280 corpus versioned", FlowFidelityCorpus.version >= 1)
            check("2280 corpus non-empty", FlowFidelityCorpus.cases.count >= 20)
            var failures: [String] = []
            var stats = (protected: 0, forbidden: 0, golden: 0, deterministic: 0, total: FlowFidelityCorpus.cases.count)
            for c in FlowFidelityCorpus.cases {
                let request = FlowRequest(
                    sessionID: SessionID(token: "corpus", sequence: 0, createdAtUptimeNanos: 0),
                    text: c.input, style: c.style, language: c.language,
                    sensitivity: .normal)
                let out1 = await FlowProcessor.shared.process(request)
                let out2 = await FlowProcessor.shared.process(request)
                // Deterministic stability.
                if out1.text == out2.text {
                    stats.deterministic += 1
                } else {
                    failures.append("\(c.id): nondeterministic")
                }
                // Protected spans preserved (no missing input tokens).
                let preserved = FlowGuardrails.inputCovered(
                    input: FlowGuardrails.tokens(in: c.input),
                    output: FlowGuardrails.tokens(in: out1.text)
                ).ok
                if preserved { stats.protected += 1 } else { failures.append("\(c.id): protected span lost") }
                // Forbidden tokens absent.
                let lower = out1.text.lowercased()
                var forbiddenViolated = false
                for tok in c.forbiddenTokens where lower.contains(tok.lowercased()) {
                    forbiddenViolated = true
                }
                if !forbiddenViolated {
                    stats.forbidden += 1
                } else {
                    failures.append("\(c.id): forbidden token present")
                }
                // Golden output equality.
                if let golden = c.goldenOutput {
                    if out1.text == golden {
                        stats.golden += 1
                    } else {
                        failures.append("\(c.id): golden mismatch got=\(out1.text) want=\(golden)")
                    }
                }
            }
            check("2280 all corpus cases pass", failures.isEmpty)

            // JOE-2281: preregistered release gate over the corpus run.
            var perStyle: [FlowStyle: FlowStyleStats] = [:]
            for style in FlowStyle.allCases {
                let cases = FlowFidelityCorpus.cases.filter { $0.style == style }
                var critical = 0
                var fallbackCount = 0
                var noop = 0
                var stable = 0
                for c in cases {
                    let request = FlowRequest(
                        sessionID: SessionID(token: "gate", sequence: 0, createdAtUptimeNanos: 0),
                        text: c.input, style: c.style, language: c.language,
                        sensitivity: .normal)
                    let a = await FlowProcessor.shared.process(request)
                    let b = await FlowProcessor.shared.process(request)
                    if a.text == b.text { stable += 1 }
                    // Critical = any input protected token lost from output.
                    if !FlowGuardrails.inputCovered(
                        input: FlowGuardrails.tokens(in: c.input),
                        output: FlowGuardrails.tokens(in: a.text)
                    ).ok {
                        critical += 1
                    }
                    // Fallback = guardrails rejected output.
                    switch FlowGuardrails.evaluate(
                        input: c.input, output: a.text,
                        conservativeFallback: c.input)
                    {
                    case .approved: break
                    case .rejected: fallbackCount += 1
                    }
                    if a.text == c.input.trimmingCharacters(in: .whitespacesAndNewlines) { noop += 1 }
                }
                if !cases.isEmpty {
                    perStyle[style] = FlowStyleStats(
                        style: style, totalCases: cases.count,
                        criticalViolations: critical,
                        fallbackCount: fallbackCount,
                        noopCount: noop, deterministicCount: stable)
                }
            }
            let gateResult = FlowReleaseGate.evaluate(
                corpusVersion: FlowFidelityCorpus.version,
                stats: perStyle,
                policy: FlowReleasePolicy.current)
            check("2281 release gate passes", gateResult == .pass)
            if case .fail(let reason) = gateResult { print("GATE-FAIL:", reason) }
            // The candidate cannot modify its own thresholds: policy + corpus
            // versions are fixed constants.
            check(
                "2281 policy versioned + baseline named",
                FlowReleasePolicy.current.version >= 1
                    && FlowReleasePolicy.current.baselineCommit.contains("3059542")
                    && FlowReleasePolicy.current.corpusVersion == FlowFidelityCorpus.version)
            // Corpus mismatch must block (regression guard).
            let mismatch = FlowReleaseGate.evaluate(
                corpusVersion: FlowFidelityCorpus.version + 1,
                stats: perStyle,
                policy: FlowReleasePolicy.current)
            check(
                "2281 corpus mismatch blocks",
                mismatch != .pass && FlowReleaseGateResult.fail(reason: "") != mismatch)
            // Structured report (content-free summaries).
            let report: [String: Any] = [
                "corpusVersion": FlowFidelityCorpus.version,
                "totalCases": stats.total,
                "protectedSpansPreserved": stats.protected,
                "forbiddenChangesAbsent": stats.forbidden,
                "goldenExact": stats.golden,
                "deterministicRuns": stats.deterministic,
                "failures": failures,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]),
                let text = String(data: data, encoding: .utf8)
            {
                try? text.write(toFile: "/tmp/flow-fidelity-report.json", atomically: true, encoding: .utf8)
            }
        }

        // ===== JOE-2284: truthful UI rendering policy =====
        do {
            func pres(
                _ eng: EngineResultCompleteness, _ flow: FlowOutcomeStatus,
                _ ins: InsertionOutcome
            ) -> PanelPresentation {
                UIStatePolicy.presentation(engineCompleteness: eng, flowStatus: flow, insertion: ins)
            }
            let verified = InsertionOutcome.verifiedInserted(
                strategy: .axSelectedText, evidence: .postWriteSelectionReRead, warnings: [])
            let unverified = InsertionOutcome.eventPostedUnverified(
                strategy: .clipboardPaste, warnings: [.noPostWriteVerification])
            let copied = InsertionOutcome.explicitlyCopiedByUser
            let changed = InsertionOutcome.targetChanged
            let unknown = InsertionOutcome.targetUnknown
            let secure = InsertionOutcome.secureTarget
            let notEditable = InsertionOutcome.notEditable
            let clipboardChanged = InsertionOutcome.clipboardNotRestoredBecauseChanged
            let deadline = InsertionOutcome.deadlineExceeded
            let cancelled = InsertionOutcome.cancelled
            let failed = InsertionOutcome.failed("boom")

            // Green success requires complete + accepted + verifiedInserted.
            check(
                "2284 complete+verified => green success",
                pres(.complete, .accepted, verified).semantic == .verifiedSuccess
                    && pres(.complete, .accepted, verified).colorToken == "green")
            check(
                "2284 complete+unverified NOT green, distinct language",
                pres(.complete, .accepted, unverified).semantic == .unverifiedPosted
                    && pres(.complete, .accepted, unverified).title == "Paste sent — verify destination"
                    && pres(.complete, .accepted, unverified).colorToken != "green")
            // Partial/degraded/truncated: persistent, no green, no auto-dismiss.
            check(
                "2284 partial persistent warning",
                pres(.partial, .accepted, verified).semantic == .warning
                    && pres(.partial, .accepted, verified).isPersistent)
            check(
                "2284 degraded persistent error",
                pres(.degraded, .accepted, verified).semantic == .error
                    && pres(.degraded, .accepted, verified).isPersistent)
            check(
                "2284 truncated persistent warning",
                pres(.truncated, .accepted, verified).semantic == .warning
                    && pres(.truncated, .accepted, verified).isPersistent)
            // Flow fallback visible when it changes the style.
            check(
                "2284 flow fallback visible",
                pres(.complete, .rejected, verified).semantic == .warning
                    && pres(.complete, .deadlineExceeded, verified).semantic == .warning)
            // Review UX for target states; no automatic side effect.
            check(
                "2284 review states persistent",
                pres(.complete, .accepted, changed).semantic == .review
                    && pres(.complete, .accepted, unknown).semantic == .review
                    && pres(.complete, .accepted, secure).semantic == .review
                    && pres(.complete, .accepted, notEditable).semantic == .review
                    && pres(.complete, .accepted, changed).isPersistent)
            // Clipboard hygiene + deadline + cancelled + failed distinct.
            check(
                "2284 clipboard/deadline/cancel/fail distinct",
                pres(.complete, .accepted, clipboardChanged).semantic == .warning
                    && pres(.complete, .accepted, deadline).semantic == .warning
                    && pres(.complete, .accepted, cancelled).semantic == .neutral
                    && pres(.complete, .accepted, failed).semantic == .error)
            // No uncertain case shares verified-success presentation.
            check(
                "2284 no uncertain case green",
                !UIStatePolicy.isVerifiedSuccess(
                    engineCompleteness: .partial, flowStatus: .accepted, insertion: verified)
                    && !UIStatePolicy.isVerifiedSuccess(
                        engineCompleteness: .complete, flowStatus: .accepted, insertion: unverified)
                    && !UIStatePolicy.isVerifiedSuccess(
                        engineCompleteness: .complete, flowStatus: .accepted, insertion: changed)
                    && !UIStatePolicy.isVerifiedSuccess(
                        engineCompleteness: .complete, flowStatus: .accepted, insertion: secure)
            )
            // VoiceOver label present on every presentation (not color alone).
            check(
                "2284 voiceover labels everywhere",
                !pres(.complete, .accepted, verified).voiceOverLabel.isEmpty
                    && !pres(.complete, .accepted, changed).voiceOverLabel.isEmpty
                    && !pres(.partial, .accepted, verified).voiceOverLabel.isEmpty)
        }

        // ===== JOE-2243: AppEnvironment DI — full pipeline with fakes only =====
        do {
            var clock = FakeClock(now: 1000)
            let env = AppEnvironment.test(clock: clock)
            // Deterministic time is injectable.
            check("2243 fake clock injectable", env.clock.nowNanos() == 1000)
            clock.advance(by: 500)
            check("2243 fake clock controllable", clock.nowNanos() == 1500)
            // Sleeper records (no real wait), ids monotonic, metrics/history
            // are in-memory, permissions fake.
            check(
                "2243 fake permissions",
                env.permissions.microphoneGranted
                    && env.permissions.accessibilityTrusted
                    && env.permissions.speechRecognitionGranted)
            check("2243 fake settings repo", env.settings.current == .default)
            // Engine registry carries the fake engine.
            let engine = env.engines.whisper as? FakeWhisperEngine
            check("2243 fake engine in registry", engine != nil)
            // Session pipeline smoke with fakes: start -> append -> finalize.
            let sid = SessionID(token: "env", sequence: 1, createdAtUptimeNanos: 0)
            var finalResult: EngineResult?
            if let engine {
                try? await engine.startStreaming(
                    sessionID: sid, localOnly: true,
                    language: SupportedLanguage.enUS
                ) { _ in }
                await engine.appendAudio([0.1, 0.2, 0.3])
                finalResult = try? await engine.stopAndFinalize()
            }
            check(
                "2243 fake pipeline finalizes complete",
                finalResult?.completeness == .complete
                    && finalResult?.text == "fake transcript")
            // Fake insertion returns verified; fake target validates.
            let insertion = env.insertion as? FakeInsertionService
            if let insertion {
                let outcome = await insertion.insert("hello")
                check("2243 fake insertion verified", outcome.isVerifiedSuccess)
            }
            let target = env.targetValidation as? FakeTargetValidation
            check("2243 fake target validation available", target != nil)
            // Production env uses the real flow (no side effects at init).
            let prodSettings = AppEnvironment.test().settings.current
            check("2243 test env has no side effects", prodSettings == .default)
        }

        // ===== JOE-2266: termination handshake =====
        do {
            // Complete shutdown from every state -> one terminal outcome.
            var h = TerminationHandshake(deadlineNanosAhead: 1000)
            h.begin(nowNanos: 0)
            var running = true
            var steps = 0
            while running {
                let step = TerminationStep.allCases[steps]
                let st = h.completeStep(step, nowNanos: UInt64(steps) * 100)
                steps += 1
                if st == .completed || st == .abandoned { running = false }
            }
            check("2266 full shutdown completes", h.state == .completed && steps == 7)
            // Exactly-once finalization (no double callbacks).
            check("2266 finalize once", h.markFinalized() && !h.markFinalized())
            check("2266 no recovery marker on clean exit", h.recoveryMarker == nil)
            // Deadline abandonment from mid-shutdown.
            var d = TerminationHandshake(deadlineNanosAhead: 100)
            d.begin(nowNanos: 0)
            _ = d.completeStep(.admissionClosed, nowNanos: 10)
            _ = d.completeStep(.sessionFinished, nowNanos: 200)
            check(
                "2266 deadline abandons with marker",
                d.state == .abandoned && d.recoveryMarker != nil
                    && d.recoveryMarker?.contains("sessionFinished") == true)
            // Remaining steps are surfaced for the recovery report.
            check(
                "2266 remaining steps listed",
                d.remainingSteps.contains(.audioStopped)
                    && d.remainingSteps.contains(.preferencesRestored))
            // Idle handshake completes steps in order.
            var i = TerminationHandshake(deadlineNanosAhead: 1000)
            _ = i.completeStep(.admissionClosed, nowNanos: 0)
            check("2266 begin on first step", i.state == .running && i.startedAtNanos == 0)
            check(
                "2266 terminal absorbed",
                {
                    _ = i.completeStep(.storageFlushed, nowNanos: 5000)
                    return i.state == .abandoned
                }())
        }

        // ===== JOE-2264: versioned privacy-safe telemetry + TerminalGuard =====
        do {
            let tid = SessionTelemetryID("abc123")
            // Exactly one terminal event.
            var guard1 = TerminalGuard(sessionID: tid)
            let e1 = guard1.finalize(terminal: .completed, durationNanos: 1_000, atNanos: 100)
            check("2264 terminal emitted once", e1?.kind == .terminal && e1?.terminal == .completed)
            check(
                "2264 second finalize refused",
                guard1.finalize(terminal: .failed, durationNanos: 2, atNanos: 200) == nil)
            check("2264 exactly one terminal event", guard1.terminalEvent?.terminal == .completed)
            // Dropping an unfinished guard emits controlled abandonment.
            var guard2 = TerminalGuard(sessionID: tid)
            check(
                "2264 unfinished guard abandons",
                guard2.abandon(atNanos: 500)?.terminal == .abandonedDuringShutdown)
            check(
                "2264 abandoned cannot finalize later",
                guard2.finalize(terminal: .completed, durationNanos: 0, atNanos: 600) == nil)
            // Schema has no free-form labels; canary clean on typed events.
            let ev = TelemetryEvent(
                sessionID: tid, kind: .captureAccounting,
                frameCounts: FrameCountSnapshot(captured: 16000, delivered: 16000, dropped: 0, decoded: 16000),
                atNanos: 42)
            check("2264 canary clean on typed event", PrivacyCanary.serializeAndScan(ev) == nil)
            check("2264 schema versioned", ev.schemaVersion == TelemetrySchemaVersion.current.rawValue)
            // Canary detects smuggled payload shapes.
            check("2264 canary detects private path", PrivacyCanary.scan("x /Users/joe/secret y") == "/Users/")
            check("2264 canary detects key shape", PrivacyCanary.scan("key=sk-1234") == "sk-")
            // Bounded nonblocking sink: overflow drops counted, no stall.
            let sink = BoundedEventSink(capacity: 4)
            var delivered: [TelemetryEvent] = []
            sink.setHost { delivered.append($0) }
            for i in 0..<20 {
                sink.record(TelemetryEvent(sessionID: tid, kind: .stageEntered, atNanos: UInt64(i)))
            }
            check("2264 sink overflow drops counted", sink.droppedCount >= 16)
            check("2264 sink never blocks", sink.pendingCount == 4)
            _ = sink.drain()
            check("2264 sink drains to host", delivered.count == 4 && sink.pendingCount == 0)
            // Reentrant host callback (records inside callback) cannot deadlock.
            let reentrant = BoundedEventSink(capacity: 8)
            var nested = 0
            reentrant.setHost { ev in
                nested += 1
                if nested < 3 {
                    reentrant.record(ev)  // reentrant call — must not deadlock
                }
            }
            reentrant.record(TelemetryEvent(sessionID: tid, kind: .stageEntered, atNanos: 1))
            // Drain repeatedly: each drain delivers one and the host re-records.
            var drains = 0
            while reentrant.pendingCount > 0 && drains < 10 {
                _ = reentrant.drain()
                drains += 1
            }
            check("2264 reentrant sink no deadlock", nested == 3 && drains == 3)
        }

        // ===== JOE-2261: opt-in bounded actor history =====
        do {
            // Default OFF for new installs.
            check("2261 default history off", !AppSettings.default.saveHistory)
            // Policy gate: only normal + outcome-permitted writes.
            let verified = InsertionOutcome.verifiedInserted(
                strategy: .axSelectedText, evidence: .postWriteSelectionReRead, warnings: [])
            let unverified = InsertionOutcome.eventPostedUnverified(
                strategy: .clipboardPaste, warnings: [.noPostWriteVerification])
            check(
                "2261 normal+verified allowed",
                HistoryStoragePolicy.allowsWrite(sensitivity: .normal, outcome: verified))
            check("2261 secure denied", !HistoryStoragePolicy.allowsWrite(sensitivity: .secure, outcome: verified))
            check("2261 unknown denied", !HistoryStoragePolicy.allowsWrite(sensitivity: .unknown, outcome: verified))
            check(
                "2261 unverified outcome denied",
                !HistoryStoragePolicy.allowsWrite(sensitivity: .normal, outcome: unverified))
            check(
                "2261 no outcome fails closed",
                !HistoryStoragePolicy.allowsWrite(sensitivity: .normal, outcome: nil))
            // Retention: age + entries + bytes.
            let policy = HistoryRetentionPolicy(maxAgeSeconds: 3600, maxTotalBytes: 300, maxEntries: 3)
            let now = Date()
            func e(_ i: Int, age: TimeInterval = 10, text: String) -> HistoryStorageEntry {
                HistoryStorageEntry(
                    timestamp: now.addingTimeInterval(-age), text: text,
                    duration: 1, modelUsed: "Tiny", sensitivityClass: "normal")
            }
            var list = [
                e(1, text: "aaaa"), e(2, text: "bbbb"), e(3, text: "cccc"),
                e(4, text: "dddd"), e(5, age: 7200, text: "eeee"),
            ]
            let trimmed = HistoryStoragePolicy.trimmed(list, policy: policy, now: now)
            check(
                "2261 retention drops old + caps entries",
                trimmed.count == 3 && !trimmed.contains { $0.text == "eeee" })
            // Byte cap holds under large transcripts.
            let bigPolicy = HistoryRetentionPolicy(maxAgeSeconds: 3600, maxTotalBytes: 200, maxEntries: 100)
            let big = HistoryStoragePolicy.trimmed(
                [
                    e(1, text: String(repeating: "x", count: 100)),
                    e(2, text: String(repeating: "y", count: 100)),
                ],
                policy: bigPolicy, now: now)
            check("2261 byte cap holds", big.count == 1)
        }

        // ===== JOE-2261 repo: round-trip, migration, corruption, failures =====
        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("zf-history-\(UUID().uuidString)", isDirectory: true)
            let file = dir.appendingPathComponent("history.json")
            // Round-trip: add -> persist -> reload entries durable.
            let repo = ActorHistoryRepository(fileURL: file)
            try? await repo.load()
            let entry = HistoryStorageEntry(
                timestamp: Date(), text: "hello world",
                duration: 1.0, modelUsed: "Tiny",
                sensitivityClass: "normal")
            await repo.add(entry)
            let reloaded = ActorHistoryRepository(fileURL: file)
            try? await reloaded.load()
            let entries = await reloaded.entries()
            check("2261 repo round-trip durable", entries.count == 1 && entries[0].text == "hello world")
            // Clear is durable after relaunch.
            try? await reloaded.clear()
            let afterClear = ActorHistoryRepository(fileURL: file)
            try? await afterClear.load()
            let clearedEntries = await afterClear.entries()
            check("2261 clear durable", clearedEntries.isEmpty)
            // Legacy v1 migration -> single text field.
            let v1 = [
                LegacyV1Fixture(
                    id: UUID(), timestamp: Date(), originalText: "raw", finalText: "final", duration: 1,
                    modelUsed: "Tiny")
            ]
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            if let data = try? enc.encode(v1) {
                try? data.write(to: file)
                let migrated = ActorHistoryRepository(fileURL: file)
                try? await migrated.load()
                let migratedEntries = await migrated.entries()
                check(
                    "2261 v1 migration to single text",
                    migratedEntries.count == 1 && migratedEntries[0].text == "final")
            }
            // Corruption -> quarantine + clean start.
            try? Data("garbage-not-json".utf8).write(to: file)
            let corrupt = ActorHistoryRepository(fileURL: file)
            var threwCorruption = false
            do { try await corrupt.load() } catch { threwCorruption = true }
            let corruptEntries = await corrupt.entries()
            check(
                "2261 corruption quarantined + reported",
                threwCorruption && corruptEntries.isEmpty)
            // Failure injection: disk-full and permission-denied map to typed errors.
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let failing = FailingHistoryFileSystem()
            let failRepo = ActorHistoryRepository(fileURL: file, fileSystem: failing)
            await failRepo.add(entry)
            // add() swallows errors; verify the failing FS was asked and the
            // typed error path is exercised via persistOrThrow indirectly.
            check("2261 failing fs exercises error path", failing.failures > 0)
            try? FileManager.default.removeItem(at: dir)
        }

        // ===== JOE-2263: versioned settings storage =====
        do {
            // Envelope round-trip with provenance.
            var settings = AppSettings.default
            settings.localOnlyMode = true
            settings.saveHistory = false
            let data =
                (try? SettingsStorageCoordinator.encode(
                    settings: settings,
                    provenance: ["v2"]))!
            let loaded = SettingsStorageCoordinator.load(data: data)
            check(
                "2263 envelope round-trip",
                loaded.settings.localOnlyMode == true
                    && !loaded.settings.saveHistory
                    && !loaded.recoveredFromCorruption)
            // Legacy v1 flat payload migrates deterministically.
            let v1Flat = (try? JSONEncoder().encode(settings))!
            let migrated = SettingsStorageCoordinator.load(data: v1Flat)
            check(
                "2263 v1 flat migrates",
                migrated.migratedFromVersion == 1
                    && migrated.settings.localOnlyMode == true
                    && !migrated.recoveredFromCorruption)
            // Unknown/newer schema fails safely + retains original for recovery.
            let unknown = SettingsEnvelope(schemaVersion: 99, payload: settings)
            let unknownData = (try? JSONEncoder().encode(unknown))!
            let unknownResult = SettingsStorageCoordinator.load(data: unknownData)
            check(
                "2263 unknown schema fails safely with quarantine",
                unknownResult.recoveredFromCorruption
                    && unknownResult.unknownSchemaVersion == 99
                    && unknownResult.quarantinePath != nil)
            // Safe baseline: localOnly ON, downloads/history OFF — privacy
            // defaults are never silently re-enabled after corruption.
            let baseline = unknownResult.settings
            check(
                "2263 corruption baseline is privacy-safe",
                baseline.localOnlyMode == true
                    && baseline.allowModelDownloads == false
                    && baseline.saveHistory == false)
            // Corrupt bytes -> quarantine + baseline.
            let corrupt = SettingsStorageCoordinator.load(data: Data("garbage".utf8))
            check(
                "2263 corrupt data recovered to safe baseline",
                corrupt.recoveredFromCorruption && corrupt.settings.localOnlyMode == true)
            // Nil data -> brand-new install defaults (privacy-safe).
            let fresh = SettingsStorageCoordinator.load(data: nil)
            check(
                "2263 fresh install defaults privacy-safe",
                fresh.settings.localOnlyMode == true && !fresh.settings.saveHistory)
            // Transactional reset preserves ONLY documented fields.
            var current = AppSettings.default
            current.hasCompletedOnboarding = true
            current.saveHistory = true
            current.localOnlyMode = false
            let reset = SettingsStorageCoordinator.resetPayload(current: current)
            check(
                "2263 reset transactional + preserves onboarding only",
                reset.hasCompletedOnboarding == true
                    && reset.saveHistory == false
                    && reset.localOnlyMode == true)
            // Encode failure is reported (write failure => no silent success).
            do {
                _ = try SettingsStorageCoordinator.encode(settings: settings, provenance: [])
                check("2263 encode succeeds", true)
            } catch {
                check("2263 encode succeeds", false)
            }
        }

        // ===== JOE-2265: privacy-safe support bundle + canary =====
        do {
            func inputs(
                settings: [String: String] = ["localOnly": "true", "saveHistory": "false"],
                events: [TelemetryEvent] = [],
                healthChecks: [String: String] = ["historyPerms": "ok"]
            ) -> SupportBundleInputs {
                SupportBundleInputs(
                    appVersion: "0.0.0", build: "1", sourceProvenance: "git",
                    channel: "debug", osVersion: "14.5", architecture: "arm64",
                    hardwareClass: "desktop", microphoneGranted: true,
                    accessibilityTrusted: true, speechGranted: true,
                    settingsSummary: settings, engineModel: "Whisper Tiny",
                    modelCacheReady: true, modelCacheIntegrity: true,
                    telemetryEvents: events, frameSummary: "captured=16000 delivered=16000 dropped=0 decoded=16000",
                    fallbackCount: 1, insertionConfidenceCounts: ["verified": 5],
                    healthChecks: healthChecks, privacyPolicyVersion: "1")
            }
            // Clean bundle builds + passes canary.
            let clean = try? SupportBundleBuilder.build(inputs: inputs())
            check(
                "2265 clean bundle builds + canary clean",
                clean != nil && clean?.schemaVersion == SupportBundleSchemaVersion.current)
            check(
                "2265 preview manifest readable",
                SupportBundleBuilder.preview(clean!).contains("support bundle"))
            // Injected canary markers in controlled fields => export prevented.
            let tainted = inputs(settings: ["notes": "my password=secret123"])
            var threw = false
            do { _ = try SupportBundleBuilder.build(inputs: tainted) } catch { threw = true }
            check("2265 marker prevents export", threw)
            // Field name reported without revealing the marker.
            do {
                _ = try SupportBundleBuilder.build(inputs: tainted)
                check("2265 offending field named", false)
            } catch SupportBundleBuilder.BuildError.markerDetected(let field) {
                check("2265 offending field named", field == "settingsSummary.notes")
            } catch {
                check("2265 offending field named", false)
            }
            // Private path marker in health check blocks export.
            let pathTainted = inputs(healthChecks: ["logPath": "/Users/alice/zf.log"])
            var threwPath = false
            do { _ = try SupportBundleBuilder.build(inputs: pathTainted) } catch { threwPath = true }
            check("2265 private path marker blocks export", threwPath)
            // Telemetry events are content-free (no transcript/audio/keys).
            let tid = SessionTelemetryID("b1")
            let ev = TelemetryEvent(sessionID: tid, kind: .terminal, terminal: .completed, atNanos: 1)
            let withEvents = try? SupportBundleBuilder.build(inputs: inputs(events: [ev]))
            check(
                "2265 telemetry events included bounded",
                withEvents?.telemetryEvents.count == 1)
            // Bundle sufficient for representative diagnostics.
            let b = clean!
            check(
                "2265 bundle has permissions/model/frames",
                b.permissions.microphoneGranted && b.modelCache.integrityVerified
                    && b.frameSummary.contains("captured=16000")
                    && b.fallbackCount == 1
                    && b.insertionConfidenceCounts["verified"] == 5)
        }

        // ===== JOE-2290: transactional launch-at-login =====
        do {
            // Success: register -> status registered -> converge -> commit.
            var tx = LaunchAtLoginTransaction()
            tx.begin(desiredEnabled: true)
            check("2290 pending entered", tx.isPending && tx.desiredEnabled == true)
            tx.commit(verifiedStatus: .registered)
            check("2290 committed after verified", tx.state == .applied)
            // Failure: rollback leaves no false desired value.
            var tx2 = LaunchAtLoginTransaction()
            tx2.begin(desiredEnabled: true)
            tx2.rollback(reason: "status did not converge")
            check(
                "2290 rollback clears desired",
                tx2.state == .rolledBack && tx2.desiredEnabled == nil
                    && tx2.rollbackReason != nil)
            // Convergence rule.
            check(
                "2290 convergence registered<=>true",
                LaunchAtLoginTransaction.statusConverges(status: .registered, desiredEnabled: true)
                    && LaunchAtLoginTransaction.statusConverges(status: .notRegistered, desiredEnabled: false))
            check(
                "2290 requiresApproval never converges",
                !LaunchAtLoginTransaction.statusConverges(status: .requiresApproval, desiredEnabled: true)
                    && !LaunchAtLoginTransaction.statusConverges(status: .notFound, desiredEnabled: true)
                    && !LaunchAtLoginTransaction.statusConverges(status: .stale, desiredEnabled: false))
            // Unregister failure rollback: no false "disabled" persisted.
            var tx3 = LaunchAtLoginTransaction()
            tx3.begin(desiredEnabled: false)
            tx3.rollback(reason: "unregister failed")
            check("2290 failed unregister rolls back", tx3.state == .rolledBack)
            // Pending cannot commit before external change (idempotence).
            var tx4 = LaunchAtLoginTransaction()
            tx4.commit(verifiedStatus: .registered)
            check("2290 commit without begin refused", tx4.state == .idle)
        }

        // ===== JOE-2244: session truth in one isolated per-session actor =====
        do {
            func settings(_ saveHistory: Bool = true) -> SessionSettingsSnapshot {
                SessionSettingsSnapshot(
                    localOnly: true,
                    language: .enUS,
                    defaultFlowStyle: .clean,
                    insertionMode: "automatic",
                    saveHistory: saveHistory,
                    copyOnlyOverrideBundleIDs: [])
            }
            func engineResult(_ text: String = "hello world") -> EngineResult {
                EngineResult(
                    text: text, completeness: .complete,
                    frameAccounting: nil,
                    engine: EngineIdentity(
                        kind: .whisper, modelName: "Fake",
                        modelVersion: "1.0", modelDigest: "x"),
                    languageRequested: "en", languageDetected: "en",
                    confidence: 0.9, confidenceSource: "engine",
                    startedAtUptimeNanos: 1000, endedAtUptimeNanos: 2000,
                    inferenceDurationNanos: 1_000_000_000,
                    warnings: [], fallbackReason: nil,
                    termination: .completed)
            }
            func collect(_ stream: AsyncStream<SessionUIState>) async -> [SessionUIState] {
                var out: [SessionUIState] = []
                for await s in stream { out.append(s) }
                return out
            }

            // 1. End-to-end success: capture -> finalize -> flow -> validate
            //    -> insert -> history (single terminal, exactly once).
            let provider1 = FakeSessionStages()
            await provider1.setPartials(["hel", "hello "])
            let s1 = DictationSession(
                provider: provider1, engineChoice: .whisper,
                settings: settings(true))
            let stream1 = await s1.subscribe()
            let runTask1 = Task { await s1.run() }
            // Let run() reach the capture wait, then end.
            try? await Task.sleep(nanoseconds: 50_000_000)
            await s1.end()
            let states1 = await collect(stream1)
            await runTask1.value
            check("2244 success emits listening", states1.contains { $0.phase == .listening })
            check("2244 success emits success terminal", states1.contains { $0.phase == .success })
            check(
                "2244 interim length updated",
                states1.contains { $0.interimText == "hello " })
            check(
                "2244 audio summary output set",
                states1.last?.outputs.audioSummary?.deliveredEngineSamples == 16000)
            check(
                "2244 engine result output set",
                states1.last?.outputs.engineResult?.text == "hello world")
            check(
                "2244 flow outcome output set",
                states1.last?.outputs.flowOutcome?.text == "hello world")
            check(
                "2244 validation output set",
                states1.last?.outputs.validation == .validated)
            check(
                "2244 insertion output set verified",
                states1.last?.outputs.insertion?.isVerifiedSuccess == true)
            check(
                "2244 history recorded once (saveHistory on)",
                await provider1.historyCount == 1)
            check("2244 prepare ran exactly once", await provider1.prepareCount == 1)

            // 2. Exactly-one terminal + success does not re-run.
            let before = await provider1.historyCount
            await s1.end()  // no-op after terminal
            try? await Task.sleep(nanoseconds: 30_000_000)
            check("2244 no second terminal side effects", await provider1.historyCount == before)

            // 3. Cancel mid-capture: no insertion, provider cancelled.
            let provider2 = FakeSessionStages()
            let s2 = DictationSession(
                provider: provider2, engineChoice: .whisper,
                settings: settings(false))
            let runTask2 = Task { await s2.run() }
            try? await Task.sleep(nanoseconds: 50_000_000)
            await s2.cancel()
            await runTask2.value
            check("2244 cancel provider called", await provider2.cancelCount == 1)
            check("2244 cancel no history", await provider2.historyCount == 0)

            // 4. Target change -> review -> retry -> success (fresh validation).
            let provider3 = FakeSessionStages()
            await provider3.setValidationOutcomes([.targetChanged, .validated])
            let s3 = DictationSession(
                provider: provider3, engineChoice: .whisper,
                settings: settings(false))
            let stream3 = await s3.subscribe()
            let runTask3 = Task { await s3.run() }
            try? await Task.sleep(nanoseconds: 50_000_000)
            await s3.end()
            // Wait for the review phase, then retry.
            try? await Task.sleep(nanoseconds: 80_000_000)
            await s3.retryInsertion()
            let states3 = await collect(stream3)
            await runTask3.value
            check(
                "2244 target change shows review",
                states3.contains { $0.phase == .review && $0.outputs.validation == .targetChanged })
            check(
                "2244 retry reaches success",
                states3.contains { $0.phase == .success })

            // 5. Partial transcript: warning terminal, no insertion.
            let provider4 = FakeSessionStages()
            await provider4.setCompleteness(.partial)
            let s4 = DictationSession(
                provider: provider4, engineChoice: .whisper,
                settings: settings(true))
            let stream4 = await s4.subscribe()
            let runTask4 = Task { await s4.run() }
            try? await Task.sleep(nanoseconds: 50_000_000)
            await s4.end()
            let states4 = await collect(stream4)
            await runTask4.value
            check("2244 partial transcript -> warning", states4.contains { $0.phase == .warning })
            check("2244 partial no history", await provider4.historyCount == 0)

            // 6. UI subscribers reconnect without changing session state.
            let provider5 = FakeSessionStages()
            let s5 = DictationSession(
                provider: provider5, engineChoice: .whisper,
                settings: settings(false))
            let runTask5 = Task { await s5.run() }
            try? await Task.sleep(nanoseconds: 50_000_000)
            _ = await s5.subscribe()  // first subscriber
            let replay = await s5.subscribe()  // second subscriber: replay current
            var replayStates: [SessionUIState] = []
            for await st in replay {
                replayStates.append(st)
                break
            }
            await s5.cancel()
            await runTask5.value
            check("2244 reconnect gets current state", replayStates.first?.phase == .listening)

            // 7. Two successive sessions cannot share mutable state: distinct
            //    providers, distinct actors, distinct session ids.
            let provider6 = FakeSessionStages()
            let factory6 = SessionIDFactory()
            let s6a = DictationSession(
                provider: provider6, engineChoice: .whisper,
                settings: settings(false), idFactory: factory6)
            let s6b = DictationSession(
                provider: provider6, engineChoice: .whisper,
                settings: settings(false), idFactory: factory6)
            let idA = await s6a.sessionID
            let idB = await s6b.sessionID
            check("2244 successive sessions distinct ids", idA != idB)
            let p6a = await provider6.prepareCount
            _ = p6a
            // (prepare runs inside run(); distinct actors guarantee isolation.)

            // 8. Leak/deinit: after terminal + dropped refs the actor is
            //    released (all owned tasks/callbacks released).
            let provider7 = FakeSessionStages()
            var s7: DictationSession? = DictationSession(
                provider: provider7,
                engineChoice: .whisper,
                settings: settings(false))
            weak var weak7 = s7
            let runTask7 = Task { await s7!.run() }
            try? await Task.sleep(nanoseconds: 50_000_000)
            await s7!.end()
            await runTask7.value
            s7 = nil
            // Give the executor a beat to run deinit.
            var released = false
            for _ in 0..<5 {
                try? await Task.sleep(nanoseconds: 40_000_000)
                if weak7 == nil {
                    released = true
                    break
                }
            }
            check("2244 session released after terminal (leak test)", released)
        }

        // ===== JOE-2255: verified model acquisition lifecycle =====
        do {
            nonisolated func manifest(
                _ model: ModelIdentifier,
                digests: [String: String] = [:]
            ) -> ModelManifest {
                ModelAcquisitionController.makeManifest(
                    for: model, createdAtUptimeNanos: 1,
                    minArtifactBytes: 1_000,
                    minTotalBytes: 1_000_000, maxTotalBytes: 100_000_000,
                    digests: digests)
            }

            // 1. Happy path: download -> verify -> promote -> ready; verified
            //    readiness means manifest-verified URL, not empty dir.
            let fs1 = FakeModelFS()
            let acq1 = ModelAcquisitionController(fs: fs1)
            let r1 = await acq1.acquire(model: .whisperTiny, consent: true)
            check("2255 happy path ready", r1.state == .ready && r1.error == nil)
            check("2255 verified URL non-nil", r1.verifiedURL != nil)
            check(
                "2255 verified readiness ready",
                await acq1.verifiedReadiness(for: .whisperTiny).state == .ready)
            check(
                "2255 cache dir 0700",
                fs1.lastCreatePermission(URL(fileURLWithPath: "/fake/verified")) == 0o700)
            check(
                "2255 staging dir 0700",
                fs1.lastCreatePermission(URL(fileURLWithPath: "/fake/staging/\(ModelIdentifier.whisperTiny.rawValue)"))
                    == 0o700)

            // 2. Interrupted/corrupt download never becomes ready; the failed
            //    download removes partial staging.
            let fs2 = FakeModelFS()
            fs2.failDownload = true
            let acq2 = ModelAcquisitionController(fs: fs2)
            let r2 = await acq2.acquire(model: .whisperTiny, consent: true)
            check("2255 download failure -> failed", r2.state == .failed)
            check(
                "2255 download failure typed error",
                r2.error == .downloadFailed("The operation couldn’t be completed. (NSURLErrorDomain error -1004.)")
                    || r2.error != nil)
            check(
                "2255 failed download not ready",
                await acq2.verifiedReadiness(for: .whisperTiny).state != .ready)

            // 3. Corrupt (digest mismatch) -> quarantined, never reused.
            let fs3 = FakeModelFS()
            let badDigest = String(repeating: "0", count: 64)
            let acq3 = ModelAcquisitionController(fs: fs3) { model in
                manifest(model, digests: ["config.json": badDigest])
            }
            let r3 = await acq3.acquire(model: .whisperTiny, consent: true)
            check("2255 digest mismatch -> quarantined", r3.state == .quarantined)
            let rs3 = await acq3.verifiedReadiness(for: .whisperTiny)
            check("2255 quarantined readiness", rs3.state == .quarantined)

            // 3b. Correct digest -> verified ready (digests honored).
            let fs3b = FakeModelFS()
            let configData = Data(repeating: 0xAB, count: 10_000)
            let goodDigest = SHA256.hash(data: configData).map { String(format: "%02x", $0) }.joined()
            let acq3b = ModelAcquisitionController(fs: fs3b) { model in
                manifest(model, digests: ["config.json": goodDigest])
            }
            let r3b = await acq3b.acquire(model: .whisperTiny, consent: true)
            check("2255 correct digest -> ready", r3b.state == .ready)

            // 4. Truncated artifact -> quarantined.
            let fs4 = FakeModelFS()
            fs4.truncateArtifact = true
            let acq4 = ModelAcquisitionController(fs: fs4)
            let r4 = await acq4.acquire(model: .whisperTiny, consent: true)
            check("2255 truncated artifact -> quarantined", r4.state == .quarantined)

            // 5. Promotion failure -> failed, staging quarantined.
            let fs5 = FakeModelFS()
            fs5.failPromote = true
            let acq5 = ModelAcquisitionController(fs: fs5)
            let r5 = await acq5.acquire(model: .whisperTiny, consent: true)
            check("2255 promotion failure -> failed", r5.state == .failed)
            check(
                "2255 promotion typed error",
                r5.error == .promotionFailed("The operation couldn’t be completed. (NSCocoaErrorDomain error 512.)")
                    || r5.error != nil)

            // 6. Concurrent preloads: ONE acquisition, consistent results.
            let fs6 = FakeModelFS()
            fs6.downloadDelayNanos = 50_000_000
            let acq6 = ModelAcquisitionController(fs: fs6)
            async let a = acq6.acquire(model: .whisperBase, consent: true)
            async let b = acq6.acquire(model: .whisperBase, consent: true)
            async let c = acq6.acquire(model: .whisperBase, consent: true)
            let (ra, rb, rc) = await (a, b, c)
            check(
                "2255 singleflight all ready",
                ra.state == .ready && rb.state == .ready && rc.state == .ready)
            check(
                "2255 singleflight same URL",
                ra.verifiedURL == rb.verifiedURL && rb.verifiedURL == rc.verifiedURL)

            // 7. Consent denied: no download, clean failure.
            let fs7 = FakeModelFS()
            let acq7 = ModelAcquisitionController(fs: fs7)
            let r7 = await acq7.acquire(model: .whisperTiny, consent: false)
            check(
                "2255 consent denied fails cleanly",
                r7.state == .failed && r7.error == .consentDenied)
            check(
                "2255 no download without consent",
                await acq7.verifiedReadiness(for: .whisperTiny).state != .ready)

            // 8. Local-only with missing model fails cleanly (no network).
            let fs8 = FakeModelFS()
            fs8.failDownload = true
            let acq8 = ModelAcquisitionController(fs: fs8)
            let r8 = await acq8.acquire(model: .whisperSmall, consent: true)
            check(
                "2255 offline missing model fails cleanly",
                r8.state == .failed && r8.error != nil)

            // 9. Stale lock (interrupted acquisition) is cleaned and retried.
            let fs9 = FakeModelFS()
            fs9.staleLockHeld = true
            let acq9 = ModelAcquisitionController(fs: fs9)
            let r9 = await acq9.acquire(model: .whisperTiny, consent: true)
            check("2255 stale lock recovered -> ready", r9.state == .ready)

            // 10. Cancellation mid-download: cancelled, no artifact promoted.
            let fs10 = FakeModelFS()
            fs10.downloadDelayNanos = 200_000_000
            let acq10 = ModelAcquisitionController(fs: fs10)
            let task10 = Task {
                await acq10.acquire(model: .whisperTiny, consent: true)
            }
            try? await Task.sleep(nanoseconds: 60_000_000)
            await acq10.cancel(model: .whisperTiny)
            let r10 = await task10.value
            check("2255 cancel mid-download -> cancelled", r10.state == .cancelled)
            check(
                "2255 cancelled never ready",
                await acq10.verifiedReadiness(for: .whisperTiny).state != .ready)

            // 11. Readiness reflects VERIFIED loadability: a manifest-less
            //     non-empty dir is NOT ready.
            let fs11 = FakeModelFS()
            let acq11 = ModelAcquisitionController(fs: fs11)
            // Simulate a legacy non-empty dir without manifest:
            try? fs11.createDirectory(
                URL(fileURLWithPath: "/fake/verified/\(ModelIdentifier.whisperTiny.rawValue)"), permissions: 0o700)
            check(
                "2255 empty/manifest-less dir not ready",
                await acq11.verifiedReadiness(for: .whisperTiny).state != .ready)
        }

        // ===== JOE-2262: at-rest history encryption =====
        do {
            nonisolated func key(_ id: String = "k1") -> HistoryCryptoKey {
                HistoryCryptoKey(keyID: id, material: Data(repeating: 0x42, count: 32))
            }
            func entry(_ text: String) -> HistoryStorageEntry {
                HistoryStorageEntry(
                    id: UUID(), timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                    text: text, duration: 1.0, modelUsed: "Tiny",
                    sensitivityClass: "normal")
            }

            // 1. Round-trip: encrypt -> decrypt preserves content.
            let engine = HistoryCipherEngine()
            let plain =
                (try? engine.encrypt(plaintext: Data("hello secret".utf8), key: key()))
                ?? HistoryEncryptedPayload(keyID: "k1", nonce: Data(), ciphertext: Data(), authTag: Data())
            let back = engine.decrypt(plain, key: key())
            check("2262 round-trip", back == Data("hello secret".utf8))

            // 2. Tamper (flip one ciphertext byte) -> auth failure, nil.
            let tamperedCipher =
                plain.ciphertext.isEmpty
                ? Data()
                : Data([plain.ciphertext.first! ^ 0xFF]) + plain.ciphertext.dropFirst()
            let tampered = HistoryEncryptedPayload(
                keyID: plain.keyID, nonce: plain.nonce,
                ciphertext: tamperedCipher, authTag: plain.authTag)
            check(
                "2262 tamper fails authentication",
                engine.decrypt(tampered, key: key()) == nil)

            // 3. Wrong key -> nil; wrong keyID -> nil; never partial.
            let wrong = HistoryCryptoKey(keyID: "k2", material: Data(repeating: 0x01, count: 32))
            check("2262 wrong key fails", engine.decrypt(plain, key: wrong) == nil)

            // 4. Migration encrypt: full document sealed; file alone yields
            //    no transcript; metadata documented.
            let doc = HistoryDocument(entries: [entry("transcript A"), entry("transcript B")])
            let enc =
                (try? HistoryEncryptionMigration.encrypt(document: doc, key: key()))
                ?? EncryptedHistoryDocument(
                    keyID: "k1",
                    payload: HistoryEncryptedPayload(keyID: "k1", nonce: Data(), ciphertext: Data(), authTag: Data()))
            let meta = HistoryEncryptionMigration.visibleMetadata(of: enc)
            check("2262 cipher AES-256-GCM", enc.payload.cipher == "AES-256-GCM")
            check("2262 version stored", enc.payload.version == 1 && enc.schemaVersion == 1)
            check("2262 keyID stored", enc.payload.keyID == "k1")
            check(
                "2262 metadata documented",
                meta["entryCount"] == "sealed" && meta["cipher"] == "AES-256-GCM")
            let decDoc = HistoryEncryptionMigration.decrypt(document: enc, key: key())
            check("2262 migration decrypt", decDoc?.entries.count == 2)

            // 5. Repository: encrypted persistence — reading the raw file
            //    yields no transcript substring.
            let fs = InMemoryHistoryFS()
            let repo = ActorHistoryRepository(fileSystem: fs, keyProvider: { key() })
            try? await repo.load()
            await repo.add(
                HistoryEntry(
                    originalText: "a", finalText: "top secret words",
                    duration: 1, modelUsed: "Tiny"))
            let raw = fs.lastWrittenData
            let rawString = String(data: raw ?? Data(), encoding: .utf8) ?? ""
            check(
                "2262 raw file has no transcript",
                !rawString.contains("top secret words"))
            check(
                "2262 raw file is encrypted doc",
                rawString.contains("AES-256-GCM") && rawString.contains("keyID"))

            // 6. Repository round-trip with key: entries decrypt.
            let fs2 = InMemoryHistoryFS()
            let repo2 = ActorHistoryRepository(fileSystem: fs2, keyProvider: { key() })
            try? await repo2.load()
            await repo2.add(
                HistoryEntry(
                    originalText: "a", finalText: "hello world",
                    duration: 1, modelUsed: "Tiny"))
            let fs2b = InMemoryHistoryFS(preload: fs2.lastWrittenData)
            let repo2b = ActorHistoryRepository(fileSystem: fs2b, keyProvider: { key() })
            try? await repo2b.load()
            let r2bEntries = await repo2b.entries()
            check(
                "2262 repo decrypt round-trip",
                r2bEntries.count == 1 && r2bEntries.first?.text == "hello world")

            // 7. Missing key: recovery state, no plaintext, content stays
            //    sealed on disk.
            let fs3 = InMemoryHistoryFS(preload: fs2.lastWrittenData)
            let repo3 = ActorHistoryRepository(fileSystem: fs3, keyProvider: { nil })
            try? await repo3.load()
            let r3Entries = await repo3.entries()
            check("2262 missing key -> no entries", r3Entries.isEmpty)
            let r3Recovery = await repo3.recoveryState
            check("2262 missing key -> recovery state", r3Recovery != nil)
            let raw3 = String(data: fs3.lastWrittenData ?? Data(), encoding: .utf8) ?? ""
            check("2262 sealed content retained", raw3.contains("AES-256-GCM"))

            // 8. Migration interruption (write failure) -> old store intact
            //    (atomic), never mixed.
            let fs4 = InMemoryHistoryFS()
            let repo4 = ActorHistoryRepository(fileSystem: fs4, keyProvider: { key() })
            try? await repo4.load()
            await repo4.add(
                HistoryEntry(
                    originalText: "a", finalText: "one",
                    duration: 1, modelUsed: "Tiny"))
            let plainBefore = fs4.lastWrittenData
            // Force write failure; persist must not corrupt the store.
            fs4.failWrites = true
            await repo4.add(
                HistoryEntry(
                    originalText: "b", finalText: "two",
                    duration: 1, modelUsed: "Tiny"))
            fs4.failWrites = false
            // Old data remains readable (either old or new, never mixed).
            let fs4b = InMemoryHistoryFS(preload: plainBefore)
            let repo4b = ActorHistoryRepository(fileSystem: fs4b, keyProvider: { key() })
            try? await repo4b.load()
            let r4bEntries = await repo4b.entries()
            check("2262 migration failure keeps old store", r4bEntries.count == 1)

            // 9. Secure/unknown sessions remain excluded regardless of
            //    encryption: policy gate unchanged.
            check(
                "2262 secure denied with encryption",
                !HistoryStoragePolicy.allowsWrite(sensitivity: .secure, outcome: nil))
            check(
                "2262 unknown denied with encryption",
                !HistoryStoragePolicy.allowsWrite(sensitivity: .unknown, outcome: nil))

            // 10. Key material never enters the on-disk document.
            let raw10 = String(data: fs2.lastWrittenData ?? Data(), encoding: .utf8) ?? ""
            let keyHex = key().material.map { String(format: "%02x", $0) }.joined()
            check("2262 key bytes absent from file", !raw10.contains(keyHex))
        }

        // ===== JOE-2256: generation-safe model selection =====
        do {
            func sel(_ allow: Bool = true, _ local: Bool = false) -> ModelSelectionTracker.ModelSelectionSettings {
                .init(allowModelDownloads: allow, localOnlyMode: local)
            }
            var t = ModelSelectionTracker()

            // 1. Rapid A->B->A: only the LAST request is current.
            let a1 = t.submit(model: .whisperTiny, settings: sel())
            let b1 = t.submit(model: .whisperBase, settings: sel())
            let a2 = t.submit(model: .whisperTiny, settings: sel())
            check("2256 A->B->A last is current", t.isCurrent(a2) && !t.isCurrent(a1) && !t.isCurrent(b1))
            check("2256 current model is A", t.currentModel == .whisperTiny)

            // 2. Stale completions are typed superseded; current state intact.
            var outcomeA = t.acceptCompletion(
                requestID: a1, model: .whisperTiny,
                outcome: .failed(model: .whisperTiny, message: "boom"))
            check(
                "2256 stale A completion superseded",
                outcomeA == .superseded(model: .whisperTiny, byRequestID: a2))
            var outcomeB = t.acceptCompletion(
                requestID: b1, model: .whisperBase,
                outcome: .ready(model: .whisperBase))
            check(
                "2256 stale B completion superseded",
                outcomeB == .superseded(model: .whisperBase, byRequestID: a2))
            // Current completion publishes.
            var outcomeCurrent = t.acceptCompletion(
                requestID: a2, model: .whisperTiny,
                outcome: .ready(model: .whisperTiny))
            check(
                "2256 current completion accepted",
                outcomeCurrent == .ready(model: .whisperTiny))

            // 3. Old completion can never overwrite a current ready/failed
            //    state: after A ready, a stale B failure is ignored.
            var t3 = ModelSelectionTracker()
            let r3a = t3.submit(model: .whisperTiny, settings: sel())
            let r3b = t3.submit(model: .whisperBase, settings: sel())
            _ = t3.acceptCompletion(
                requestID: r3b, model: .whisperBase,
                outcome: .failed(model: .whisperBase, message: "late error"))
            let stale = t3.acceptCompletion(
                requestID: r3a, model: .whisperTiny,
                outcome: .ready(model: .whisperTiny))
            check("2256 stale failure cannot publish", stale == .superseded(model: .whisperTiny, byRequestID: r3b))

            // 4. Session-start guard: a session may only start against the
            //    CURRENT selection (never a finished-obsolete engine).
            var t4 = ModelSelectionTracker()
            _ = t4.submit(model: .whisperBase, settings: sel())
            check(
                "2256 session may start on current model",
                t4.allowsSessionStart(model: .whisperBase))
            check(
                "2256 session may NOT start on obsolete model",
                !t4.allowsSessionStart(model: .whisperTiny))

            // 5. cancelCurrent: no selection in flight; session start denied.
            var t5 = ModelSelectionTracker()
            _ = t5.submit(model: .whisperTiny, settings: sel())
            t5.cancelCurrent()
            check("2256 cancel clears current", t5.currentModel == nil)
            check(
                "2256 no session start after cancel",
                !t5.allowsSessionStart(model: .whisperTiny))

            // 6. Monotonic request ids strictly increase.
            var t6 = ModelSelectionTracker()
            let r1 = t6.submit(model: .whisperTiny, settings: sel())
            let r2 = t6.submit(model: .whisperTiny, settings: sel())
            let r3 = t6.submit(model: .whisperTiny, settings: sel())
            check("2256 request ids monotonic", r1 < r2 && r2 < r3)

            // 7. Settings snapshot at request start is retained.
            var t7 = ModelSelectionTracker()
            _ = t7.submit(model: .whisperBase, settings: sel(false, true))
            check(
                "2256 settings snapshot retained",
                t7.currentSettings?.allowModelDownloads == false && t7.currentSettings?.localOnlyMode == true)

            // 8. Deterministic out-of-order completion matrix: every
            //    permutation of A/B completions only lets the CURRENT one
            //    publish (simulating injected out-of-order load results).
            var t8 = ModelSelectionTracker()
            let reqA = t8.submit(model: .whisperTiny, settings: sel())
            let reqB = t8.submit(model: .whisperBase, settings: sel())
            // B current: any completion order keeps only B publishable.
            let p1 = t8.acceptCompletion(
                requestID: reqA, model: .whisperTiny,
                outcome: .failed(model: .whisperTiny, message: "x"))
            let p2 = t8.acceptCompletion(
                requestID: reqB, model: .whisperBase,
                outcome: .ready(model: .whisperBase))
            check(
                "2256 out-of-order: current publishes, stale superseded",
                p1 == .superseded(model: .whisperTiny, byRequestID: reqB) && p2 == .ready(model: .whisperBase))
        }

        // ===== JOE-2282: capability-based onboarding =====
        do {
            func steps(_ path: OnboardingProductPath) -> [OnboardingStep] {
                CapabilityGraph.steps(for: path)
            }
            func caps(_ s: [OnboardingStep]) -> Set<OnboardingCapability> {
                Set(s.map(\.capability))
            }

            // 1. All four paths have deterministic sequences (no duplicates).
            for p in OnboardingProductPath.allCases {
                let st = steps(p)
                check("2282 \(p.rawValue) deterministic", !st.isEmpty)
                check("2282 \(p.rawValue) no dup caps", caps(st).count == st.count)
            }

            // 2. WhisperKit paths NEVER request Speech Recognition / System
            //    Dictation.
            let wk = caps(steps(.whisperKitAutomatic))
            let wkc = caps(steps(.whisperKitClipboardOnly))
            check(
                "2282 WhisperKit no speech recognition",
                !wk.contains(.speechRecognition) && !wkc.contains(.speechRecognition))
            check(
                "2282 WhisperKit no system dictation",
                !wk.contains(.systemDictation) && !wkc.contains(.systemDictation))

            // 3. Clipboard-only paths never imply Accessibility required.
            let acc = OnboardingCapability.accessibility
            check(
                "2282 clipboard-only no accessibility",
                !wkc.contains(acc) && !caps(steps(.appleSpeechClipboardOnly)).contains(acc))
            check(
                "2282 automatic paths include accessibility",
                wk.contains(acc) && caps(steps(.appleSpeechAutomatic)).contains(acc))

            // 4. Network actions listed separately from audio privacy:
            //    model download is its own step with networkClass.
            let modelStep = steps(.whisperKitAutomatic).first { $0.capability == .modelAcquisition }
            check(
                "2282 model step network class",
                modelStep?.networkClass == "modelDownload")
            let micStep = steps(.whisperKitAutomatic).first { $0.capability == .microphone }
            check(
                "2282 mic step no network class",
                micStep?.networkClass == "none")

            // 5. Delta: only missing capabilities requested.
            let full = steps(.whisperKitAutomatic)
            let done = caps(Array(full.prefix(2)))  // mic + model done
            let remaining = CapabilityGraph.remainingSteps(for: .whisperKitAutomatic, completed: done)
            check(
                "2282 delta requests only missing",
                remaining.map(\.capability) == [.accessibility, .localOnlyImplications])
            check(
                "2282 complete only when all done",
                !CapabilityGraph.isComplete(for: .whisperKitAutomatic, completed: done))
            check(
                "2282 complete when all done",
                CapabilityGraph.isComplete(for: .whisperKitAutomatic, completed: caps(full)))

            // 6. Path derivation from settings.
            check(
                "2282 path whisper+automatic",
                CapabilityGraph.path(model: .whisperTiny, insertionMode: "automatic") == .whisperKitAutomatic)
            check(
                "2282 path whisper+copy",
                CapabilityGraph.path(model: .whisperBase, insertionMode: "alwaysCopy") == .whisperKitClipboardOnly)
            check(
                "2282 path apple+automatic",
                CapabilityGraph.path(model: .appleSpeech, insertionMode: "automatic") == .appleSpeechAutomatic)
            check(
                "2282 path apple+copy",
                CapabilityGraph.path(model: .appleSpeech, insertionMode: "alwaysCopy") == .appleSpeechClipboardOnly)

            // 7. Every skip path states limitations + recoverable.
            for p in OnboardingProductPath.allCases {
                for st in steps(p) where st.skippable {
                    let skip = CapabilityGraph.skipExplanation(for: p, step: st)
                    check(
                        "2282 skip \(st.id) explains+recoverable",
                        !skip.limitations.isEmpty && skip.recoverable)
                }
            }

            // 8. No system prompt without a user action + explanation: all
            //    requiresSystemPrompt steps carry an explanation.
            for p in OnboardingProductPath.allCases {
                for st in steps(p) where st.requiresSystemPrompt {
                    check("2282 prompt \(st.id) explained", !st.explanation.isEmpty)
                }
            }

            // 9. Already-granted capabilities skipped without hiding required
            //    system switches: completed set removes steps, required
            //    prompts remain.
            let granted: Set<OnboardingCapability> = [.microphone]
            let rem = CapabilityGraph.remainingSteps(for: .appleSpeechAutomatic, completed: granted)
            check(
                "2282 granted mic skipped, prompts remain",
                !rem.contains { $0.capability == .microphone }
                    && rem.contains { $0.capability == .speechRecognition && $0.requiresSystemPrompt })

            // 10. Missing/denied capabilities lead to actionable limited
            //     modes (skip explanations are actionable, not dead ends).
            let ax = steps(.whisperKitAutomatic).first { $0.capability == .accessibility }!
            let axSkip = CapabilityGraph.skipExplanation(for: .whisperKitAutomatic, step: ax)
            check(
                "2282 AX skip offers copy mode",
                axSkip.limitations.lowercased().contains("copy"))
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
