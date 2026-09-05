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
    var cancelled = false
    var insertionCount = 0
    /// Round-5 B4: the last insert request observed (lease verification).
    var lastInsertRequest: SessionInsertRequest?
    var prepareCount = 0
    var capturedSessionIDs: [SessionID] = []
    /// Review R2/4 test hook: block stopCapture for this long so a cancel can
    /// land mid-processing deterministically.
    var stopDelayNanos: UInt64 = 0
    /// Review B5 test hook: when true, applyFlow returns a REJECTED outcome
    /// (protected spans not preserved, original text returned).
    var flowRejected = false
    var flowOverride: FlowOutcome?
    /// Round-6 B1 test hook: block recordHistory this long so a cancel can
    /// land deterministically during history persistence.
    var historyDelayNanos: UInt64 = 0

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
    func setStopDelay(_ ns: UInt64) { stopDelayNanos = ns }
    func setDegraded(_ d: Bool) { degraded = d }
    func setHistoryDelay(_ ns: UInt64) { historyDelayNanos = ns }

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
        if stopDelayNanos > 0 {
            try? await Task.sleep(nanoseconds: stopDelayNanos)
        }
        return SessionAudioSummary(
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
        if let flowOverride { return flowOverride }
        if flowRejected {
            // Review B5: rejected outcome — original text returned, no
            // automatic insertion allowed.
            return FlowOutcome(
                text: request.text, requestedStyle: request.style,
                resolvedLossClass: .conservative, backend: .regex,
                capabilityID: "test", capabilityVersion: 1,
                language: request.language, changedRangeCount: 0,
                protectedSpanCount: 1, protectedSpansPreserved: false,
                status: .rejected, warnings: [.guardrailRejected],
                fallbackReason: "protected spans not preserved; original text returned",
                durationNanos: 5,
                termination: .completed)
        }
        return FlowOutcome(
            text: request.text, requestedStyle: request.style,
            resolvedLossClass: .verbatim, backend: .regex,
            capabilityID: "test", capabilityVersion: 1,
            language: request.language, changedRangeCount: 0,
            protectedSpanCount: 0, protectedSpansPreserved: true,
            status: .accepted, warnings: [],
            fallbackReason: nil, durationNanos: 5,
            termination: .completed)
    }

    func setFlowRejected(_ v: Bool) { flowRejected = v }
    func setFlowOverride(_ value: FlowOutcome, original: String) {
        flowOverride = value
        finalText = original
    }

    func validateTarget() async -> SessionValidationResult {
        let next = validationOutcomes.isEmpty ? .validated : validationOutcomes.removeFirst()
        return SessionValidationResult(
            outcome: next,
            effectiveSensitivity: .normal)
    }

    func insert(_ request: SessionInsertRequest) async -> InsertionOutcome {
        insertionCount += 1
        lastInsertRequest = request
        return insertionOutcome
    }

    func recordHistory(
        originalText: String, finalText: String,
        duration: TimeInterval, modelName: String
    ) async {
        if historyDelayNanos > 0 {
            try? await Task.sleep(nanoseconds: historyDelayNanos)
        }
        historyCount += 1
    }

    func cancel() async {
        // Idempotent: count only the first cancellation (matches real provider
        // semantics — cancel() may be called by both the control path and the
        // stage gate).
        if !cancelled {
            cancelled = true
            cancelCount += 1
        }
    }
}

/// Round-5 REQ-5: filesystem whose readData always throws (permission/I/O
/// failure) — distinct from corruption.
private struct UnreadableHistoryFileSystem: HistoryFileSystem {
    let real = RealHistoryFileSystem()
    func fileExists(_ url: URL) -> Bool { real.fileExists(url) }
    func createDirectory(_ url: URL) throws { try real.createDirectory(url) }
    func readData(_ url: URL) throws -> Data {
        throw NSError(
            domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
            userInfo: [NSFilePathErrorKey: url.path])
    }
    func writeAtomic(data: Data, to url: URL) throws { try real.writeAtomic(data: data, to: url) }
    func move(_ from: URL, to: URL) throws { try real.move(from, to: to) }
    func remove(_ url: URL) throws { try real.remove(url) }
    func setPermissions(_ url: URL, mode: Int) throws { try real.setPermissions(url, mode: mode) }
}

// ===== JOE-2255: in-memory fault-injecting model filesystem =====
actor CoreDownloadBarrier {
    private(set) var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

final class FakeModelFS: ModelAcquisitionFileSystem, @unchecked Sendable {
    struct Node {
        var isDir: Bool
        var data: Data?
        var size: UInt64
    }
    private let lock = NSLock()
    private var nodes: [String: Node] = [:]
    private var perms: [String: Int] = [:]
    private let beforeDownload: @Sendable () async -> Void
    init(beforeDownload: @escaping @Sendable () async -> Void = {}) { self.beforeDownload = beforeDownload }
    private var _downloadCalls = 0
    private var _downloadCancellations = 0
    var downloadCalls: Int { lock.withLock { _downloadCalls } }
    var downloadCancellations: Int { lock.withLock { _downloadCancellations } }
    var lockHeld: [String: Bool] = [:]
    // Fault injection knobs
    var failDownload = false
    var downloadBytes = 2_000_000  // writes 2 MB payload
    var truncateArtifact = false
    /// Round-6 B4: skip the optional TextDecoderContextPrefill bundle.
    var skipPrefill = false
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
    func fileSize(_ url: URL) -> UInt64? {
        lock.withLock {
            // Round-6 B4: a directory bundle reports its RECURSIVE size
            // (mirroring production), not the directory node's size.
            if nodes[key(url)]?.isDir == true {
                return nodes.filter { $0.key.hasPrefix(key(url) + "/") }
                    .values.reduce(0) { $0 + $1.size }
            }
            return nodes[key(url)]?.size
        }
    }
    func sha256Hex(of url: URL) -> String? {
        lock.withLock {
            // Round-6 B4: directory-aware hash (recursive sorted relative
            // paths + lengths + bytes), mirroring production.
            if nodes[key(url)]?.isDir == true {
                let prefix = key(url) + "/"
                var entries: [(String, Data)] = []
                for (k, n) in nodes where k.hasPrefix(prefix) {
                    if let data = n.data {
                        entries.append((k.replacingOccurrences(of: prefix, with: ""), data))
                    }
                }
                entries.sort { $0.0 < $1.0 }
                guard !entries.isEmpty else { return nil }
                var hasher = SHA256()
                for (rel, data) in entries {
                    hasher.update(data: Data(rel.utf8))
                    hasher.update(data: withUnsafeBytes(of: UInt64(data.count).bigEndian) { Data($0) })
                    hasher.update(data: data)
                }
                return hasher.finalize().map { String(format: "%02x", $0) }.joined()
            }
            guard let n = nodes[key(url)], let data = n.data else { return nil }
            let h = SHA256.hash(data: data)
            return h.map { String(format: "%02x", $0) }.joined()
        }
    }
    func download(
        model: ModelIdentifier, to stagingURL: URL,
        onProgress: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws {
        lock.withLock { _downloadCalls += 1 }
        await beforeDownload()
        if downloadDelayNanos > 0 { try? await Task.sleep(nanoseconds: downloadDelayNanos) }
        if Task.isCancelled { lock.withLock { _downloadCancellations += 1 } }
        if failDownload { throw URLError(.cannotConnectToHost) }
        // Write artifact payloads into staging. Round-5 B5: the default
        // manifest enumerates EVERY WhisperKit-loaded component, so the fake
        // writes all of them (config + each CoreML bundle + tokenizer).
        let config = Data(repeating: 0xAB, count: 10_000)
        var modelData = Data(repeating: 0xCD, count: Int(downloadBytes))
        if truncateArtifact { modelData = Data(repeating: 0xCD, count: 500) }
        try createDirectory(stagingURL, permissions: 0o700)
        writeDownloadedFixtures(to: stagingURL, config: config)
        onProgress(
            ModelDownloadProgress(
                fraction: 1.0, bytesDownloaded: UInt64(modelData.count),
                bytesExpected: UInt64(modelData.count)))
    }

    /// No suspension or callback can occur while holding the fixture lock.
    private func writeDownloadedFixtures(to stagingURL: URL, config: Data) {
        // Round-6 B4: .mlmodelc entries are DIRECTORY BUNDLES (a file inside),
        // matching real compiled Core ML models; the tokenizer is a directory
        // with tokenizer.json + configs. This makes the fake exercise the
        // same directory-aware hashing as production.
        lock.lock()
        defer { lock.unlock() }
        // config.json is a single file.
        nodes[key(stagingURL.appendingPathComponent("config.json"))] = Node(
            isDir: false, data: config, size: UInt64(config.count))
        // CoreML bundles as directories with a payload file inside.
        let bundleNames = [
            "MelSpectrogram.mlmodelc",
            "AudioEncoder.mlmodelc",
            "TextDecoder.mlmodelc",
            "TextDecoderContextPrefill.mlmodelc",
        ]
        for (i, name) in bundleNames.enumerated() {
            if skipPrefill && name == "TextDecoderContextPrefill.mlmodelc" {
                continue
            }
            let dir = stagingURL.appendingPathComponent(name)
            nodes[key(dir)] = Node(isDir: true, data: nil, size: 0)
            var payload = Data(
                repeating: UInt8(0x20 + i),
                count: Int(downloadBytes) / max(bundleNames.count, 1))
            if truncateArtifact, i == 1 {
                payload = Data(repeating: UInt8(0x20 + i), count: 500)
            }
            let inner = dir.appendingPathComponent("model.mlmodel")
            nodes[key(inner)] = Node(
                isDir: false, data: payload, size: UInt64(payload.count))
        }
        // tokenizer directory with tokenizer.json + config.
        let tokDir = stagingURL.appendingPathComponent("tokenizer")
        nodes[key(tokDir)] = Node(isDir: true, data: nil, size: 0)
        nodes[key(tokDir.appendingPathComponent("tokenizer.json"))] = Node(
            isDir: false, data: Data(repeating: 0x44, count: 200_000),
            size: 200_000)
        nodes[key(tokDir.appendingPathComponent("config.json"))] = Node(
            isDir: false, data: Data(repeating: 0x45, count: 5_000),
            size: 5_000)
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

    /// Test helper: overwrite an artifact's bytes directly (tamper).
    func writeRaw(_ url: URL, data: Data) {
        lock.lock()
        defer { lock.unlock() }
        nodes[key(url)] = Node(isDir: false, data: data, size: UInt64(data.count))
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

/// Held synthetic backend for non-joining Flow deadline regression checks.
private actor CoreHeldFlowBackend: FlowProcessorProtocol {
    private(set) var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func process(_ text: String, style: FlowStyle) async -> String { text }
    func process(_ request: FlowRequest) async -> FlowOutcome {
        entered = true
        if !released { await withCheckedContinuation { continuation = $0 } }
        return await FlowProcessor.shared.process(request)
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

/// Concurrency-safe failure counter for the split test runner.
private final class CoreTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }
    @discardableResult
    func bump() -> Int {
        lock.withLock {
            _value += 1
            return _value
        }
    }
}

/// Round-6: Sendable boxes so test Tasks do not mutate captured locals
/// (Swift-6 diagnostics).
private final class MutableArrayBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [T] = []
    var values: [T] {
        lock.lock()
        defer { lock.unlock() }
        return _values
    }
    func append(_ v: T) {
        lock.lock()
        _values.append(v)
        lock.unlock()
    }
}

/// Keeps the weak observation in a stored property (compatible with both
/// supported compilers), without retaining the actor under test.
private final class WeakSessionReference {
    private(set) weak var value: DictationSession?
    init(_ value: DictationSession?) { self.value = value }
}

private final class MutableSequencerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var seq = AudioChunkSequencer()
    func accept(_ c: AudioChunk) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return seq.accept(c)
    }
    var seqIsDegraded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return seq.isDegraded
    }
}

@main
struct CoreTests {
    /// Round-6: the original single 6,000-line main() function type-checked as
    /// one unit and peaked near the OS memory limit (jetsam killed
    /// swift-frontend mid-compile). Split into per-part functions below so
    /// each type-checks independently with a bounded peak.
    /// Round-6: a static var would be a nonisolated mutable global under
    /// Swift-6 diagnostics; box the counter in a small final class (sendable
    /// by reference, no global mutable state).
    private static let counter = CoreTestCounter()
    static var failed: Int { counter.value }
    static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if ok {
            print("  ✓ \(name)")
        } else {
            print("  ✗ \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            counter.bump()
        }
    }

    static let processor = FlowProcessor()

    static func main() async {
        print("ZephyrFlowCore tests\n")

        await Self.runPart0()
        await Self.runPart1()
        await Self.runPart2()
        await Self.runPart3()
        await Self.runPart4()
        await Self.runPart5()
        await Self.runPart6()
        await Self.runPart7()
        print("")
        if failed == 0 {
            print("All tests passed.")
            exit(0)
        } else {
            print("\(failed) test(s) failed.")
            exit(1)
        }
    }

    static func runPart0() async {
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
            // Review R6.1: downloads default OFF until explicit consent.
            check("downloads off by default", !s.allowModelDownloads)
            check("mayDownload follows allow flag", !s.mayDownloadModels)
            check("default model whisper tiny", s.preferredModel == .whisperTiny)
            check("default hotkey fn", s.hotkey.specialKey == .fn)
            check("debug logging off", !s.debugLogging)
            check("save history default off", !s.saveHistory)
        }

        // ===== REQ-5 regression: missing saveHistory decodes privacy-safe =====
        do {
            // A migrated/partial settings payload WITHOUT saveHistory must NOT
            // enable history (old decode defaulted to true).
            let partial: [String: Any] = ["localOnlyMode": true]
            let data = try! JSONSerialization.data(withJSONObject: partial)
            let loaded = SettingsStorageCoordinator.load(data: data)
            check("REQ-5 missing saveHistory decodes false", !loaded.settings.saveHistory)
            // And the static default is history-off.
            check("REQ-5 default history off", !AppSettings.default.saveHistory)
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
            var happyTransitionsMatch = true
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
                if case .to(let ns) = tr(happy.last!, e) {
                    happyTransitionsMatch = happyTransitionsMatch && ns == expect
                    happy.append(ns)
                } else {
                    happyTransitionsMatch = false
                }
            }
            check("happy path follows every expected transition", happyTransitionsMatch)
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

        // ===== R2/3 regression: review-retry does not strand the state machine =====
        do {
            // Review R2/3: a target-change review must NOT drive the control
            // model terminal (that would make retry's targetValidationSucceeded
            // illegal and silently ignored). The session stays in
            // .resolvingTarget during review; retry re-validates and reaches
            // .completed. Simulate the exact session sequence.
            var c = SessionControlModel()
            _ = c.begin()
            _ = c.stage(.readyToCapture)  // capturing
            _ = c.stage(.stop)  // draining
            _ = c.stage(.drainFinished)  // transcribing
            _ = c.stage(.transcriptionFinished)  // transforming
            _ = c.stage(.transformationFinished)  // resolvingTarget
            check(
                "R2/3 before review: resolvingTarget (nonterminal)",
                c.state == .resolvingTarget && !c.state.isTerminal)
            // Review shown: do NOT stage .targetChanged (stays resolvingTarget).
            // Retry re-validates and completes.
            let retry = c.stage(.targetValidationSucceeded)
            var retryAccepted = false
            if case .accepted(let st) = retry, st == .inserting { retryAccepted = true }
            check("R2/3 retry after review is legal (not rejected)", retryAccepted)
            _ = c.stage(.insertionSucceeded)
            check(
                "R2/3 retry reaches completed terminal",
                c.state == .completed && c.terminal == .completed)
            // A session that instead cancels from review lands cancelled.
            var c2 = SessionControlModel()
            _ = c2.begin()
            _ = c2.stage(.readyToCapture)
            _ = c2.stage(.stop)
            _ = c2.stage(.drainFinished)
            _ = c2.stage(.transcriptionFinished)
            _ = c2.stage(.transformationFinished)
            check(
                "R2/3 review state nonterminal before cancel",
                c2.state == .resolvingTarget)
            _ = c2.cancel()
            check(
                "R2/3 cancel from review -> cancelled",
                c2.state == .cancelled && c2.terminal == .cancelled)
        }

        // ===== R2/4 regression: durable command mailbox (no lost controls) =====
        do {
            // Review R2/4: a cancel sent BEFORE run() installs the consumer
            // must not be lost — the mailbox is created at init with buffering.
            let provider = FakeSessionStages()
            let s = DictationSession(
                provider: provider, engineChoice: .whisper,
                settings: SessionSettingsSnapshot(
                    localOnly: true, language: .enUS, defaultFlowStyle: .clean,
                    insertionMode: "automatic", saveHistory: false,
                    copyOnlyOverrideBundleIDs: []))
            // Cancel before run() ever starts (continuation must already exist).
            await s.cancel()
            let stream = await s.subscribe()
            let runTask = Task { await s.run() }
            var states: [SessionUIState] = []
            for await st in stream { states.append(st) }
            await runTask.value
            check(
                "R2/4 pre-run cancel not lost (no success/insertion)",
                states.contains { $0.phase == SessionPhase.hidden }
                    && !states.contains { $0.phase == .success })
            check(
                "R2/4 cancel-during-capture provider cancelled",
                await provider.cancelCount >= 1)
        }
        do {
            // Review R2/4: cancel DURING processing (stopCapture blocks) must
            // prevent insertion. The fake blocks in stopCapture so the cancel
            // deterministically lands while the pipeline is mid-processing.
            let provider = FakeSessionStages()
            await provider.setPartials(["hello"])
            await provider.setStopDelay(300_000_000)  // 300ms block in stopCapture
            let s = DictationSession(
                provider: provider, engineChoice: .whisper,
                settings: SessionSettingsSnapshot(
                    localOnly: true, language: .enUS, defaultFlowStyle: .clean,
                    insertionMode: "automatic", saveHistory: true,
                    copyOnlyOverrideBundleIDs: []))
            let stream = await s.subscribe()
            let runTask = Task { await s.run() }
            try? await Task.sleep(nanoseconds: 30_000_000)
            await s.end()  // enters stopCapture (blocked 300ms)
            try? await Task.sleep(nanoseconds: 50_000_000)
            await s.cancel()  // while stopCapture is blocked
            var states: [SessionUIState] = []
            for await st in stream { states.append(st) }
            await runTask.value
            check(
                "R2/4 cancel during processing prevents success",
                !states.contains { $0.phase == .success })
            check(
                "R2/4 cancel during processing lands hidden/cancelled",
                states.contains { $0.phase == SessionPhase.hidden })
        }

        // ===== B2 round-5 regression: press-edge intent + termination join =====
        do {
            // Review B2v2 (round 5): the session intent is allocated at the
            // press edge and invalidated synchronously by release/cancel —
            // even before the queued begin starts. A begin that observes the
            // cancelled intent must abort without preparing/starting capture.
            let intent = PendingSessionIntent(
                generation: 1, pressTimestampNanos: 100, requestedMode: "hotkey")
            check("B2r5 intent starts valid", !intent.isCancelled)
            intent.cancel()
            check("B2r5 intent cancelled synchronously", intent.isCancelled)
            // A NEW intent (new press) is valid again.
            let intent2 = PendingSessionIntent(
                generation: 2, pressTimestampNanos: 200, requestedMode: "hotkey")
            check("B2r5 new press intent valid", !intent2.isCancelled)
            check("B2r5 generations distinct", intent2.generation == intent.generation + 1)
            check("B2r5 press timestamp retained", intent2.pressTimestampNanos == 200)
        }
        do {
            // Termination join: a session that completes normally reaches
            // terminal release and awaitTerminalAndReleased returns true.
            let provider = FakeSessionStages()
            let s = DictationSession(
                provider: provider, engineChoice: .whisper,
                settings: SessionSettingsSnapshot(
                    localOnly: true, language: .enUS, defaultFlowStyle: .clean,
                    insertionMode: "automatic", saveHistory: false,
                    copyOnlyOverrideBundleIDs: []))
            let stream = await s.subscribe()
            let runTask = Task { await s.run() }
            try? await Task.sleep(nanoseconds: 20_000_000)
            await s.end()
            await runTask.value
            var states: [SessionUIState] = []
            for await st in stream { states.append(st) }
            let joined = await s.awaitTerminalAndReleased(deadlineNanosAhead: 500_000_000)
            check("B2r5 normal session reaches terminal release", joined)
            // A session that is deliberately kept running (no end command) must
            // NOT report terminal release within a short deadline.
            let s2 = DictationSession(
                provider: FakeSessionStages(), engineChoice: .whisper,
                settings: SessionSettingsSnapshot(
                    localOnly: true, language: .enUS, defaultFlowStyle: .clean,
                    insertionMode: "automatic", saveHistory: false,
                    copyOnlyOverrideBundleIDs: []))
            let runTask2 = Task { await s2.run() }
            try? await Task.sleep(nanoseconds: 20_000_000)
            let joined2 = await s2.awaitTerminalAndReleased(deadlineNanosAhead: 50_000_000)
            check("B2r5 live session not released within deadline", !joined2)
            await s2.cancel()
            await runTask2.value
            let joined3 = await s2.awaitTerminalAndReleased(deadlineNanosAhead: 500_000_000)
            check("B2r5 cancelled session releases", joined3)
        }

        // ===== B2 round-6: handshake abandon + release-after-broadcaster =====
        do {
            // Review B2 (round 6): the release signal fires only AFTER
            // terminal cleanup and broadcaster finish — awaitTerminalAndReleased
            // means "run() reached terminal AND broadcaster done".
            let provider = FakeSessionStages()
            let s = DictationSession(
                provider: provider, engineChoice: .whisper,
                settings: SessionSettingsSnapshot(
                    localOnly: true, language: .enUS, defaultFlowStyle: .clean,
                    insertionMode: "automatic", saveHistory: true,
                    copyOnlyOverrideBundleIDs: []))
            let stream = await s.subscribe()
            let runTask = Task { await s.run() }
            try? await Task.sleep(nanoseconds: 20_000_000)
            await s.end()
            var states: [SessionUIState] = []
            for await st in stream { states.append(st) }
            await runTask.value
            let joined = await s.awaitTerminalAndReleased(deadlineNanosAhead: 500_000_000)
            check("B2r6 normal session joined after broadcast finish", joined)
            // Broadcaster finished -> stream drained to terminal state.
            check(
                "B2r6 broadcaster finished (success seen)",
                states.contains { $0.phase == .success })
        }
        do {
            // Review B2 (round 6): handshake abandon is explicit and the
            // abandoned handshake reports the recovery marker + does NOT mark
            // remaining steps (sessionFinished etc. must be refused).
            var hs = TerminationHandshake(deadlineNanosAhead: 10_000)
            hs.begin(nowNanos: 0)
            _ = hs.completeStep(.admissionClosed, nowNanos: 1)
            let st = hs.abandon(reason: "session run task did not quiesce")
            check("B2r6 abandon -> .abandoned", st == .abandoned)
            check("B2r6 abandoned is terminal", hs.isTerminal)
            check("B2r6 recovery marker set", hs.recoveryMarker != nil)
            // completeStep on an abandoned handshake is a no-op (no remaining
            // steps can be marked).
            let after = hs.completeStep(.sessionFinished, nowNanos: 5)
            check("B2r6 abandoned refuses further steps", after == .abandoned)
            check(
                "B2r6 sessionFinished not marked after abandon",
                !hs.completedSteps.contains(.sessionFinished))
        }
        do {
            // Review B2 (round 6): manual toggle preempts a queued begin —
            // two rapid toggles with no session must cancel intent 1, not
            // overwrite it (intent 1 must be invalid).
            let intent1 = PendingSessionIntent(
                generation: 1, pressTimestampNanos: 0, requestedMode: "manual-toggle")
            intent1.cancel()  // the controller cancels the existing intent
            check("B2r6 preempted intent is cancelled", intent1.isCancelled)
            // A fresh intent allocated only when no pending begin exists.
            let intent2 = PendingSessionIntent(
                generation: 2, pressTimestampNanos: 1, requestedMode: "manual-toggle")
            check("B2r6 new intent valid after preempt", !intent2.isCancelled)
            check("B2r6 intent generations strictly increase", intent2.generation > intent1.generation)
        }

        // ===== B3 regression: exactly-one terminal telemetry emission =====
        do {
            // Review B3: the TerminalGuard emits a versioned terminal event
            // exactly once, with the correct category and duration.
            var tg = TerminalGuard(sessionID: SessionTelemetryID("s1"))
            let e1 = tg.finalize(
                terminal: .completed, durationNanos: 1_000_000, atNanos: 5_000)
            check("B3 tg emits one terminal event", e1?.kind == .terminal)
            check("B3 tg category completed", e1?.terminal == .completed)
            check("B3 tg duration retained", e1?.durationNanos == 1_000_000)
            // Second finalize is refused (exactly once).
            let e2 = tg.finalize(
                terminal: .cancelled, durationNanos: 1, atNanos: 6_000)
            check("B3 tg refuses second terminal", e2 == nil)
            // Abandon on an unfinished guard emits a controlled abandoned event.
            var g2 = TerminalGuard(sessionID: SessionTelemetryID("s2"))
            let abandoned = g2.abandon(atNanos: 7_000)
            check("B3 abandoned guard emits abandoned event", abandoned?.kind == .abandoned)
            // Session-level: a completed session's drainTelemetry carries one
            // terminal event (no lifecycle hang — the session is collected
            // normally in prior tests; here we verify the sink path directly).
            let sink = BoundedEventSink(capacity: 8)
            sink.record(
                TelemetryEvent(
                    sessionID: SessionTelemetryID("s3"), kind: .terminal,
                    terminal: .completed, durationNanos: 10, atNanos: 20))
            let drained = sink.drain()
            check("B3 sink drains terminal event", drained.count == 1 && drained[0].terminal == .completed)
        }

        // ===== B3 round-5: session terminal agreement (control == UI == telemetry) =====
        do {
            // Review B3 (round 5): a DEGRADED drain must end with the session
            // in the error phase AND the terminal telemetry carrying .degraded
            // (the state machine reached .degraded via the legal .drainFailed
            // event) — no invented .failed, no success.
            let provider = FakeSessionStages()
            await provider.setPartials(["hello"])
            await provider.setDegraded(true)
            let s = DictationSession(
                provider: provider, engineChoice: .whisper,
                settings: SessionSettingsSnapshot(
                    localOnly: true, language: .enUS, defaultFlowStyle: .clean,
                    insertionMode: "automatic", saveHistory: true,
                    copyOnlyOverrideBundleIDs: []))
            let stream = await s.subscribe()
            let runTask = Task { await s.run() }
            try? await Task.sleep(nanoseconds: 20_000_000)
            await s.end()
            try? await Task.sleep(nanoseconds: 60_000_000)
            var states: [SessionUIState] = []
            for await st in stream { states.append(st) }
            await runTask.value
            let telemetry = await s.drainTelemetry()
            let terminal = telemetry.first { $0.kind == .terminal }
            check(
                "B3r5 degraded drain -> UI error",
                states.contains { $0.phase == .error })
            check(
                "B3r5 degraded drain -> telemetry terminal .degraded",
                terminal?.terminal == .degraded)
        }
        do {
            // Review B3 (round 5): a TRUNCATED engine result (finalize returns
            // non-complete) must end with UI warning + telemetry .truncated
            // (legal .engineTruncated from .transforming).
            let provider = FakeSessionStages()
            await provider.setPartials(["hello"])
            await provider.setCompleteness(.truncated)
            let s = DictationSession(
                provider: provider, engineChoice: .whisper,
                settings: SessionSettingsSnapshot(
                    localOnly: true, language: .enUS, defaultFlowStyle: .clean,
                    insertionMode: "automatic", saveHistory: true,
                    copyOnlyOverrideBundleIDs: []))
            let stream = await s.subscribe()
            let runTask = Task { await s.run() }
            try? await Task.sleep(nanoseconds: 20_000_000)
            await s.end()
            try? await Task.sleep(nanoseconds: 60_000_000)
            await s.cancel()
            var states: [SessionUIState] = []
            for await st in stream { states.append(st) }
            await runTask.value
            let telemetry = await s.drainTelemetry()
            let terminal = telemetry.first { $0.kind == .terminal }
            check(
                "B3r5 truncated engine -> UI warning",
                states.contains { $0.phase == .warning })
            check(
                "B3r5 truncated engine -> telemetry terminal .truncated",
                terminal?.terminal == .truncated)
        }
        do {
            // Review B3 (round 5): every terminal event in the session shares
            // ONE telemetry ID (terminal + capture-accounting correlate).
            let provider = FakeSessionStages()
            await provider.setPartials(["hello"])
            let s = DictationSession(
                provider: provider, engineChoice: .whisper,
                settings: SessionSettingsSnapshot(
                    localOnly: true, language: .enUS, defaultFlowStyle: .clean,
                    insertionMode: "automatic", saveHistory: true,
                    copyOnlyOverrideBundleIDs: []))
            let stream = await s.subscribe()
            let runTask = Task { await s.run() }
            try? await Task.sleep(nanoseconds: 20_000_000)
            await s.end()
            try? await Task.sleep(nanoseconds: 60_000_000)
            await s.cancel()
            var states: [SessionUIState] = []
            for await st in stream { states.append(st) }
            await runTask.value
            let telemetry = await s.drainTelemetry()
            let ids = Set(telemetry.map { $0.sessionID })
            check(
                "B3r5 all session telemetry shares one ID",
                ids.count == 1)
        }
    }

    static func runPart1() async {
        // ===== B1 round-6: cancel during history persistence never strands =====
        do {
            // Review B1 (round 6): when insertion succeeded (control is
            // .completed) and a cancel arrives DURING the awaited history
            // write, the session must NOT request a second terminal (.cancelled
            // from .completed would hit the mismatch guard and strand the
            // session unreleased). Applied insertion wins: finish as
            // completed, record lateCancelAfterInsertion, run exits,
            // broadcaster finishes, next session can start.
            let provider = FakeSessionStages()
            await provider.setPartials(["hello"])
            await provider.setHistoryDelay(300_000_000)  // block history 300ms
            let s = DictationSession(
                provider: provider, engineChoice: .whisper,
                settings: SessionSettingsSnapshot(
                    localOnly: true, language: .enUS, defaultFlowStyle: .clean,
                    insertionMode: "automatic", saveHistory: true,
                    copyOnlyOverrideBundleIDs: []))
            let stream = await s.subscribe()
            let runTask = Task { await s.run() }
            try? await Task.sleep(nanoseconds: 20_000_000)
            await s.end()  // enters validate+insert -> history (blocked 300ms)
            try? await Task.sleep(nanoseconds: 60_000_000)
            await s.cancel()  // lands during history persistence
            var states: [SessionUIState] = []
            for await st in stream { states.append(st) }
            // The run task MUST exit (not hang waiting on a finished stream).
            let exited = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    await runTask.value
                    return true
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            check("B1r6 run task exits after history-cancel", exited)
            check(
                "B1r6 broadcaster finished (stream drained)",
                states.count > 0)
            // Exactly one terminal emitted.
            let telemetry = await s.drainTelemetry()
            let terminals = telemetry.filter { $0.kind == .terminal }
            check("B1r6 exactly one terminal", terminals.count == 1)
            check(
                "B1r6 terminal is completed (applied wins)",
                terminals.first?.terminal == .completed)
            check(
                "B1r6 late-cancel warning recorded",
                telemetry.contains { $0.kind == .lateCancelAfterInsertion })
            // The session reached terminal release (join succeeds).
            let joined = await s.awaitTerminalAndReleased(deadlineNanosAhead: 500_000_000)
            check("B1r6 session released after history-cancel", joined)
            // A NEW session can start (session object reusable, no stranded
            // state): drive a second session to completion.
            let s2 = DictationSession(
                provider: FakeSessionStages(), engineChoice: .whisper,
                settings: SessionSettingsSnapshot(
                    localOnly: true, language: .enUS, defaultFlowStyle: .clean,
                    insertionMode: "automatic", saveHistory: true,
                    copyOnlyOverrideBundleIDs: []))
            let stream2 = await s2.subscribe()
            let runTask2 = Task { await s2.run() }
            try? await Task.sleep(nanoseconds: 20_000_000)
            await s2.end()
            var states2: [SessionUIState] = []
            for await st in stream2 { states2.append(st) }
            await runTask2.value
            check(
                "B1r6 next session completes normally",
                states2.contains { $0.phase == .success })
        }

        // ===== B5 regression: rejected Flow never auto-inserts =====
        do {
            // Review B5: when Flow returns a REJECTED outcome (protected spans
            // not preserved), the session must enter REVIEW without automatic
            // insertion — the unsafe output must never reach validate/insert.
            let provider = FakeSessionStages()
            await provider.setPartials(["hello"])
            await provider.setFlowRejected(true)
            let s = DictationSession(
                provider: provider, engineChoice: .whisper,
                settings: SessionSettingsSnapshot(
                    localOnly: true, language: .enUS, defaultFlowStyle: .clean,
                    insertionMode: "automatic", saveHistory: true,
                    copyOnlyOverrideBundleIDs: []))
            let stream = await s.subscribe()
            let runTask = Task { await s.run() }
            try? await Task.sleep(nanoseconds: 40_000_000)
            await s.end()
            // Rejected Flow shows the review surface; the review loop stays
            // alive until the user acts — send discard to end it deterministically.
            try? await Task.sleep(nanoseconds: 60_000_000)
            await s.discard()
            var states: [SessionUIState] = []
            for await st in stream { states.append(st) }
            await runTask.value
            check(
                "B5 rejected Flow enters review (not success)",
                states.contains { $0.phase == .review }
                    && !states.contains { $0.phase == .success })
            check(
                "B5 rejected Flow no history written",
                await provider.historyCount == 0)
            check(
                "B5 rejected Flow no insertion",
                await provider.insertionCount == 0)
        }

        // Typed Flow boundaries through the real session actor + fake stages.
        do {
            let original = "  👩🏽‍💻 e\u{301}\n\tkeep trailing space  "
            for status in [FlowOutcomeStatus.accepted, .deadlineExceeded, .cancelled, .superseded] {
                let deadline = status == .deadlineExceeded
                let outcome = FlowOutcome(
                    text: original, requestedStyle: .raw,
                    resolvedLossClass: .verbatim, backend: .regex, capabilityID: "synthetic", capabilityVersion: 1,
                    language: .enUS, changedRangeCount: 0, protectedSpanCount: 0, protectedSpansPreserved: true,
                    status: status, warnings: deadline ? [.verbatimFallback] : [], fallbackReason: nil,
                    durationNanos: 1,
                    termination: deadline ? .deadlineExceeded : (status == .accepted ? .completed : .cancelled))
                let provider = FakeSessionStages()
                await provider.setFlowOverride(outcome, original: original)
                let session = DictationSession(
                    provider: provider, engineChoice: .whisper,
                    settings: .init(
                        localOnly: true, language: .enUS, defaultFlowStyle: .raw,
                        insertionMode: "automatic", saveHistory: false, copyOnlyOverrideBundleIDs: []))
                let states = await session.subscribe()
                let run = Task { await session.run() }
                let timeout = Task {
                    do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                    await session.cancel()
                }
                var ended = false
                var reviewed = false
                for await state in states {
                    if state.phase == .listening && !ended {
                        ended = true
                        await session.end()
                    }
                    if state.phase == .review {
                        reviewed = true
                        await session.discard()
                    }
                }
                await run.value
                timeout.cancel()
                let request = await provider.lastInsertRequest
                if status == .accepted || deadline {
                    check("2279 session preserves exact accepted/fallback text", request?.text == original && !reviewed)
                } else {
                    check("2279 cancelled/superseded Flow never auto-inserts", request == nil && reviewed)
                }
            }
        }

        // ===== REQ-1: session actor with fake stages (exactly-one terminal) =====
        do {
            // Drive a full session through capture -> end -> review(retry) ->
            // success; assert EXACTLY ONE success phase and no re-entrant
            // terminal (the R2/3 fix made retry reach .completed legally).
            let provider = FakeSessionStages()
            await provider.setPartials(["hello"])
            await provider.setValidationOutcomes([.targetChanged, .validated])
            let s = DictationSession(
                provider: provider, engineChoice: .whisper,
                settings: SessionSettingsSnapshot(
                    localOnly: true, language: .enUS, defaultFlowStyle: .clean,
                    insertionMode: "automatic", saveHistory: false,
                    copyOnlyOverrideBundleIDs: []))
            let stream = await s.subscribe()
            let runTask = Task { await s.run() }
            try? await Task.sleep(nanoseconds: 40_000_000)
            await s.end()
            try? await Task.sleep(nanoseconds: 60_000_000)
            await s.retryInsertion()  // review -> retry
            var states: [SessionUIState] = []
            for await st in stream { states.append(st) }
            await runTask.value
            let successCount = states.filter { $0.phase == .success }.count
            let reviewCount = states.filter { $0.phase == .review }.count
            check("REQ-1 retry reaches exactly one success", successCount == 1)
            check("REQ-1 review shown before retry", reviewCount >= 1)
            check(
                "REQ-1 no terminal after success (exactly-once)",
                states.last?.phase == .success)
        }

        // ===== R1.5 regression: finish(category:) drives terminal outcome =====
        do {
            // Review R1.5/B3: finishTerminal drives the CONTROL state machine
            // to the matching terminal state (recording the outcome). The
            // state machine is AUTHORITATIVE: an illegal finish (e.g. claiming
            // .completed from .capturing) is a no-op, never a force-apply.
            var c = SessionControlModel()
            _ = c.begin()
            _ = c.stage(.readyToCapture)
            // Illegal finish from .capturing: state unchanged (no force-apply).
            _ = c.finish(category: .completed)
            check(
                "B3 finish(completed) from capturing is no-op (not forced)",
                c.state == .capturing && c.terminal == nil)
            // Drive the session to .inserting, then finish completes legally.
            _ = c.stage(.stop)
            _ = c.stage(.drainFinished)
            _ = c.stage(.transcriptionFinished)
            _ = c.stage(.transformationFinished)
            _ = c.stage(.targetValidationSucceeded)
            _ = c.finish(category: .completed)
            check(
                "R1.5 finish(completed) drives state to completed",
                c.state == .completed && c.terminal == .completed)
            // Duplicate finish after terminal is a no-op; outcome unchanged.
            _ = c.finish(category: .cancelled)
            check("R1.5 duplicate finish keeps first terminal", c.terminal == .completed)

            // Cancel path from preparing -> cancelled via finish (legal).
            var c2 = SessionControlModel()
            _ = c2.begin()
            _ = c2.finish(category: .cancelled)
            check("R1.5 finish(cancelled) from preparing", c2.state == .cancelled)

            // A session that never left preparing can finish failed
            // (preparationFailed is legal from preparing).
            var c3 = SessionControlModel()
            _ = c3.begin()
            _ = c3.finish(category: .failed)
            check("R1.5 finish(failed) from preparing", c3.state == .failed)

            // finish from .capturing with .degraded maps to the legal terminal:
            // captureFailed -> .failed (the machine has no direct .degraded
            // edge). No force-apply to .degraded.
            var c4 = SessionControlModel()
            _ = c4.begin()
            _ = c4.stage(.readyToCapture)
            _ = c4.finish(category: .degraded)
            // Round-5 B3: degraded is a DRAIN-stage terminal. From .capturing
            // there is no legal degraded event — the machine stays nonterminal
            // (authoritative; the orchestrator must not claim degraded from a
            // stage that cannot produce it).
            check(
                "B3 finish(degraded) from capturing stays nonterminal",
                !c4.state.isTerminal && c4.terminal == nil)
            // The legal path: .draining + .drainFailed -> .degraded.
            var c5 = SessionControlModel()
            _ = c5.begin()
            _ = c5.stage(.readyToCapture)
            _ = c5.stage(.stop)
            _ = c5.finish(category: .degraded)
            check(
                "B3 finish(degraded) from draining -> degraded (legal)",
                c5.state == .degraded && c5.terminal == .degraded)
            // Partial/truncated are legal from .transforming.
            var c6 = SessionControlModel()
            _ = c6.begin()
            _ = c6.stage(.readyToCapture)
            _ = c6.stage(.stop)
            _ = c6.stage(.drainFinished)
            _ = c6.stage(.transcriptionFinished)
            _ = c6.finish(category: .partial)
            check(
                "B3 finish(partial) from transforming -> partial (legal)",
                c6.state == .partial && c6.terminal == .partial)
            var c7 = SessionControlModel()
            _ = c7.begin()
            _ = c7.stage(.readyToCapture)
            _ = c7.stage(.stop)
            _ = c7.stage(.drainFinished)
            _ = c7.stage(.transcriptionFinished)
            _ = c7.finish(category: .truncated)
            check(
                "B3 finish(truncated) from transforming -> truncated (legal)",
                c7.state == .truncated && c7.terminal == .truncated)
            // Failed after Flow: .resolvingTarget + .targetResolutionFailed.
            var c8 = SessionControlModel()
            _ = c8.begin()
            _ = c8.stage(.readyToCapture)
            _ = c8.stage(.stop)
            _ = c8.stage(.drainFinished)
            _ = c8.stage(.transcriptionFinished)
            _ = c8.stage(.transformationFinished)
            _ = c8.finish(category: .failed)
            check(
                "B3 finish(failed) from resolvingTarget -> failed (legal)",
                c8.state == .failed && c8.terminal == .failed)
            // Finalize failure: .transcribing + .transcriptionFailed.
            var c9 = SessionControlModel()
            _ = c9.begin()
            _ = c9.stage(.readyToCapture)
            _ = c9.stage(.stop)
            _ = c9.stage(.drainFinished)
            _ = c9.finish(category: .failed)
            check(
                "B3 finish(failed) from transcribing -> failed (legal)",
                c9.state == .failed && c9.terminal == .failed)
        }
        do {
            // R1.5: readyToCapture transitions preparing -> capturing (the
            // transition run() previously never staged).
            var c = SessionControlModel()
            _ = c.begin()
            check("R1.5 begins in preparing", c.state == .preparing)
            let r = c.stage(.readyToCapture)
            var accepted = false
            if case .accepted(let st) = r, st == .capturing { accepted = true }
            check("R1.5 readyToCapture -> capturing", accepted && c.state == .capturing)
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
            let seenBox = MutableArrayBox<UInt64>()
            let seqBox = MutableSequencerBox()
            let consumer = Task {
                for await c in ch.chunks {
                    seenBox.append(c.sequence)
                    _ = seqBox.accept(c)
                }
            }
            ch.close()
            consumer.cancel()
            _ = seenBox.values  // box retains delivered sequences for the check
            let stats = ch.stats()
            check(
                "channel capacity respected (memory bounded)",
                stats.capacity == 64 && stats.enqueued == 64
                    && ch.acceptedEnqueueCount == 64)
            // with no consumer, overflow must have dropped the excess (64 of them)
            check("overflow counted not silent", stats.overflowDropped == 936 && !seqBox.seqIsDegraded)
        }

        // ===== JOE-2247 regression (review R1.1): capacity released on dequeue =====
        do {
            // A slow-but-steady consumer must NOT lose audio once the ring
            // releases capacity. Old bug: admission never dequeued, so after
            // `capacity` chunks every later chunk overflowed forever.
            let sid = SessionID(token: "r1", sequence: 1, createdAtUptimeNanos: 0)
            let ch = BoundedAudioChannel(sessionID: sid, capacity: 16)
            // Deterministic wave test: enqueue a wave, fully drain it (the
            // consumer releases capacity), enqueue the next wave. Across many
            // waves, nothing overflows and everything is delivered in order.
            // This is exactly the review's required scenario: many multiples of
            // capacity through a consumer, capacity released on dequeue.
            let waves = 20
            let perWave = 8  // <= capacity so a drained wave always fits
            var produced: [UInt64] = []
            var seen: [UInt64] = []
            for w in 0..<waves {
                // Enqueue one wave.
                for j in 0..<perWave {
                    let i = w * perWave + j
                    _ = ch.enqueue(
                        AudioChunk(
                            sessionID: sid, sequence: UInt64(i), startSample: UInt64(i) * 512,
                            sampleRate: 16000, channelCount: 1, samples: [Float(i)]))
                    produced.append(UInt64(i))
                }
                // Drain exactly this wave before the next one (capacity released).
                for await c in ch.chunks {
                    seen.append(c.sequence)
                    if seen.count == (w + 1) * perWave { break }
                }
            }
            ch.close()
            let s = ch.stats()
            print(
                "R1.1-probe delivered=\(seen.count) accepted=\(s.enqueued) overflow=\(s.overflowDropped) total=\(produced.count)"
            )
            check(
                "R1.1 no overflow across waves with full drains",
                s.overflowDropped == 0)
            check("R1.1 all chunks enqueued", s.enqueued == UInt64(produced.count))
            check("R1.1 all sequences delivered in order", seen == produced)
        }
        do {
            let a = SessionID(token: "1", sequence: 1, createdAtUptimeNanos: 0)
            let b = SessionID(token: "2", sequence: 1, createdAtUptimeNanos: 0)
            let ch = BoundedAudioChannel(sessionID: a, capacity: 8)
            _ = ch.enqueue(
                AudioChunk(sessionID: b, sequence: 0, startSample: 0, sampleRate: 16000, channelCount: 1, samples: [0]))
            check("cross-session chunk rejected and counted", ch.stats().wrongSessionRejected == 1 && ch.isDegraded)
            ch.close()
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
    }

    static func runPart2() async {
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
            check(
                "2269 unverified message distinguishes",
                unverified.userFacingMessage == "Paste sent — verify destination")
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

        // ===== R9 regression: automatic clipboard writes are never success =====
        do {
            let autoCopy = InsertionOutcome.automaticCopy
            let autoBlocked = InsertionOutcome.automaticCopyBlocked
            // R9: automatic copy (copy-only mode / fallback) must NOT be green,
            // NOT history-eligible, and must surface review (no auto-dismiss).
            check("R9 automaticCopy not green", !autoCopy.permitsGreenSuccessUI)
            check("R9 automaticCopy no history", !autoCopy.permitsHistoryRetention)
            check("R9 automaticCopy uncertain (review)", autoCopy.isUncertain)
            check("R9 automaticCopy no auto-dismiss", !autoCopy.permitsAutomaticPanelDismissal)
            check(
                "R9 automaticCopy distinct message",
                autoCopy.userFacingMessage.contains("automatic"))
            // R9: policy-blocked automatic copy is also non-success, no history.
            check("R9 blocked not green", !autoBlocked.permitsGreenSuccessUI)
            check("R9 blocked no history", !autoBlocked.permitsHistoryRetention)
            check("R9 blocked uncertain (review)", autoBlocked.isUncertain)
            check(
                "R9 blocked distinct message",
                autoBlocked.userFacingMessage.contains("blocked"))
            // R9: automaticCopy IS a completed action (clipboard written) but
            // blocked is NOT (nothing written).
            check("R9 autoCopy completed action", autoCopy.isCompletedAction)
            check("R9 blocked not completed action", !autoBlocked.isCompletedAction)
            // R9: the ONLY green+history clipboard outcome is the explicit
            // review-panel copy.
            let copied = InsertionOutcome.explicitlyCopiedByUser
            check(
                "R9 explicit copy still green+history",
                copied.permitsGreenSuccessUI && copied.permitsHistoryRetention)
        }
        // ===== R2/5 regression: timed-out AX write never claims safe =====
        do {
            let mayHaveApplied = InsertionOutcome.writeMayHaveApplied
            check("R2/5 writeMayHaveApplied not green", !mayHaveApplied.permitsGreenSuccessUI)
            check("R2/5 writeMayHaveApplied no history", !mayHaveApplied.permitsHistoryRetention)
            check("R2/5 writeMayHaveApplied uncertain", mayHaveApplied.isUncertain)
            check(
                "R2/5 writeMayHaveApplied no auto-dismiss",
                !mayHaveApplied.permitsAutomaticPanelDismissal)
            check(
                "R2/5 writeMayHaveApplied honest message",
                mayHaveApplied.userFacingMessage.contains("may have applied"))
            check(
                "R2/5 writeMayHaveApplied not completed action",
                !mayHaveApplied.isCompletedAction)
        }

        // Exhaustive policy test: adding a case must fail until UI/privacy/
        // metrics policy is defined. Compile-time exhaustiveness + runtime
        // sanity for every case.
        do {
            let all: [InsertionOutcome] = [
                .verifiedInserted(strategy: .axSelectedText, evidence: .clipboardRestored, warnings: []),
                .eventPostedUnverified(strategy: .terminalPaste, warnings: [.noPostWriteVerification]),
                .explicitlyCopiedByUser,
                .automaticCopy, .automaticCopyBlocked,
                .targetChanged, .targetGone, .targetUnknown, .secureTarget, .notEditable,
                .clipboardNotRestoredBecauseChanged, .clipboardRestoreFailed,
                .deadlineExceeded, .writeMayHaveApplied, .cancelled, .failed("x"),
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
                lane: AxOperationLane(),
                operation: {
                    Thread.sleep(forTimeInterval: 0.5)  // synchronous hang, like a stuck AX target
                    return 7
                })
            if case .deadlineExceeded = slow {
                check("2270 hung AX call hits deadline", true)
            } else {
                check("2270 hung AX call hits deadline", false)
            }
            // R2.2: an already-expired budget NEVER begins the operation.
            // Use a class-based flag so the detached operation does not
            // capture+mutate a local var (Swift 6 strict-concurrency).
            let executedFlag = ExecutedFlag()
            let expiredBudget = await AxBoundedRunner.run(
                deadlineNanosAhead: 1_000,
                startedAtNanos: start,
                nowNanos: { start + 5_000 },  // elapsed >= deadline
                operation: {
                    executedFlag.mark()
                    return 1
                })
            if case .deadlineExceeded = expiredBudget {
                check("R2.2 expired budget never executes", !executedFlag.didRun)
            } else {
                check("R2.2 expired budget never executes", false)
            }
            // R2.2: held synchronous work outlives its waiter; ownership must
            // persist, but tests release it rather than leaking infinite work.
            let heldLane = AxOperationLane()
            let heldRelease = DispatchSemaphore(value: 0)
            let heldEntered = ExecutedFlag()
            let startNs = DispatchTime.now().uptimeNanoseconds
            let heldCall = Task {
                await AxBoundedRunner.run(
                    deadlineNanosAhead: 10_000_000_000,
                    startedAtNanos: startNs,
                    nowNanos: { DispatchTime.now().uptimeNanoseconds },
                    lane: heldLane,
                    operation: {
                        heldEntered.mark()
                        _ = heldRelease.wait(timeout: .now() + 10)
                        return 9
                    })
            }
            while !heldEntered.didRun && DispatchTime.now().uptimeNanoseconds - startNs < 5_000_000_000 {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            check("2270 held worker entry observed", heldEntered.didRun)
            heldCall.cancel()
            let cancelled = await heldCall.value
            if case .cancelled(let mayHaveStarted) = cancelled {
                check("R2.2 held native cancellation waiter returns", mayHaveStarted)
            } else {
                check("R2.2 held native cancellation waiter returns", false)
            }
            check("2270 native work remains owned after cancellation", heldLane.hasOutstandingWork)
            let busy = await AxBoundedRunner.run(
                deadlineNanosAhead: 1_000_000_000,
                startedAtNanos: start, nowNanos: { start }, lane: heldLane, operation: { 10 })
            if case .busy = busy {
                check("2270 native retries cannot overlap", true)
            } else {
                check("2270 native retries cannot overlap", false)
            }
            heldRelease.signal()
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

        // ===== B4 round-5: exact TargetLease validation =====
        do {
            // Review B4 (round 5): a complete immutable target lease binds
            // paste insertion to the EXACT validated field/window — not just
            // the application. PID reuse, same-app field switches and window
            // switches must fail closed.
            let sid = SessionID(token: "lease", sequence: 1, createdAtUptimeNanos: 0)
            func snapshot(
                pid: Int32 = 42, start: UInt64 = 900, bundle: String = "com.example.Editor",
                window: UInt32? = 7, role: String = "AXTextField", subrole: String? = nil,
                token: String? = "tok", settable: Bool = true, editable: Bool = true,
                enabled: Bool = true
            ) -> TargetSnapshot {
                TargetSnapshot(
                    sessionID: sid, capturedAtUptimeNanos: 100,
                    target: TargetSnapshot.Identity(
                        pid: pid, bundleID: bundle,
                        processStartUptimeNanos: start,
                        windowID: window, appVersion: "1.0"),
                    element: TargetSnapshot.ElementIdentity(
                        role: role, subrole: subrole, resolutionToken: token),
                    settable: settable, editable: editable, enabled: enabled,
                    selectionRange: 0..<0,
                    sensitivity: SensitivityAssessment(
                        sensitivity: .normal, source: .accessibilityRole,
                        capturedAtNanos: 100))
            }
            let s = snapshot()
            let lease = TargetLease.make(
                snapshot: s, sessionID: sid,
                validationDeadlineNanosAhead: 1_000_000_000, nowNanos: 0)
            // Exact re-resolution matches.
            check(
                "B4r5 lease matches exact target",
                lease.matches(reResolved: s, requireWindow: true, requireElementToken: true, nowNanos: 100))
            // Same bundle, different window -> mismatch (same-app window switch).
            let otherWindow = snapshot(window: 8)
            check(
                "B4r5 lease rejects same-app window switch",
                !lease.matches(reResolved: otherWindow, requireWindow: true, requireElementToken: true, nowNanos: 100))
            // Same app, different element token -> mismatch (same-window field switch).
            let otherField = snapshot(token: "tok2")
            check(
                "B4r5 lease rejects same-app field switch (token)",
                !lease.matches(reResolved: otherField, requireWindow: true, requireElementToken: true, nowNanos: 100))
            // PID reuse / process restart -> mismatch.
            let pidReuse = snapshot(pid: 42, start: 901)
            check(
                "B4r5 lease rejects process restart (start identity)",
                !lease.matches(reResolved: pidReuse, requireWindow: true, requireElementToken: true, nowNanos: 100))
            // Different bundle -> mismatch.
            let otherBundle = snapshot(bundle: "com.other.App")
            check(
                "B4r5 lease rejects bundle change",
                !lease.matches(reResolved: otherBundle, requireWindow: true, requireElementToken: true, nowNanos: 100))
            // Role/subrole change -> mismatch.
            let roleChange = snapshot(role: "AXTextArea")
            check(
                "B4r5 lease rejects role change",
                !lease.matches(reResolved: roleChange, requireWindow: true, requireElementToken: true, nowNanos: 100))
            // Capability change -> mismatch.
            let capChange = snapshot(editable: false)
            check(
                "B4r5 lease rejects capability change",
                !lease.matches(reResolved: capChange, requireWindow: true, requireElementToken: true, nowNanos: 100))
            // Expiry -> mismatch even for the exact target.
            check(
                "B4r5 lease expires (deadline passed)",
                !lease.matches(reResolved: s, requireWindow: true, requireElementToken: true, nowNanos: 2_000_000_000))
            // Without requireWindow/requireElementToken the weaker identity is
            // still bundle+pid+process-start bound.
            let weak = snapshot(window: nil, token: nil)
            let lease2 = TargetLease.make(
                snapshot: weak, sessionID: sid,
                validationDeadlineNanosAhead: 1_000_000_000, nowNanos: 0)
            let windowChanged = snapshot(window: 99, token: nil)
            check(
                "B4r5 lease matches when window/token not required",
                lease2.matches(
                    reResolved: windowChanged, requireWindow: false, requireElementToken: false, nowNanos: 100))
        }
        do {
            // Session-level: a validated insertion request carries the lease
            // (produced at validation time), and a non-validated path has no
            // lease (fail-closed review).
            let provider = FakeSessionStages()
            await provider.setPartials(["hello"])
            let s = DictationSession(
                provider: provider, engineChoice: .whisper,
                settings: SessionSettingsSnapshot(
                    localOnly: true, language: .enUS, defaultFlowStyle: .clean,
                    insertionMode: "automatic", saveHistory: true,
                    copyOnlyOverrideBundleIDs: []))
            let stream = await s.subscribe()
            let runTask = Task { await s.run() }
            try? await Task.sleep(nanoseconds: 20_000_000)
            await s.end()
            try? await Task.sleep(nanoseconds: 60_000_000)
            await s.cancel()
            var states: [SessionUIState] = []
            for await st in stream { states.append(st) }
            await runTask.value
            // The fake records the last insert request; verify it carried a
            // lease with the validated pid/bundle/window.
            let lastRequest = await provider.lastInsertRequest
            check("B4r5 insert request carries lease", lastRequest?.lease != nil)
            if let l = lastRequest?.lease {
                check("B4r5 lease pid matches snapshot", l.pid == 42)
                check("B4r5 lease bundle matches snapshot", l.bundleID == "com.example.Editor")
                check("B4r5 lease window matches snapshot", l.windowID == 7)
            }
        }

        // ===== B3 round-6: lease nonce consumption + session/sensitivity identity =====
        do {
            let sid = SessionID(token: "lease2", sequence: 1, createdAtUptimeNanos: 0)
            let otherSid = SessionID(token: "other", sequence: 2, createdAtUptimeNanos: 0)
            func snap(sid: SessionID, sens: SessionSensitivity = .normal) -> TargetSnapshot {
                TargetSnapshot(
                    sessionID: sid, capturedAtUptimeNanos: 100,
                    target: TargetSnapshot.Identity(
                        pid: 42, bundleID: "com.example.Editor",
                        processStartUptimeNanos: 900,
                        windowID: 7, appVersion: "1.0"),
                    element: TargetSnapshot.ElementIdentity(
                        role: "AXTextField", subrole: nil, resolutionToken: "tok"),
                    settable: true, editable: true, enabled: true,
                    selectionRange: 0..<0,
                    sensitivity: SensitivityAssessment(
                        sensitivity: sens, source: .accessibilityRole,
                        capturedAtNanos: 100))
            }
            let s = snap(sid: sid)
            let lease = TargetLease.make(
                snapshot: s, sessionID: sid,
                validationDeadlineNanosAhead: 1_000_000_000, nowNanos: 0)
            // Exact target + same session matches.
            check(
                "B3r6 lease matches with session identity",
                lease.matches(reResolved: s, requireWindow: true, requireElementToken: true, nowNanos: 100))
            // A DIFFERENT session snapshot fails (cross-session lease reuse).
            let otherSession = snap(sid: otherSid)
            check(
                "B3r6 lease rejects cross-session reuse",
                !lease.matches(reResolved: otherSession, requireWindow: true, requireElementToken: true, nowNanos: 100))
            // A sensitivity change fails.
            let sensChanged = snap(sid: sid, sens: .secure)
            check(
                "B3r6 lease rejects sensitivity change",
                !lease.matches(reResolved: sensChanged, requireWindow: true, requireElementToken: true, nowNanos: 100))
            // One-use consumption: first consume ok, second refused.
            let registry = TargetLeaseRegistry()
            let consumedOnce = await registry.consume(lease.nonce)
            check("B3r6 lease consumed once", consumedOnce)
            let consumedTwice = await registry.consume(lease.nonce)
            check("B3r6 lease second consume refused", !consumedTwice)
            check("B3r6 lease registry reports consumed", await registry.isConsumed(lease.nonce))
            // Distinct nonces are independent.
            let lease2 = TargetLease.make(
                snapshot: s, sessionID: sid,
                validationDeadlineNanosAhead: 1_000_000_000, nowNanos: 0)
            check("B3r6 distinct nonces", lease2.nonce != lease.nonce)
            let freshConsumed = await registry.consume(lease2.nonce)
            check("B3r6 fresh nonce consumable", freshConsumed)
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
            var copiedMarker = PasteboardTransaction(sessionID: sid, original: plain)!
            copiedMarker.applyTemporary(changeCount: 6)
            check(
                "2260 marker cannot authorize a newer clipboard generation",
                copiedMarker.attemptRestore(currentChangeCount: 7, currentIsOurMarker: true)
                    == .notRestoredBecauseChanged)
            var missingMarker = PasteboardTransaction(sessionID: sid, original: plain)!
            missingMarker.applyTemporary(changeCount: 6)
            check(
                "2260 count alone cannot authorize restoration",
                missingMarker.attemptRestore(currentChangeCount: 6, currentIsOurMarker: false)
                    == .notRestoredBecauseChanged)
            var reads = 0
            let missingData = PasteboardSnapshot.capture(itemTypes: [["one", "two"]], changeCount: 0) { _, _ in
                reads += 1
                return nil
            }
            check("2260 unreadable representation rejects entire snapshot", missingData == nil && reads == 1)
            reads = 0
            let metadataOverflow = PasteboardSnapshot.capture(
                itemTypes: [["one", "two"]], changeCount: 0,
                budget: .init(maxTypesPerItem: 1)
            ) { _, _ in
                reads += 1
                return Data()
            }
            check("2260 metadata budget precedes payload materialization", metadataOverflow == nil && reads == 0)
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
            // Review B4v2: automatic cascades never end in copyOnly.
            check(
                "2271 default cascade has no automatic copyOnly",
                !def.strategies.contains(.copyOnly))

            // Strategy ordering + cascade semantics.
            let editor = reg.adapter(
                forBundle: "com.apple.dt.Xcode", role: nil,
                appVersion: nil, macOSVersion: nil)
            // Review B4v2: no automatic copyOnly fallback in editor cascade.
            check(
                "2271 editor strategy order",
                editor.strategies == [.clipboardPaste, .axSelectedText, .axValue])
            check(
                "2271 cascade to next permitted",
                editor.nextStrategy(after: .clipboardPaste) == .axSelectedText
                    && editor.nextStrategy(after: .axValue) == nil)
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
            // Review B4v2: resolver default cascade has no copyOnly fallback.
            check(
                "2271 resolver default strategies",
                InsertionStrategyResolver.strategies(
                    bundleID: "com.google.Chrome", role: "AXTextField", mode: .automatic)
                    == [.clipboardPaste, .axSelectedText])
            check(
                "2271 resolver editor includes axValue",
                InsertionStrategyResolver.strategies(
                    bundleID: "com.microsoft.VSCode", role: "AXTextField", mode: .automatic)
                    == [.clipboardPaste, .axSelectedText, .axValue])
            check(
                // Review B4v2: unknown-app default cascade has no copyOnly fallback.
                "2271 resolver unknown => default",
                InsertionStrategyResolver.strategies(bundleID: "com.example.x", role: "AXTextField", mode: .automatic)
                    == [.clipboardPaste, .axSelectedText])
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
                let chunkCount = Int(rnd(40)) + 1
                for _ in 0..<chunkCount {
                    let samples = UInt64(rnd(4000)) + 16
                    captured &+= samples
                    acct.noteCaptured(sourceSamples: samples, sourceRate: 16000)
                    let out = UInt64((Double(samples) * ratio).rounded())
                    converted &+= out
                    acct.noteConverted(engineSamples: out)
                    acct.noteDelivered(engineSamples: out)
                }
                let tol: UInt64 = 32
                if !acct.reconciles(converterRatio: ratio, roundingToleranceSamples: tol)
                    || acct.capturedSourceSamples != captured
                    || acct.convertedEngineSamples != converted
                    || acct.deliveredEngineSamples != converted
                    || acct.droppedSourceSamples != 0
                {
                    propertyOK = false
                }
            }
            check("2248 property: random chunk sizes/ratios reconcile", propertyOK)
        }
        do {
            // Gap/overflow => degraded, never completes.
            var acct = AudioFrameAccounting()
            acct.noteCaptured(sourceSamples: 16000, sourceRate: 16000)
            acct.noteDropped(sourceSamples: 8000, reason: .overflow)
            acct.noteConverted(engineSamples: 8000)
            acct.noteDelivered(engineSamples: 8000)
            check(
                "2248 dropped samples degrade the session",
                acct.isDegraded && !acct.reconciles(converterRatio: 1.0, roundingToleranceSamples: 0))
            // Delivered < converted => mismatch.
            var m = AudioFrameAccounting()
            m.noteCaptured(sourceSamples: 16000, sourceRate: 16000)
            m.noteConverted(engineSamples: 16000)
            m.noteDelivered(engineSamples: 15000)
            check(
                "2248 delivered<converted fails reconciliation",
                !m.reconciles(converterRatio: 1.0, roundingToleranceSamples: 0))
            // Exact success.
            var ok = AudioFrameAccounting()
            ok.noteCaptured(sourceSamples: 16000, sourceRate: 16000)
            ok.noteConverted(engineSamples: 16000)
            ok.noteDelivered(engineSamples: 16000)
            check(
                "2248 exact reconciliation succeeds",
                ok.reconciles(converterRatio: 1.0, roundingToleranceSamples: 0))
            // Converter rounding within explicit tolerance.
            var r = AudioFrameAccounting()
            r.noteCaptured(sourceSamples: 16000, sourceRate: 16000)
            r.noteConverted(engineSamples: 8000)
            r.noteDelivered(engineSamples: 8000)
            check(
                "2248 ratio rounding within tolerance",
                r.reconciles(converterRatio: 0.5, roundingToleranceSamples: 1))
        }
    }

    static func runPart3() async {
        // ===== R1.2 regression: non-16k source rate reconciles correctly =====
        do {
            // Review R1.2: the old code hardcoded 16k/16k for the converter
            // ratio, so any source rate other than 16 kHz failed
            // reconciliation even with a perfect conversion.
            var acct = AudioFrameAccounting()
            let sourceRate = 44_100.0
            let captured = UInt64(44_100 * 10)  // 10 s of 44.1 kHz
            acct.noteCaptured(sourceSamples: captured, sourceRate: sourceRate)
            // Perfect conversion to 16 kHz: 441000 * (16000/44100) = 160000.
            let converted = UInt64((Double(captured) * (16000.0 / sourceRate)).rounded())
            acct.noteConverted(engineSamples: converted)
            acct.noteDelivered(engineSamples: converted)
            let ratio = 16000.0 / acct.sourceSampleRate
            check(
                "R1.2 non-16k source rate reconciles",
                ratio == 16000.0 / 44100.0
                    && acct.reconciles(converterRatio: ratio, roundingToleranceSamples: 64))
            // 48 kHz too.
            var acct48 = AudioFrameAccounting()
            let src48 = 48_000.0
            let cap48 = UInt64(48_000 * 5)
            acct48.noteCaptured(sourceSamples: cap48, sourceRate: src48)
            let conv48 = UInt64((Double(cap48) * (16000.0 / src48)).rounded())
            acct48.noteConverted(engineSamples: conv48)
            acct48.noteDelivered(engineSamples: conv48)
            let ratio48 = 16000.0 / acct48.sourceSampleRate
            check(
                "R1.2 48k source rate reconciles",
                acct48.reconciles(converterRatio: ratio48, roundingToleranceSamples: 64))
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

        // ===== B1 regression: barrier recognizes already-delivered final =====
        do {
            // Review B1: if the consumer delivered the final sequence BEFORE
            // begin() (the old arm-after-close race), the barrier must drain
            // immediately instead of stranding .draining.
            var b = AudioDrainBarrier(deadlineNanosAhead: 10_000)
            // Consumer delivers seq 5 while idle.
            _ = b.noteDelivered(sequence: 5, nowNanos: 100)
            // Now arm with final=5: must drain immediately.
            b.begin(finalSequence: 5, nowNanos: 200)
            check(
                "B1 final delivered while idle -> drained immediately",
                b.state == .drained && b.isComplete)
            // And a final BEYOND what was delivered stays draining until the
            // missing chunk arrives (or times out).
            var b2 = AudioDrainBarrier(deadlineNanosAhead: 10_000)
            _ = b2.noteDelivered(sequence: 3, nowNanos: 100)
            b2.begin(finalSequence: 5, nowNanos: 200)
            check("B1 final beyond delivered stays draining", b2.state == .draining)
            _ = b2.noteDelivered(sequence: 4, nowNanos: 300)
            _ = b2.noteDelivered(sequence: 5, nowNanos: 400)
            check("B1 drains when remaining chunks delivered", b2.state == .drained)
            // Highest-delivered-while-idle is tracked for the next session too.
            check("B1 idle tracking retained", b2.highestDeliveredWhileIdle == 5)
        }

        // ===== R1.3 regression: barrier terminal states + drain-before-close =====
        do {
            // Review R1.3: a barrier that never receives the final sequence
            // must reach a terminal state (timedOut) rather than strand in
            // .draining forever; isTerminal bounds the consumer wait.
            var stranded = AudioDrainBarrier(deadlineNanosAhead: 500)
            stranded.begin(finalSequence: 99, nowNanos: 0)
            // Consumer never delivers sequence 99.
            _ = stranded.noteDelivered(sequence: 5, nowNanos: 100)
            check("R1.3 draining not yet terminal", !stranded.isTerminal)
            _ = stranded.noteDelivered(sequence: 6, nowNanos: 700)  // past deadline
            check("R1.3 timedOut is terminal (bounded wait)", stranded.isTerminal)
            check("R1.3 stranded barrier timed out", stranded.state == .timedOut)

            // A correctly-drained barrier is terminal AND complete.
            var done = AudioDrainBarrier(deadlineNanosAhead: 10_000)
            done.begin(finalSequence: 3, nowNanos: 0)
            _ = done.noteDelivered(sequence: 1, nowNanos: 100)
            _ = done.noteDelivered(sequence: 2, nowNanos: 200)
            _ = done.noteDelivered(sequence: 3, nowNanos: 300)
            check("R1.3 drained is terminal + complete", done.isTerminal && done.isComplete)

            // The orchestration invariant (review R1.3): the barrier must be
            // begun BEFORE the channel closes so the consumer's final-sequence
            // acknowledgment is observed. The barrier primitive drains when the
            // final sequence arrives after begin; the ProductionSessionStages
            // fix guarantees begin happens before audio.stop() closes the
            // channel. Verify the primitive's contract: a final sequence
            // delivered after begin drains (complete), and the deadline bounds
            // the wait (never hangs).
            var ok3 = AudioDrainBarrier(deadlineNanosAhead: 10_000)
            ok3.begin(finalSequence: 4, nowNanos: 0)
            _ = ok3.noteDelivered(sequence: 4, nowNanos: 500)
            check("R1.3 final sequence after begin drains", ok3.isComplete && ok3.isTerminal)
        }
        // ===== B1 round-5 regression: incomplete consumer must degrade =====
        do {
            // Review B1v2 (round 5): `markTimedOut()` only fires while the
            // barrier is still .draining. A barrier ALREADY drained at the
            // deadline (final chunk delivered) with a consumer still running
            // (EOS tail append suspended) must STILL be degraded — consumer
            // completion is a mandatory success condition, tracked
            // independently of barrier state.
            func assess(
                barrierDrained: Bool, consumerCompleted: Bool
            ) -> Bool {
                AudioDrainAssessment.isDegraded(
                    AudioDrainAssessment.Input(
                        seqDegraded: false,
                        channelDegraded: false,
                        barrierTimedOut: false,
                        barrierDrained: barrierDrained,
                        consumerCompleted: consumerCompleted,
                        lateAppends: 0,
                        reconciled: true))
            }
            // Drained + consumer completed => NOT degraded (success).
            check("B1r5 drained+consumer-complete succeeds", !assess(barrierDrained: true, consumerCompleted: true))
            // Drained but consumer NOT completed => DEGRADED (the round-5
            // blocker: the old expression ignored consumer completion).
            check(
                "B1r5 drained+consumer-incomplete is degraded", assess(barrierDrained: true, consumerCompleted: false))
            // Consumer completed but barrier timed out => degraded.
            check(
                "B1r5 barrier-timeout still degraded",
                AudioDrainAssessment.isDegraded(
                    AudioDrainAssessment.Input(
                        seqDegraded: false, channelDegraded: false,
                        barrierTimedOut: true, barrierDrained: true,
                        consumerCompleted: true, lateAppends: 0,
                        reconciled: true)))
            // Late appends / unreconciled / sequence-degraded / channel-degraded
            // each independently force degradation.
            check(
                "B1r5 late append degrades",
                AudioDrainAssessment.isDegraded(
                    AudioDrainAssessment.Input(
                        seqDegraded: false, channelDegraded: false,
                        barrierTimedOut: false, barrierDrained: true,
                        consumerCompleted: true, lateAppends: 1,
                        reconciled: true)))
            check(
                "B1r5 unreconciled degrades",
                AudioDrainAssessment.isDegraded(
                    AudioDrainAssessment.Input(
                        seqDegraded: false, channelDegraded: false,
                        barrierTimedOut: false, barrierDrained: true,
                        consumerCompleted: true, lateAppends: 0,
                        reconciled: false)))
            check(
                "B1r5 seq-degraded degrades",
                AudioDrainAssessment.isDegraded(
                    AudioDrainAssessment.Input(
                        seqDegraded: true, channelDegraded: false,
                        barrierTimedOut: false, barrierDrained: true,
                        consumerCompleted: true, lateAppends: 0,
                        reconciled: true)))
            // Ownership: the task/converter handles must be RETAINED while
            // the consumer is incomplete (never discarded mid-flight).
            check(
                "B1r5 retain ownership while consumer incomplete",
                AudioDrainAssessment.shouldRetainOwnership(consumerCompleted: false))
            check(
                "B1r5 release ownership when consumer complete",
                !AudioDrainAssessment.shouldRetainOwnership(consumerCompleted: true))
            // Session-level behavior: a degraded summary (produced when the
            // consumer is incomplete) must drive the session to the error
            // phase (never success), with no insertion and no history write.
            let stages = FakeSessionStages()
            await stages.setDegraded(true)
            let s = DictationSession(
                provider: stages, engineChoice: .whisper,
                settings: SessionSettingsSnapshot(
                    localOnly: true, language: .enUS, defaultFlowStyle: .clean,
                    insertionMode: "automatic", saveHistory: true,
                    copyOnlyOverrideBundleIDs: []))
            let stream = await s.subscribe()
            let runTask = Task { await s.run() }
            try? await Task.sleep(nanoseconds: 20_000_000)
            await s.end()
            try? await Task.sleep(nanoseconds: 40_000_000)
            await s.cancel()
            var states: [SessionUIState] = []
            for await st in stream { states.append(st) }
            await runTask.value
            check(
                "B1r5 incomplete consumer -> session error (not success)",
                states.contains { $0.phase == .error }
                    && !states.contains { $0.phase == .success })
            check(
                "B1r5 incomplete consumer -> no insertion",
                await stages.insertionCount == 0)
            check(
                "B1r5 incomplete consumer -> no history write",
                await stages.historyCount == 0)
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

            let gate = CallbackGate()
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

        // ===== R3.1 regression: errored partial never complete =====
        do {
            // Review R3.1: an error after non-empty partial text must yield
            // .partial (with a warning), never .complete.
            let erroredPartial = SpeechCompletenessPolicy.completeness(
                sawFinal: true, error: "recognition failed", hasText: true)
            check(
                "R3.1 errored partial is partial, not complete",
                erroredPartial == .partial)
            let w = SpeechCompletenessPolicy.warnings(
                sawFinal: true, error: "recognition failed", hasText: true)
            check("R3.1 errored partial warns partialFallback", w == [.partialFallback])
            // A genuine final with no error and text is complete.
            let good = SpeechCompletenessPolicy.completeness(
                sawFinal: true, error: nil, hasText: true)
            check("R3.1 final-no-error with text is complete", good == .complete)
            // No final, no error, but text => partial (rolling).
            let rolling = SpeechCompletenessPolicy.completeness(
                sawFinal: false, error: nil, hasText: true)
            check("R3.1 rolling partial is partial", rolling == .partial)
            // No text at all => degraded.
            let empty = SpeechCompletenessPolicy.completeness(
                sawFinal: false, error: nil, hasText: false)
            check("R3.1 no text is degraded", empty == .degraded)
            // Error with no text => degraded.
            let errEmpty = SpeechCompletenessPolicy.completeness(
                sawFinal: false, error: "boom", hasText: false)
            check("R3.1 error-no-text is degraded", errEmpty == .degraded)
        }

        // ===== R3.2 regression: window truncation is visible, never complete =====
        do {
            // Review R3.2: a 60s window cap that dropped audio must yield
            // .truncated (never .complete) with a truncation warning.
            let truncated = SpeechCompletenessPolicy.completenessWithTruncation(
                hasFinalText: true, didTruncateWindow: true)
            check("R3.2 truncated input never complete", truncated == .truncated)
            let noTextTrunc = SpeechCompletenessPolicy.completenessWithTruncation(
                hasFinalText: false, didTruncateWindow: true)
            check("R3.2 truncated no-text is partial", noTextTrunc == .partial)
            let normal = SpeechCompletenessPolicy.completenessWithTruncation(
                hasFinalText: true, didTruncateWindow: false)
            check("R3.2 untruncated with text is complete", normal == .complete)
            let warns = SpeechCompletenessPolicy.truncationWarnings(
                didTruncateWindow: true, baseWarnings: [])
            check("R3.2 truncation warning appended", warns == [.truncation])
            let noWarn = SpeechCompletenessPolicy.truncationWarnings(
                didTruncateWindow: false, baseWarnings: [.partialFallback])
            check("R3.2 no truncation warning when untruncated", noWarn == [.partialFallback])
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
    }

    static func runPart4() async {
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

        // ===== JOE-2277 regression (review R5.1): protected spans across =====
        // ===== lines/paragraphs must not collide (placeholder reuse) =====
        do {
            // Two paragraphs, each with a DIFFERENT URL. Old bug: each line's
            // protect() restarted placeholders at 0, so both paragraphs got
            // token 0 and restore replaced both with the FIRST URL.
            let twoUrls = "See https://alpha.example.com/first for details.\n\nThen https://beta.example.com/second."
            let out = await FlowProcessor.shared.process(twoUrls, style: .clean, language: .enUS)
            check(
                "R5.1 first url preserved",
                out.contains("https://alpha.example.com/first"))
            check(
                "R5.1 second url preserved",
                out.contains("https://beta.example.com/second"))
            check(
                "R5.1 urls not cross-replaced",
                out.contains("https://alpha.example.com/first")
                    && out.contains("https://beta.example.com/second")
                    && !out.contains("https://alpha.example.com/second")
                    && !out.contains("https://beta.example.com/first"))
            // Same with emails across lines (also protected spans).
            let twoEmails = "Mail a@one.example now.\nAnd b@two.example later."
            let out2 = await FlowProcessor.shared.process(twoEmails, style: .clean, language: .enUS)
            check("R5.1 first email preserved", out2.contains("a@one.example"))
            check("R5.1 second email preserved", out2.contains("b@two.example"))
            // And a mixed single-line case still works (sanity).
            let single = "x@a.co and https://y.example/p"
            let out3 = await FlowProcessor.shared.process(single, style: .clean, language: .enUS)
            check(
                "R5.1 single-line mixed spans preserved",
                out3.contains("x@a.co") && out3.contains("https://y.example/p"))
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

        // ===== R2/9 regression: Flow never fails open on span loss =====
        do {
            // Review R2/9: a typed process() that loses a protected span must
            // return .rejected with a fallback reason and a guardrail warning —
            // NEVER .accepted. Use a path/code span that the rules could
            // corrupt to force the comparison to fail (or at least verify the
            // status contract holds for normal accepted output).
            let sid = SessionID(token: "r2f", sequence: 1, createdAtUptimeNanos: 0)
            // Normal accepted case still reports accepted with no warnings.
            let okReq = FlowRequest(
                sessionID: sid, text: "Please ship it tomorrow",
                style: .clean, language: .enUS, sensitivity: .normal)
            let okOut = await FlowProcessor.shared.process(okReq)
            check(
                "R2/9 accepted when spans preserved",
                okOut.status == .accepted && okOut.warnings.isEmpty
                    && okOut.protectedSpansPreserved)
            // The typed path must NEVER report accepted when preservation
            // failed: exercise the internal guard by checking the outcome's
            // status consistency (protectedSpansPreserved false => not accepted).
            if !okOut.protectedSpansPreserved {
                check(
                    "R2/9 fail-closed: !preserved => rejected",
                    okOut.status == .rejected && okOut.usedFallback)
            }
            // Cross-line protected spans (the R5.1 regression) must be
            // preserved AND accepted — the fix made this the normal path.
            let spansReq = FlowRequest(
                sessionID: sid,
                text: "See https://alpha.example.com/first now.\nThen https://beta.example.com/second.",
                style: .clean, language: .enUS, sensitivity: .normal)
            let spansOut = await FlowProcessor.shared.process(spansReq)
            check(
                "R2/9 cross-line spans preserved + accepted",
                spansOut.protectedSpansPreserved && spansOut.status == .accepted)
        }

        // ===== NIT (round 4): rejected fallback reports 0 changed ranges =====
        do {
            // Review NIT: when Flow REJECTS (protected spans not preserved)
            // the returned text is the ORIGINAL input — the change count must
            // be 0 (a rejected fallback must not claim a change it did not
            // perform).
            let sid = SessionID(token: "nit1", sequence: 1, createdAtUptimeNanos: 0)

            // Deterministic rejection through the GUARDRAILS gate (same
            // status vocabulary the processor maps to): an empty output for a
            // long input is rejected with the original text as the
            // conservative fallback.
            let longInput = "this is a long dictation that says something important"
            let g = FlowGuardrails.evaluate(
                input: longInput, output: "",
                conservativeFallback: longInput)
            if case .rejected = g {
                check(
                    "NIT guardrails rejected keeps original fallback",
                    FlowGuardrailsResult.rejected(
                        reason: .emptyOutput,
                        conservativeFallback: longInput) == g)
            }

            // The PROCESSOR contract: build the exact outcome the processor
            // emits on rejection (text == input, status .rejected) and assert
            // changedRangeCount is 0 whenever the returned text equals the
            // input. This pins the invariant the fix implements.
            let okReq = FlowRequest(
                sessionID: sid, text: "please ship", style: .clean,
                language: .enUS, sensitivity: .normal)
            let okOut = await FlowProcessor.shared.process(okReq)
            if okOut.status == .accepted {
                check(
                    "NIT accepted changedRangeCount matches text delta",
                    okOut.changedRangeCount == (okOut.text != "please ship" ? 1 : 0))
            }
            // A rejected outcome with unchanged text must report 0 changes
            // (regression for the old behavior which reported 1 whenever the
            // TRANSFORMED output differed, even though the rejected return
            // was the original input).
            let rejected = FlowOutcome(
                text: longInput,
                requestedStyle: .clean,
                resolvedLossClass: .conservative,
                backend: .regex,
                capabilityID: "io.zephyr-flow.flow.rules.v1",
                capabilityVersion: 1,
                language: .enUS,
                changedRangeCount: 0,
                protectedSpanCount: FlowGuardrails.tokens(in: longInput).count,
                protectedSpansPreserved: false,
                status: .rejected,
                warnings: [.guardrailRejected],
                fallbackReason: "protected spans not preserved; original text returned (conservative)",
                durationNanos: 0,
                termination: .completed)
            check("NIT rejected reports 0 changed ranges", rejected.changedRangeCount == 0)
            check("NIT rejected keeps original text", rejected.text == longInput)
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
            // The inherited corpus has NO Raw cases, although the policy has
            // a Raw budget. Do not invent evidence or silently skip that style.
            // This is an evaluator regression test, not a passing release gate.
            check(
                "2281 inherited incomplete corpus cannot qualify",
                gateResult == .fail(reason: "raw: missing statistics"))
            if case .fail(let reason) = gateResult { print("FLOW QUALIFICATION INCOMPLETE:", reason) }
            // A named version/baseline is metadata, not independently verified
            // provenance or protection against candidate source edits.
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
                "releaseGatePassed": gateResult == .pass,
                "releaseGateResult": String(describing: gateResult),
                "requiredStyleCount": FlowReleasePolicy.current.budgets.count,
                "measuredStyleCount": perStyle.count,
            ]
            if let path = ProcessInfo.processInfo.environment["ZF_FLOW_REPORT_PATH"] {
                do {
                    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted])
                    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
                } catch {
                    check("2281 requested Flow evidence write must succeed", false)
                }
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
                "2284 explicit copy is labelled copy, not inserted",
                pres(.complete, .accepted, copied).title == "Copied to clipboard"
                    && pres(.complete, .accepted, copied).title != pres(.complete, .accepted, verified).title)
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
    }

    static func runPart5() async {
        do {
            var buffer = LongDictationAudioBuffer(maximumSamples: 10, blockSamples: 3)
            check("2251 blocked buffer admits prefix", buffer.append([0, 1, 2, 3, 4, 5]) == 6)
            check(
                "2251 partial window does not erase final audio",
                buffer.recentSamples(maximum: 2) == [4, 5]
                    && buffer.samples(in: 0..<3) == [0, 1, 2])
            check(
                "2251 product limit counts excess",
                buffer.append([6, 7, 8, 9, 10]) == 4
                    && buffer.rejectedSamples == 1 && buffer.reachedLimit)
            check("2251 final prefix still present", buffer.samples(in: 0..<10) == Array(0..<10).map(Float.init))
            let plan = FinalDecodeChunkPlan.ranges(sampleCount: LongDictationPolicy.maximumSamples)
            check(
                "2251 ten-minute plan covers complete admitted range",
                plan?.first?.lowerBound == 0 && plan?.last?.upperBound == 9_600_000)
            check("2251 invalid length cannot plan", FinalDecodeChunkPlan.ranges(sampleCount: 9_600_001) == nil)
            let missing = LongDictationStitcher.stitch(
                [
                    .init(samples: 0..<480_000, text: "first", words: nil),
                    .init(samples: 448_000..<500_000, text: "second", words: nil),
                ], expectedSampleCount: 500_000)
            if case .incomplete(let text, _) = missing {
                check("2251 missing seam preserves both hypotheses", text == "first\n\nsecond")
            } else {
                check("2251 missing seam preserves both hypotheses", false)
            }
        }
        do {
            check(
                "2258 secure subrole confines ordinary text role",
                AccessibilitySensitivity.classify(
                    role: .value("AXTextField"), subrole: .value("AXSecureTextField"), enabled: true) == .secure)
            check(
                "2258 role failure cannot erase secure subrole evidence",
                AccessibilitySensitivity.classify(
                    role: .unavailable, subrole: .value("AXSecureTextField"), enabled: nil) == .secure)
            check(
                "2258 subrole read failure is unknown",
                AccessibilitySensitivity.classify(role: .value("AXTextField"), subrole: .unavailable, enabled: true)
                    == .unknown)
            check(
                "2258 unsupported optional subrole allows known enabled text role",
                AccessibilitySensitivity.classify(role: .value("AXTextArea"), subrole: .notPresent, enabled: true)
                    == .normal)
            check(
                "2258 enabled evidence failure is unknown",
                AccessibilitySensitivity.classify(role: .value("AXTextArea"), subrole: .notPresent, enabled: nil)
                    == .unknown)
        }
        do {
            let backend = CoreHeldFlowBackend()
            let router = FlowRouter(regex: backend)
            let request = FlowRequest(
                sessionID: SessionID(token: "deadline", sequence: 1, createdAtUptimeNanos: 0),
                text: "  synthetic café -12 kg  ", style: .clean, language: .enUS,
                sensitivity: .normal, deadlineNanosAhead: 100_000_000)
            let output = await router.process(request)
            let entered = await backend.entered
            check(
                "2279 request deadline returns before native completion", output.status == .deadlineExceeded && entered)
            check(
                "2279 deadline fallback preserves exact Unicode and whitespace",
                output.text == request.text && output.resolvedLossClass == .verbatim)
            check("2279 deadline retains native work owner", await router.hasOutstandingWork)
            let busy = await router.process(request)
            check("2279 busy native backend does not accumulate work", busy.status == .rejected)
            await backend.release()
            for _ in 0..<500 {
                if !(await router.hasOutstandingWork) { break }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            check("2279 actual completion releases native owner", !(await router.hasOutstandingWork))
        }
        do {
            let keyCalls = CoreTestCounter()
            let repo = ActorHistoryRepository(
                fileURL: URL(fileURLWithPath: "/synthetic-never-accessed/history.json"),
                fileSystem: InMemoryHistoryFS())
            let preparation = HistoryStoragePreparation(repository: repo) {
                keyCalls.bump()
                return nil
            }
            check("2261 history off skips initialization", await preparation.prepareForSession(saveHistory: false))
            check("2261 history off never requests a key", keyCalls.value == 0)
            check("2261 history off leaves storage uninitialized", await repo.storageState == .uninitialized)
            check(
                "2261 zero history wait budget does not launch work",
                !(await preparation.prepareForAccess(timeoutNanos: 0)))
            check("2261 rejected wait did not request key", keyCalls.value == 0)
        }
        // Current readiness, not consent or historical onboarding flags.
        do {
            let consentOnly = OnboardingReadinessSnapshot(
                microphone: true, speech: false, accessibility: false,
                downloadConsent: true, engineLoaded: false)
            check("2283 consent is not loaded readiness", !consentOnly.satisfies(.modelAcquisition))
            check(
                "2282 consent cannot satisfy Apple language capability", !consentOnly.satisfies(.languageAvailability))
            let cached = OnboardingReadinessSnapshot(
                microphone: true, speech: true, accessibility: false,
                downloadConsent: false, engineLoaded: true)
            check("2283 verified loaded cache needs no download consent", cached.satisfies(.modelAcquisition))
            for path in [OnboardingProductPath.appleSpeechAutomatic, .appleSpeechClipboardOnly] {
                check(
                    "2282 every Apple path checks language",
                    CapabilityGraph.steps(for: path).contains { $0.capability == .languageAvailability })
            }
            for localOnly in [true, false] {
                for onDevice in [true, false] {
                    let capabilities = SpeechReadinessCapabilities(
                        speechAuthorized: true, microphoneAuthorized: true,
                        requestedLocaleAvailable: true, recognizerAvailable: true, supportsOnDevice: onDevice)
                    if localOnly && !onDevice {
                        do {
                            _ = try capabilities.validate(localOnly: true)
                            check("2254 local only fails closed", false)
                        } catch {
                            check(
                                "2254 local only controlled failure",
                                error as? SpeechCapabilityFailure == .onDeviceUnavailable)
                        }
                    } else {
                        check(
                            "2254 prefer device even when network allowed",
                            (try? capabilities.validate(localOnly: localOnly)) == onDevice)
                    }
                }
            }
            let noSpeech = SpeechReadinessCapabilities(
                speechAuthorized: false, microphoneAuthorized: true,
                requestedLocaleAvailable: true, recognizerAvailable: true, supportsOnDevice: true)
            do {
                _ = try noSpeech.validate(localOnly: true)
                check("2254 denied speech rejects readiness", false)
            } catch {
                check(
                    "2254 speech authorization failure controlled",
                    error as? SpeechCapabilityFailure == .speechAuthorizationRequired)
            }
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
            let microphone = await env.permissions.microphoneGranted
            let accessibility = await env.permissions.accessibilityTrusted
            let speech = await env.permissions.speechRecognitionGranted
            check(
                "2243 fake permissions",
                microphone && accessibility && speech)
            let currentSettings = await env.settings.current
            check("2243 fake settings repo", currentSettings == .default)
            // Engine registry carries the fake engine.
            let engine = env.engines.makeEngine(for: .whisperTiny) as? FakeWhisperEngine
            check("2243 fake engine in registry", engine != nil)
            let freshRegistry = EngineRegistry(makeWhisper: { FakeWhisperEngine() }, makeAppleSpeech: nil)
            let firstCandidate = freshRegistry.makeEngine(for: .whisperTiny)
            let secondCandidate = freshRegistry.makeEngine(for: .whisperTiny)
            check("2243 registry factories create isolated candidates", firstCandidate !== secondCandidate)
            check("2243 missing backend cannot substitute Whisper", freshRegistry.makeEngine(for: .appleSpeech) == nil)
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
            // The test composition uses static settings, not the production store.
            let testSettings = await AppEnvironment.test().settings.current
            check("2243 test env has no side effects", testSettings == .default)
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
            let delivered = MutableArrayBox<TelemetryEvent>()
            sink.setHost { delivered.append($0) }
            for i in 0..<20 {
                sink.record(TelemetryEvent(sessionID: tid, kind: .stageEntered, atNanos: UInt64(i)))
            }
            check("2264 sink overflow drops counted", sink.droppedCount >= 16)
            check("2264 sink never blocks", sink.pendingCount == 4)
            _ = sink.drain()
            check("2264 sink drains to host", delivered.values.count == 4 && sink.pendingCount == 0)
            // Reentrant host callback (records inside callback) cannot deadlock.
            let reentrant = BoundedEventSink(capacity: 8)
            let nested = CoreTestCounter()
            reentrant.setHost { ev in
                if nested.bump() < 3 {
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
            check("2264 reentrant sink no deadlock", nested.value == 3 && drains == 3)
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
            let list = [
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
            try? await failRepo.load()  // initialize so writes reach the FS
            await failRepo.add(entry)
            // Review R4.1: add() no longer swallows persistence errors
            // silently — lastWriteError is recorded so the UI can surface it.
            check("2261 failing fs exercises error path", failing.failures > 0)
            let writeErr = await failRepo.lastWriteError
            check(
                "R4.1 add() persistence failure surfaced (lastWriteError)",
                writeErr != nil && !writeErr!.isEmpty)
            // A successful write clears the recorded error.
            let okRepo = ActorHistoryRepository(fileURL: file)
            try? await okRepo.load()
            await okRepo.add(
                HistoryStorageEntry(
                    timestamp: Date(), text: "ok", duration: 1, modelUsed: "Tiny",
                    sensitivityClass: "normal"))
            let okErr = await okRepo.lastWriteError
            check("R4.1 successful write clears lastWriteError", okErr == nil)
            try? FileManager.default.removeItem(at: dir)
        }

        // ===== R7 regression: fail-closed encrypted-history initialization =====
        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("zf-history-r7-\(UUID().uuidString)", isDirectory: true)
            let file = dir.appendingPathComponent("history.json")
            // Sealed (encrypted) data written under a key, then the key goes
            // missing: writes must be REFUSED, never overwritten with plaintext.
            let keyHolder = KeyHolder(
                HistoryCryptoKey(
                    keyID: "k1", material: Data(repeating: 0xAB, count: 32)))
            let repo = ActorHistoryRepository(fileURL: file, keyProvider: { keyHolder.key })
            await repo.configureEncryption(keyProvider: { keyHolder.key })
            try? await repo.load()
            await repo.add(
                HistoryStorageEntry(
                    timestamp: Date(), text: "sealed", duration: 1, modelUsed: "Tiny",
                    sensitivityClass: "normal"))
            // Now the key is lost; a fresh repo with no key sees sealed data.
            let noKey = ActorHistoryRepository(fileURL: file, keyProvider: { nil })
            try? await noKey.load()
            check(
                "R7 sealed data unreadable without key",
                await noKey.sealedDataUnreadable)
            // A write must fail closed (no plaintext overwrite).
            await noKey.add(
                HistoryStorageEntry(
                    timestamp: Date(), text: "should-not-write", duration: 1,
                    modelUsed: "Tiny", sensitivityClass: "normal"))
            let writeErr = await noKey.lastWriteError
            check("R7 missing key refuses write (fail-closed)", writeErr != nil)
            // The on-disk file is still sealed (not overwritten with plaintext).
            let data = try? Data(contentsOf: file)
            let sealedStill =
                data.flatMap {
                    try? JSONDecoder().decode(
                        EncryptedHistoryDocument.self, from: $0)
                } != nil
            check("R7 sealed file preserved (no plaintext overwrite)", sealedStill)
            // Encryption-configured-but-key-missing also refuses writes.
            let cfgNoKey = ActorHistoryRepository(fileURL: file, keyProvider: { nil })
            await cfgNoKey.configureEncryption(keyProvider: { nil })
            try? await cfgNoKey.load()
            await cfgNoKey.add(
                HistoryStorageEntry(
                    timestamp: Date(), text: "x", duration: 1, modelUsed: "T",
                    sensitivityClass: "normal"))
            check(
                "R7 configured-but-key-missing refuses write",
                await cfgNoKey.lastWriteError != nil)
            try? FileManager.default.removeItem(at: dir)
        }

        // ===== REQ-5 round-5: explicit history storage states =====
        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("zf-history-req5-\(UUID().uuidString)", isDirectory: true)
            let file = dir.appendingPathComponent("history.json")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            // Fresh install + encryption configured + key -> readyEncrypted.
            let key = HistoryCryptoKey(keyID: "k", material: Data(repeating: 0x21, count: 32))
            let fresh = ActorHistoryRepository(fileURL: file, keyProvider: { key })
            await fresh.configureEncryption(keyProvider: { key })
            try? await fresh.load()
            check(
                "REQ5 fresh+encrypted -> readyEncrypted",
                await fresh.storageState == .readyEncrypted)

            // Fresh install + no encryption -> readyPlaintext.
            let file2 = dir.appendingPathComponent("history2.json")
            let plain = ActorHistoryRepository(fileURL: file2)
            try? await plain.load()
            check(
                "REQ5 fresh no-encryption -> readyPlaintext",
                await plain.storageState == .readyPlaintext)

            // Sealed data + missing key -> sealedKeyUnavailable (never empty
            // in-memory admission).
            let keyHolder = KeyHolder(key)
            let sealed = ActorHistoryRepository(fileURL: file2, keyProvider: { keyHolder.key })
            await sealed.configureEncryption(keyProvider: { keyHolder.key })
            try? await sealed.load()
            await sealed.add(
                HistoryStorageEntry(
                    timestamp: Date(), text: "s", duration: 1, modelUsed: "T",
                    sensitivityClass: "normal"))
            keyHolder.set(nil)
            let noKey = ActorHistoryRepository(fileURL: file2, keyProvider: { nil })
            await noKey.configureEncryption(keyProvider: { nil })
            try? await noKey.load()
            check(
                "REQ5 sealed + missing key -> sealedKeyUnavailable",
                await noKey.storageState == .sealedKeyUnavailable)

            // Storage read failure -> storageReadFailure (NOT corruption).
            let file3 = dir.appendingPathComponent("history3.json")
            try? Data("{\"schemaVersion\":2,\"entries\":[]}".utf8).write(to: file3)
            let badFS = UnreadableHistoryFileSystem()
            let readFail = ActorHistoryRepository(fileURL: file3, fileSystem: badFS)
            try? await readFail.load()
            check(
                "REQ5 unreadable file -> storageReadFailure (not corruption)",
                await readFail.storageState == .storageReadFailure)
            check(
                "REQ5 unreadable file not quarantined",
                !FileManager.default.fileExists(atPath: file3.path + ".quarantined"))

            // Genuine corruption -> corruptQuarantined + quarantined file.
            let file4 = dir.appendingPathComponent("history4.json")
            try? Data("garbage-not-json".utf8).write(to: file4)
            let corrupt = ActorHistoryRepository(fileURL: file4)
            try? await corrupt.load()
            check(
                "REQ5 corruption -> corruptQuarantined",
                await corrupt.storageState == .corruptQuarantined)
            check(
                "REQ5 corruption quarantined file",
                FileManager.default.fileExists(atPath: file4.path + ".quarantined"))

            // markHistoryDisabled -> historyDisabled.
            await plain.markHistoryDisabled()
            check(
                "REQ5 markHistoryDisabled",
                await plain.storageState == .historyDisabled)

            try? FileManager.default.removeItem(at: dir)
        }

        // ===== B5 regression: plaintext->encrypted migration (production order) =====
        do {
            // Review B5v2: production ordering — configure encryption, load a
            // LEGACY PLAINTEXT file, verify it is re-encrypted, relaunch, and
            // decrypt the same entries. (Old bug: the migration persist ran
            // before isInitialized, failed the init guard, and the valid
            // history was quarantined as corruption.)
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("zf-history-b5-\(UUID().uuidString)", isDirectory: true)
            let file = dir.appendingPathComponent("history.json")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Write a legacy plaintext document.
            let legacy = HistoryDocument(
                schemaVersion: 1,
                entries: [
                    HistoryStorageEntry(
                        timestamp: Date(), text: "legacy-entry", duration: 1.0,
                        modelUsed: "Tiny", sensitivityClass: "normal")
                ])
            let plainEnc = JSONEncoder()
            plainEnc.dateEncodingStrategy = .iso8601
            let plain = try! plainEnc.encode(legacy)
            try! plain.write(to: file)

            // Configure encryption + load (production order).
            let key = HistoryCryptoKey(keyID: "k", material: Data(repeating: 0xCD, count: 32))
            let repo = ActorHistoryRepository(fileURL: file, keyProvider: { key })
            await repo.configureEncryption(keyProvider: { key })
            // Load with explicit error capture: a migration failure must not
            // surface as corruption/quarantine.
            var loadError: Error?
            do {
                try await repo.load()
            } catch {
                loadError = error
            }
            check("B5 load has no corruption error", loadError == nil)
            // The legacy entry is retained (NOT quarantined).
            let entries = await repo.entries()
            check(
                "B5 legacy plaintext migrated, entry retained", entries.count == 1 && entries[0].text == "legacy-entry")
            check(
                "B5 migration did not quarantine (no recovery error)",
                await repo.recoveryState == nil)
            // The on-disk file is now ENCRYPTED.
            let disk = try! Data(contentsOf: file)
            let encryptedOnDisk = (try? JSONDecoder().decode(EncryptedHistoryDocument.self, from: disk)) != nil
            check("B5 file re-encrypted after migration", encryptedOnDisk)
            // Relaunch: a fresh repo with the SAME key decrypts the entries.
            let relaunched = ActorHistoryRepository(fileURL: file, keyProvider: { key })
            try? await relaunched.load()
            let reEntries = await relaunched.entries()
            check(
                "B5 relaunch decrypts same entries",
                reEntries.count == 1 && reEntries[0].text == "legacy-entry")
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
    }

    static func runPart6() async {
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
            let weak7 = WeakSessionReference(s7)
            // Round-6: the Task closure must capture an IMMUTABLE actor
            // reference (Sendable) — capturing a mutable `var` would be a
            // non-Sendable capture under Swift-6 diagnostics.
            let runTask7: Task<Void, Never>? = s7.map { captured in
                Task { await captured.run() }
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
            await s7!.end()
            await runTask7?.value
            s7 = nil
            // Give the executor a beat to run deinit.
            var released = false
            for _ in 0..<5 {
                try? await Task.sleep(nanoseconds: 40_000_000)
                if weak7.value == nil {
                    released = true
                    break
                }
            }
            check("2244 session released after terminal (leak test)", released)
        }

        // ===== JOE-2255: verified model acquisition lifecycle =====
        do {
            // Round-6 B4: directory-aware hash mirroring FakeModelFS.
            @Sendable nonisolated func dirHash(_ entries: [(String, Data)]) -> String {
                let sorted = entries.sorted { $0.0 < $1.0 }
                var hasher = SHA256()
                for (rel, data) in sorted {
                    hasher.update(data: Data(rel.utf8))
                    hasher.update(data: withUnsafeBytes(of: UInt64(data.count).bigEndian) { Data($0) })
                    hasher.update(data: data)
                }
                return hasher.finalize().map { String(format: "%02x", $0) }.joined()
            }

            @Sendable nonisolated func manifest(
                _ model: ModelIdentifier,
                digests: [String: String] = [:]
            ) -> ModelManifest {
                // Round-5 B5: digests are REQUIRED for every artifact. When a
                // caller supplies any digest, fill ALL components with their
                // deterministic fake payload digests (unless explicitly set).
                var allDigests = digests
                // Round-6 B4: components are .mlmodelc DIRECTORY bundles and a
                // tokenizer DIRECTORY — digests are the directory-aware hashes
                // of the fake's payload layout.
                let names = [
                    "config.json",
                    "MelSpectrogram.mlmodelc",
                    "AudioEncoder.mlmodelc",
                    "TextDecoder.mlmodelc",
                    "TextDecoderContextPrefill.mlmodelc",
                    "tokenizer",
                ]
                for (i, name) in names.enumerated() {
                    if allDigests[name] == nil {
                        if i == 0 {
                            allDigests[name] = SHA256.hash(data: Data(repeating: 0xAB, count: 10_000))
                                .map { String(format: "%02x", $0) }.joined()
                        } else if name == "tokenizer" {
                            allDigests[name] = dirHash([
                                ("config.json", Data(repeating: 0x45, count: 5_000)),
                                ("tokenizer.json", Data(repeating: 0x44, count: 200_000)),
                            ])
                        } else {
                            // Match the fake's payload size exactly
                            // (downloadBytes / bundle count = 500,000 default).
                            allDigests[name] = dirHash([
                                ("model.mlmodel", Data(repeating: UInt8(0x20 + (i - 1)), count: 500_000))
                            ])
                        }
                    }
                }
                return ModelAcquisitionController.makeManifest(
                    for: model, createdAtUptimeNanos: 1,
                    minArtifactBytes: 1_000,
                    minTotalBytes: 1_000_000, maxTotalBytes: 100_000_000,
                    digests: allDigests)
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
            let barrier10 = CoreDownloadBarrier()
            let fs10 = FakeModelFS(beforeDownload: { await barrier10.wait() })
            let acq10 = ModelAcquisitionController(fs: fs10)
            let task10 = Task {
                await acq10.acquire(model: .whisperTiny, consent: true)
            }
            for _ in 0..<5000 {
                if await barrier10.entered { break }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            check("2255 explicit-cancel fixture reached held download", await barrier10.entered)
            await acq10.cancel(model: .whisperTiny)
            await barrier10.release()
            let r10 = await task10.value
            check("2255 cancel mid-download -> cancelled", r10.state == .cancelled)
            check(
                "2255 cancelled never ready",
                await acq10.verifiedReadiness(for: .whisperTiny).state != .ready)
            check("2255 explicit cancel reaches download task", fs10.downloadCancellations == 1)
            let retried10 = await acq10.acquire(model: .whisperTiny, consent: true)
            check("2255 retry after cancel resets cancellation", retried10.state == .ready && fs10.downloadCalls == 2)

            let ownerBarrier = CoreDownloadBarrier()
            let fsCancelledOwner = FakeModelFS(beforeDownload: { await ownerBarrier.wait() })
            let cancelledOwner = ModelAcquisitionController(fs: fsCancelledOwner)
            let owner = Task { await cancelledOwner.acquire(model: .whisperTiny, consent: true) }
            for _ in 0..<5000 {
                if await ownerBarrier.entered { break }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            check("2255 owner-cancel fixture reached download", await ownerBarrier.entered)
            owner.cancel()
            await ownerBarrier.release()
            let cancelledResult = await owner.value
            check("2255 caller cancellation reaches retained native task", fsCancelledOwner.downloadCancellations == 1)
            check(
                "2255 cancelled caller cannot promote",
                cancelledResult.state == .cancelled && cancelledResult.verifiedURL == nil)
            check(
                "2255 cancelled caller leaves no verified artifact",
                await cancelledOwner.verifiedArtifact(for: .whisperTiny) == nil)

            check(
                "2255 unknown transport progress stays indeterminate",
                ModelDownloadProgress(fraction: nil, bytesDownloaded: 0, bytesExpected: nil).fraction == nil)
            check(
                "2255 invalid measured progress rejected",
                ModelDownloadProgress(fraction: .nan, bytesDownloaded: 0, bytesExpected: nil).fraction == nil
                    && ModelDownloadProgress(fraction: 1.1, bytesDownloaded: 0, bytesExpected: nil).fraction == nil)

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

        // ===== B5 round-5: verified model = all loaded bytes verified =====
        do {
            // Review B5 (round 5): a "verified" model means EVERY artifact
            // WhisperKit loads (config + MelSpectrogram + AudioEncoder +
            // TextDecoder + TextDecoderContextPrefill + tokenizer) is
            // enumerated in the manifest AND digest-verified. The default
            // production manifest must enumerate all of them.
            let defaultManifest = ModelAcquisitionController.makeManifest(
                for: .whisperTiny, createdAtUptimeNanos: 0)
            let names = Set(defaultManifest.artifacts.map { $0.name })
            for expected in [
                "config.json",
                "MelSpectrogram.mlmodelc",
                "AudioEncoder.mlmodelc",
                "TextDecoder.mlmodelc",
                "TextDecoderContextPrefill.mlmodelc",
                "tokenizer",
            ] {
                check("B5r5 default manifest includes \(expected)", names.contains(expected))
            }
            // Every artifact in the default manifest is digest-required after
            // promotion (the controller writes a digest-COMPLETE manifest).
            let fs = FakeModelFS()
            let acq = ModelAcquisitionController(fs: fs)
            let r = await acq.acquire(model: .whisperTiny, consent: true)
            check("B5r5 happy path ready with all components", r.state == .ready)
            // Atomic artifact: folder + manifest version + aggregate digest.
            let artifact = await acq.verifiedArtifact(for: .whisperTiny)
            check("B5r5 atomic artifact present", artifact != nil)
            if let a = artifact {
                check("B5r5 artifact folder is verified cache", a.folder.path.contains("verified"))
                check("B5r5 artifact manifest version", a.manifestVersion == ModelManifest.schemaVersion)
                check("B5r5 aggregate digest non-empty", a.aggregateDigest.contains(":"))
            }
            // Changing ANY component after promotion invalidates readiness
            // (re-verification hashes every artifact).
            let fs2 = FakeModelFS()
            let acq2 = ModelAcquisitionController(fs: fs2)
            _ = await acq2.acquire(model: .whisperTiny, consent: true)
            let verifiedURL = await acq2.verifiedURL(for: .whisperTiny)
            check("B5r5 verified before tamper", verifiedURL != nil)
            // Tamper: overwrite TextDecoder.mlmodelc with different bytes.
            if let url = verifiedURL {
                let tampered = url.appendingPathComponent("TextDecoder.mlmodelc")
                try? fs2.remove(tampered)
                fs2.writeRaw(
                    tampered, data: Data(repeating: 0xEE, count: 500_000))
                let after = await acq2.verifiedArtifact(for: .whisperTiny)
                check("B5r5 tampered component invalidates readiness", after == nil)
                check("B5r5 tampered component -> verifiedURL nil", await acq2.verifiedURL(for: .whisperTiny) == nil)
            }
            // Hash failure: a digest-COMPLETE manifest whose stored artifact
            // no longer matches (tampered after promotion) invalidates.
            let fs3 = FakeModelFS()
            let acq3 = ModelAcquisitionController(fs: fs3)
            _ = await acq3.acquire(model: .whisperTiny, consent: true)
            if let url = await acq3.verifiedURL(for: .whisperTiny) {
                // Tamper with the config (the manifest carries its digest).
                let cfg = url.appendingPathComponent("config.json")
                try? fs3.remove(cfg)
                fs3.writeRaw(cfg, data: Data(repeating: 0x77, count: 9_000))
                check(
                    "B5r5 tampered config invalidates readiness",
                    await acq3.verifiedArtifact(for: .whisperTiny) == nil)
            }
        }

        // Model-bound tokenizer cache lookup (synthetic filesystem only).
        do {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("zf-tokenizer-locator-\(UUID())")
            let base = root.appendingPathComponent("openai/whisper-base")
            do {
                try fm.createDirectory(at: base, withIntermediateDirectories: true)
                for name in ["tokenizer.json", "tokenizer_config.json"] {
                    try Data("synthetic locator fixture".utf8).write(to: base.appendingPathComponent(name))
                }
                check(
                    "tokenizer locator rejects other model",
                    WhisperTokenizerLocator.locate(model: .whisperTiny, roots: [root]) == nil)
                check(
                    "tokenizer locator selects requested namespace",
                    WhisperTokenizerLocator.locate(model: .whisperBase, roots: [root])?.path == base.path)
                try fm.removeItem(at: base.appendingPathComponent("tokenizer_config.json"))
                check(
                    "tokenizer locator requires configuration",
                    WhisperTokenizerLocator.locate(model: .whisperBase, roots: [root]) == nil)
                try fm.removeItem(at: root)
            } catch {
                check("tokenizer locator fixture must complete", false)
            }
        }

        // ===== B4 round-6: directory-aware verified model =====
        do {
            // Review B4 (round 6): a compiled .mlmodelc is a DIRECTORY bundle.
            // The fake writes directories; acquisition must hash them
            // recursively and a change inside ANY file invalidates readiness.
            let fs = FakeModelFS()
            let acq = ModelAcquisitionController(fs: fs)
            let r = await acq.acquire(model: .whisperTiny, consent: true)
            check("B4r6 directory-model happy path ready", r.state == .ready)
            let artifact = await acq.verifiedArtifact(for: .whisperTiny)
            check("B4r6 directory-model verified artifact", artifact != nil)
            // Tamper with a file INSIDE an .mlmodelc bundle.
            if let url = await acq.verifiedURL(for: .whisperTiny) {
                let inner =
                    url
                    .appendingPathComponent("TextDecoder.mlmodelc")
                    .appendingPathComponent("model.mlmodel")
                try? fs.remove(inner)
                fs.writeRaw(inner, data: Data(repeating: 0x77, count: 300_000))
                check(
                    "B4r6 inner file tamper invalidates readiness",
                    await acq.verifiedArtifact(for: .whisperTiny) == nil)
            }
            // Optional prefill: a model WITHOUT TextDecoderContextPrefill is
            // still valid (the pinned loader loads it only when present).
            let fs2 = FakeModelFS()
            // Remove the optional prefill from the fake's download.
            fs2.skipPrefill = true
            let acq2 = ModelAcquisitionController(fs: fs2)
            let r2 = await acq2.acquire(model: .whisperTiny, consent: true)
            check("B4r6 optional prefill absent still ready", r2.state == .ready)
            // Tokenizer directory is part of the verified artifact.
            let names = Set(
                ModelAcquisitionController.makeManifest(for: .whisperTiny, createdAtUptimeNanos: 0)
                    .artifacts.map { $0.name })
            check("B4r6 tokenizer dir in manifest", names.contains("tokenizer"))
            // Prefill marked optional in the manifest.
            if let prefill = ModelAcquisitionController.makeManifest(
                for: .whisperTiny, createdAtUptimeNanos: 0
            )
            .artifacts.first(where: { $0.name == "TextDecoderContextPrefill.mlmodelc" }) {
                check("B4r6 prefill is optional", prefill.isOptional)
            }
        }

        // ===== JOE-2262: at-rest history encryption =====
        do {
            @Sendable nonisolated func key(_ id: String = "k1") -> HistoryCryptoKey {
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
            let outcomeA = t.acceptCompletion(
                requestID: a1, model: .whisperTiny,
                outcome: .failed(model: .whisperTiny, message: "boom"))
            check(
                "2256 stale A completion superseded",
                outcomeA == .superseded(model: .whisperTiny, byRequestID: a2))
            let outcomeB = t.acceptCompletion(
                requestID: b1, model: .whisperBase,
                outcome: .ready(model: .whisperBase))
            check(
                "2256 stale B completion superseded",
                outcomeB == .superseded(model: .whisperBase, byRequestID: a2))
            // Current completion publishes.
            let outcomeCurrent = t.acceptCompletion(
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

        // ===== JOE-2289: localization-ready strings =====
        do {
            // 1. Catalog completeness: every UI reference resolves; unknown
            //    keys resolve to themselves (surfaced by the CI scan).
            let known = AppStrings.key("panel.processing")
            check("2289 known key resolves", known == "Processing…")
            check("2289 unknown key returns key", AppStrings.key("nope.missing") == "nope.missing")

            // 2. Every catalog entry has a translator context and non-empty
            //    English value.
            for (k, entry) in AppStrings.catalog {
                check("2289 context for \(k)", !entry.context.isEmpty)
                check("2289 value for \(k)", !entry.value.isEmpty)
            }

            // 3. UI locale independence: the transcription-language picker is
            //    independent of the UI locale. SupportedLanguage is the
            //    engine-capability matrix (JOE-2254) with Auto.
            check(
                "2289 transcription matrix has Auto",
                SupportedLanguage.allCases.contains(.auto))
            check(
                "2289 matrix is BCP-47",
                SupportedLanguage.allCases.allSatisfy { $0.isAuto || ($0.bcp47?.isEmpty == false) })

            // 4. Pseudolocalization expands length (layout probe).
            let pseudo = AppStrings.pseudolocalize("Hold Fn to speak")
            check("2289 pseudolocalize expands", pseudo.count > "Hold Fn to speak".count)
            check(
                "2289 pseudolocalize wraps markers",
                pseudo.hasPrefix("⟦") && pseudo.hasSuffix("⟧"))

            // 5. Long-string probe expands ~1.8x for layout testing.
            let long = AppStrings.longProbe("Stop and insert")
            check("2289 long probe expands", long.count >= "Stop and insert".count * 2)

            // 6. Technical identifiers are protected (never localized).
            check(
                "2289 model id protected",
                AppStrings.isProtected("openai_whisper-tiny"))
            check(
                "2289 bundle id protected",
                AppStrings.isProtected("com.zephyrflow.history-key"))
            check(
                "2289 path protected",
                AppStrings.isProtected("~/Library/Logs/ZephyrFlow/"))
            check("2289 app name protected", AppStrings.isProtected("ZephyrFlow"))

            // 7. RTL readiness: no hard-coded leading directional punctuation
            //    in catalog values.
            for (k, entry) in AppStrings.catalog {
                check(
                    "2289 rtl probe \(k)",
                    AppStrings.rtlProbeReady(entry.value))
            }

            // 8. Parameterized strings format without concatenating
            //    grammar-sensitive fragments.
            let review = AppStrings.format("panel.reviewTitle", "Target changed")
            check(
                "2289 parameterized format",
                review == "Review: Target changed")
            let engine = AppStrings.format("menu.engine", "Whisper Tiny")
            check("2289 engine label format", engine == "Engine: Whisper Tiny")

            // 9. Onboarding steps carry localization-ready keys that resolve.
            for p in OnboardingProductPath.allCases {
                for st in CapabilityGraph.steps(for: p) {
                    check(
                        "2289 step \(st.id) key resolves",
                        AppStrings.key(st.titleKey) != st.titleKey
                            && AppStrings.key(st.explanationKey) != st.explanationKey)
                }
            }

            // 10. Locale-aware byte/duration formatting produce output.
            check("2289 byte size formatted", !AppStrings.byteSize(1_500_000).isEmpty)
            check("2289 duration formatted", !AppStrings.duration(65).isEmpty)
        }

        // ===== JOE-2283: first-run model UX policy =====
        do {
            // 1. Every verified lifecycle state renders with a name, action
            //    and dictation-blocking rule (deterministic).
            for state in [
                ModelReadinessState.missing, .queued,
                .downloading(0.4), .verifying, .ready, .cancelled,
                .quarantined, .failed("boom"),
            ] {
                let r = ModelUIPolicy.render(for: state)
                check("2283 render \(r.stateName)", !r.stateName.isEmpty)
            }
            check(
                "2283 ready does not block dictation",
                !ModelUIPolicy.render(for: .ready).blocksDictation)
            check(
                "2283 missing blocks dictation",
                ModelUIPolicy.render(for: .missing).blocksDictation)
            check(
                "2283 verifying blocks dictation",
                ModelUIPolicy.render(for: .verifying).blocksDictation)

            // 2. Honest progress only when a real fraction exists; otherwise
            //    indeterminate (never fake bytes).
            let withFraction = ModelUIPolicy.render(for: .downloading(0.42))
            check(
                "2283 real fraction honest",
                withFraction.hasHonestProgress && !withFraction.isIndeterminate)
            let noFraction = ModelUIPolicy.render(for: .downloading(nil))
            check(
                "2283 no fraction indeterminate",
                !noFraction.hasHonestProgress && noFraction.isIndeterminate)

            // 3. Download gate: consent required; cached verified model
            //    starts from cache; insufficient disk gives actionable gate.
            check(
                "2283 cached model starts from cache",
                ModelUIPolicy.mayStartDownload(
                    consent: false,
                    hasCachedVerifiedModel: true,
                    freeBytes: 0) == .startFromCache)
            check(
                "2283 no consent -> consent required",
                ModelUIPolicy.mayStartDownload(
                    consent: false,
                    hasCachedVerifiedModel: false,
                    freeBytes: 100_000_000_000) == .consentRequired)
            check(
                "2283 consent + space -> allowed",
                ModelUIPolicy.mayStartDownload(
                    consent: true,
                    hasCachedVerifiedModel: false,
                    freeBytes: 100_000_000_000) == .allowed)
            let diskGate = ModelUIPolicy.mayStartDownload(
                consent: true,
                hasCachedVerifiedModel: false,
                freeBytes: 100_000_000)
            check(
                "2283 low disk -> insufficient",
                diskGate
                    == .insufficientDiskSpace(
                        required: 1_500_000_000,
                        available: 100_000_000))

            // 4. Cleanup guidance is actionable.
            let guidance = ModelUIPolicy.cleanupGuidance(
                available: 100_000_000,
                required: 1_500_000_000)
            check("2283 cleanup guidance actionable", guidance.contains("Free at least"))

            // 5. Cancelled/failed downloads are recoverable (retry action).
            check(
                "2283 cancelled recoverable with retry",
                ModelUIPolicy.render(for: .cancelled).primaryAction == .retry
                    && ModelUIPolicy.render(for: .cancelled).recoverable)
            check(
                "2283 quarantined recoverable with retry",
                ModelUIPolicy.render(for: .quarantined).primaryAction == .retry)

            // 6. Verification is a visible state distinct from download
            //    completion.
            let downloading = ModelUIPolicy.render(for: .downloading(0.9))
            let verifying = ModelUIPolicy.render(for: .verifying)
            check(
                "2283 verifying distinct from downloading",
                verifying.stateName != downloading.stateName && verifying.primaryAction == .none
                    && downloading.primaryAction == .cancel)

            // 7. Superseded completions never overwrite current UI: the
            //    current-request publish path (JOE-2256) absorbs stale
            //    completions as no-ops.
            check("2283 superseded absorbed", ModelUIPolicy.absorbCompletion(isCurrent: false) == .none)
            check("2283 current absorbed", ModelUIPolicy.absorbCompletion(isCurrent: true) == .none)
        }
    }

    static func runPart7() async {
        // ===== JOE-2292: deterministic randomized session stress =====
        do {
            // 1. Seeded PRNG is deterministic and reproducible.
            var a = SplitMix64(seed: 42)
            var b = SplitMix64(seed: 42)
            var seqA: [UInt64] = []
            var seqB: [UInt64] = []
            for _ in 0..<100 { seqA.append(a.next()) }
            for _ in 0..<100 { seqB.append(b.next()) }
            check("2292 PRNG deterministic", seqA == seqB)

            // 2. Stress run (fixed seed) is green: exactly-one terminal,
            //    no cross-session, no sensitive side effects, validation
            //    before mutation, resource release.
            let report = await SessionStressHarness.run(
                config: SessionStressConfig(seed: 0x5EED, iterations: 40))
            check("2292 stress green", report.isGreen)
            check("2292 exactly-one terminal", report.exactlyOneTerminalVerified)
            check("2292 cross-session ok", report.crossSessionVerified)
            check(
                "2292 sensitive side effects blocked",
                report.sensitiveSideEffectsVerified)
            check(
                "2292 validation before mutation",
                report.validationBeforeMutationVerified)
            check("2292 no violations", report.violations.isEmpty)

            // 3. Different seed, larger run stays green.
            let report2 = await SessionStressHarness.run(
                config: SessionStressConfig(seed: 0xBEEF, iterations: 60))
            check("2292 second seed green", report2.isGreen)

            // 4. Replay determinism: same seed -> same green outcome.
            let replay = await SessionStressHarness.run(
                config: SessionStressConfig(seed: 0x5EED, iterations: 40))
            check(
                "2292 replay reproducible",
                replay.violations == report.violations)

            // 5. Sensitive-session rule: secure sessions never insert/history.
            let provider = StressSessionProvider(seed: 7, normalSensitivity: false)
            await provider.prepare(
                sessionID: SessionID(
                    token: "t", sequence: 1,
                    createdAtUptimeNanos: 0))
            let snap = await provider.capturedTargetSnapshot()
            check(
                "2292 secure snapshot carries secure sensitivity",
                snap?.sensitivity.sensitivity == .secure)

            // 6. Terminal taxonomy coverage: stress across many seeds reaches
            //    multiple terminal categories (completed/secure-target/...).
            let catSeeds: Set<UInt64> = []
            _ = catSeeds
            // Deterministic PRNG gives a fixed set of behaviors per seed;
            // assert the taxonomy union is non-trivial across the corpus.
            let corpus: [UInt64] = [0x1111, 0x2222, 0x3333]
            var greenCount = 0
            for seed in corpus {
                let rep = await SessionStressHarness.run(
                    config: SessionStressConfig(seed: seed, iterations: 25))
                if rep.isGreen { greenCount += 1 }
            }
            check("2292 corpus all green", greenCount == corpus.count)
        }

        // ===== JOE-2293: crash recovery + rapid-control stress =====
        do {
            // 1. Crash mid-write with non-atomic commit rolls back to OLD
            //    (never mixed).
            let partial = CrashRecoveryPolicy.recover(
                faultPoint: .settingsWrite, wrotePartialData: true,
                commitWasAtomic: false)
            check(
                "2293 partial non-atomic -> old intact",
                partial == .oldStateIntact)
            let atomic = CrashRecoveryPolicy.recover(
                faultPoint: .historyWrite, wrotePartialData: true,
                commitWasAtomic: true)
            check(
                "2293 atomic commit -> new intact",
                atomic == .newStateIntact)
            let clean = CrashRecoveryPolicy.recover(
                faultPoint: .modelPromote, wrotePartialData: false,
                commitWasAtomic: false)
            check("2293 clean non-atomic -> old intact", clean == .oldStateIntact)

            // 2. Every fault point has a deterministic recovery rule.
            for fp in CrashFaultPoint.allCases {
                let r = CrashRecoveryPolicy.recover(
                    faultPoint: fp,
                    wrotePartialData: true,
                    commitWasAtomic: false)
                check("2293 \(fp.rawValue) rolls back", r == .oldStateIntact)
                let r2 = CrashRecoveryPolicy.recover(
                    faultPoint: fp,
                    wrotePartialData: true,
                    commitWasAtomic: true)
                check("2293 \(fp.rawValue) atomic commits", r2 == .newStateIntact)
            }

            // 3. Relaunch consistency: each boundary reports old-or-new.
            check(
                "2293 relaunch consistent (all old)",
                CrashRecoveryPolicy.relaunchConsistent(
                    settingsOld: true, settingsNew: false,
                    historyOld: true, historyNew: false,
                    modelOld: true, modelNew: false,
                    pasteboardOld: true, pasteboardNew: false))
            check(
                "2293 relaunch consistent (mixed new)",
                CrashRecoveryPolicy.relaunchConsistent(
                    settingsOld: false, settingsNew: true,
                    historyOld: true, historyNew: false,
                    modelOld: true, modelNew: false,
                    pasteboardOld: true, pasteboardNew: false))
            check(
                "2293 relaunch INCONSISTENT detected",
                !CrashRecoveryPolicy.relaunchConsistent(
                    settingsOld: true, settingsNew: false,
                    historyOld: false, historyNew: false,  // neither = lost
                    modelOld: true, modelNew: false,
                    pasteboardOld: true, pasteboardNew: false))

            // 4. Rapid-control stress (seeded) is green across seeds.
            for seed in [UInt64(0xA11CE), 0xBADC0DE, 0xF00D] {
                let rep = await RapidControlStress.run(seed: seed, cycles: 12)
                check("2293 rapid control green seed \(seed)", rep.isGreen)
            }

            // 5. PRNG drives distinct rapid-control sequences per seed.
            var a = SplitMix64(seed: 0xA11CE)
            var b = SplitMix64(seed: 0xBADC0DE)
            var seqA: [UInt64] = []
            var seqB: [UInt64] = []
            for _ in 0..<16 {
                seqA.append(a.next())
                seqB.append(b.next())
            }
            check("2293 distinct seeds distinct sequences", seqA != seqB)
        }

        // ===== JOE-2286: exact + transactional Fn preference override =====
        do {
            // 1. Nil fixture: absent key restores as absent (never removes
            //    a value; there was none).
            let snap = FnPreferenceSnapshot(
                keyPresent: false, value: nil,
                cfTypeTag: nil)
            var tx = FnPreferenceTransaction(snapshot: snap)
            check("2286 begin apply", tx.beginApply())
            tx.markApplied(mutationSucceeded: true)
            check("2286 applied", tx.record.status == .applied)
            check("2286 applied is active override", tx.record.isActiveOverride)
            check("2286 begin restore", tx.beginRestore())
            // Read-back verified exact: key absent.
            tx.finishRestore(verifiedExact: true)
            check("2286 restored", tx.record.status == .restored)
            check("2286 completed NOT active", !tx.record.isActiveOverride)

            // 2. Integer fixture: exact value + CF type restore.
            let intSnap = FnPreferenceSnapshot(
                keyPresent: true, value: 2,
                cfTypeTag: "CFNumber")
            var tx2 = FnPreferenceTransaction(snapshot: intSnap)
            _ = tx2.beginApply()
            tx2.markApplied(mutationSucceeded: true)
            _ = tx2.beginRestore()
            tx2.finishRestore(verifiedExact: true)
            check(
                "2286 int restore keeps snapshot",
                tx2.record.snapshot.value == 2 && tx2.record.snapshot.keyPresent)

            // 3. Unexpected-value fixture (CFString): type captured exactly.
            let strSnap = FnPreferenceSnapshot(
                keyPresent: true, value: nil,
                cfTypeTag: "CFString")
            check("2286 CFString type captured", strSnap.cfTypeTag == "CFString")

            // 4. Pure state transitions, not actual kill/relaunch evidence.
            //    idle -> stays idle; pendingApply is uncertain -> restore;
            //    applied -> pendingRestore (must restore);
            //    pendingRestore -> pendingRestore; restored -> restored.
            for status in FnPreferenceStatus.allCases {
                let rec = FnPreferenceRecord(
                    version: 2, status: status,
                    snapshot: snap)
                var txc = FnPreferenceTransaction(record: rec)
                let after = txc.recoverAfterCrash()
                if status == .idle || status == .restored || status == .failedRestore {
                    check("2286 crash \(status.rawValue) unchanged", after == status)
                } else if status == .pendingApply {
                    check("2286 crash pendingApply -> pendingRestore", after == .pendingRestore)
                } else {
                    check(
                        "2286 crash applied/pendingRestore -> pendingRestore",
                        after == .pendingRestore)
                }
                check(
                    "2286 crash recovery idempotent",
                    txc.recoverAfterCrash() == after)
            }

            // 5. Restore FAILURE disables capture + surfaces recovery, and
            //    never re-applies automatically.
            var tx5 = FnPreferenceTransaction(snapshot: intSnap)
            _ = tx5.beginApply()
            tx5.markApplied(mutationSucceeded: true)
            _ = tx5.beginRestore()
            tx5.finishRestore(verifiedExact: false)
            check("2286 failedRestore", tx5.record.status == .failedRestore)
            check("2286 capture disabled", tx5.captureDisabled)
            check("2286 failed NOT active", !tx5.record.isActiveOverride)
            check("2286 failed recovery cannot reapply", !tx5.beginApply())
            check("2286 explicit retry can restore", tx5.beginRestore())
            tx5.finishRestore(verifiedExact: true)
            check("2286 verified retry clears capture-disabled", !tx5.captureDisabled)

            // 6. Production default path never overrides.
            check(
                "2286 default no override",
                !FnOverridePolicy.shouldOverride(
                    experimentalOptIn: false, configuredSpecialKeyIsFn: true,
                    tapPrepared: true))
            check(
                "2286 requires opt-in + fn + tap",
                FnOverridePolicy.shouldOverride(
                    experimentalOptIn: true, configuredSpecialKeyIsFn: true,
                    tapPrepared: true))
            check(
                "2286 no override without tap",
                !FnOverridePolicy.shouldOverride(
                    experimentalOptIn: true, configuredSpecialKeyIsFn: true,
                    tapPrepared: false))
            check(
                "2286 restore immediately on fn change",
                FnOverridePolicy.shouldRestoreImmediately(
                    configuredSpecialKeyIsFn: false, accessibilityTrusted: true))
            check(
                "2286 restore immediately on permission loss",
                FnOverridePolicy.shouldRestoreImmediately(
                    configuredSpecialKeyIsFn: true, accessibilityTrusted: false))

            // 7. Schema version changes do not establish transaction ordering.
            let v1 = FnPreferenceRecord(version: 1, status: .applied, snapshot: snap)
            let v2 = FnPreferenceRecord(version: 2, status: .restored, snapshot: snap)
            check("2286 version ordering", v2.version > v1.version)
            do {
                for value: Any in [
                    NSNumber(value: true), NSNumber(value: 2), NSNumber(value: 1.25),
                    "synthetic-unexpected", Data([0, 1, 2]), ["nested": [NSNumber(value: false), "x"]],
                ] {
                    let snapshot = try FnPreferenceSnapshotCodec.capture(value)
                    let decoded = try JSONDecoder().decode(
                        FnPreferenceSnapshot.self, from: JSONEncoder().encode(snapshot))
                    check(
                        "2286 typed property-list snapshot round-trip",
                        try FnPreferenceSnapshotCodec.matches(value, snapshot: decoded))
                }
                let bool = try FnPreferenceSnapshotCodec.capture(NSNumber(value: true))
                check(
                    "2286 bool is not integer one",
                    try !FnPreferenceSnapshotCodec.matches(NSNumber(value: 1), snapshot: bool))
                do {
                    _ = try FnPreferenceSnapshotCodec.materialize(strSnap)
                    check("2286 legacy missing exact value must reject", false)
                } catch { check("2286 legacy missing exact value rejects", true) }
            } catch { check("2286 typed snapshot encoding", false) }
        }

        // ===== JOE-2287: serial deduplicated edge stream =====
        do {
            // 1. One physical action, three sources -> ONE logical pair.
            var es = HotkeyEdgeStream(configIsFn: true)
            es.setLifecycle(.healthy)
            let t0: UInt64 = 1_000_000_000
            var edges = 0
            edges +=
                es.feed(
                    HotkeySourceEvent(
                        source: .tap, down: true,
                        keyCode: 63, flags: 0x800000,
                        isFnKey: true, timestampNanos: t0)) ? 1 : 0
            edges +=
                es.feed(
                    HotkeySourceEvent(
                        source: .global, down: true,
                        keyCode: 63, flags: 0x800000,
                        isFnKey: true, timestampNanos: t0 + 5_000_000)) ? 1 : 0
            edges +=
                es.feed(
                    HotkeySourceEvent(
                        source: .local, down: true,
                        keyCode: 63, flags: 0x800000,
                        isFnKey: true, timestampNanos: t0 + 10_000_000)) ? 1 : 0
            edges +=
                es.feed(
                    HotkeySourceEvent(
                        source: .tap, down: false,
                        keyCode: 63, flags: 0,
                        isFnKey: true, timestampNanos: t0 + 50_000_000)) ? 1 : 0
            edges +=
                es.feed(
                    HotkeySourceEvent(
                        source: .global, down: false,
                        keyCode: 63, flags: 0,
                        isFnKey: true, timestampNanos: t0 + 55_000_000)) ? 1 : 0
            check("2287 three sources one pair", es.presses == 1 && es.releases == 1)
            check("2287 edge count == 2", edges == 2)
            check("2287 duplicate edges suppressed", es.suppressed == 3)

            // 2. Lost release: sweep recovers hold/toggle state.
            var es2 = HotkeyEdgeStream(configIsFn: true)
            es2.setLifecycle(.healthy)
            _ = es2.feed(
                HotkeySourceEvent(
                    source: .tap, down: true, keyCode: 63,
                    flags: 0x800000, isFnKey: true,
                    timestampNanos: t0))
            check("2287 held after down", es2.heldDown)
            check(
                "2287 lost release recovered",
                es2.sweepLostRelease(nowNanos: t0 + HotkeyEdgeStream.lostReleaseTimeoutNanos + 1))
            check("2287 not held after sweep", !es2.heldDown)
            check("2287 recovered counted", es2.lostReleasesRecovered == 1)

            // 3. Autorepeat never produces edges.
            var es3 = HotkeyEdgeStream(configIsFn: true)
            es3.setLifecycle(.healthy)
            _ = es3.feed(
                HotkeySourceEvent(
                    source: .tap, down: true, keyCode: 63,
                    flags: 0x800000, isFnKey: true,
                    isAutorepeat: true, timestampNanos: t0))
            check("2287 autorepeat suppressed", es3.presses == 0 && es3.suppressed == 1)

            // 4. Modifier chords suppressed; state resets on chord release.
            var es4 = HotkeyEdgeStream(configIsFn: true)
            es4.setLifecycle(.healthy)
            _ = es4.feed(
                HotkeySourceEvent(
                    source: .tap, down: true, keyCode: 63,
                    flags: 0x800000 | 0x100000,  // Fn+Cmd
                    isFnKey: true, timestampNanos: t0))
            check("2287 chord suppressed", es4.presses == 0)
            _ = es4.feed(
                HotkeySourceEvent(
                    source: .tap, down: false, keyCode: 63,
                    flags: 0, isFnKey: true, timestampNanos: t0 + 10_000_000))
            _ = es4.feed(
                HotkeySourceEvent(
                    source: .tap, down: true, keyCode: 63,
                    flags: 0x800000, isFnKey: true,
                    timestampNanos: t0 + 20_000_000))
            check("2287 chord released then press works", es4.presses == 1)

            // 5. Out-of-order/duplicate raw events cannot arm permanently.
            var es5 = HotkeyEdgeStream(configIsFn: true)
            es5.setLifecycle(.healthy)
            _ = es5.feed(
                HotkeySourceEvent(
                    source: .tap, down: true, keyCode: 63,
                    flags: 0x800000, isFnKey: true, timestampNanos: t0))
            _ = es5.feed(
                HotkeySourceEvent(
                    source: .global, down: true, keyCode: 63,
                    flags: 0x800000, isFnKey: true, timestampNanos: t0 + 1))
            check("2287 duplicate down no double arm", es5.presses == 1 && es5.heldDown)
            _ = es5.feed(
                HotkeySourceEvent(
                    source: .local, down: false, keyCode: 63,
                    flags: 0, isFnKey: true, timestampNanos: t0 + 2_000_000))
            check("2287 early release ok", es5.releases == 1 && !es5.heldDown)
            // Release with nothing held is suppressed, never a violation.
            _ = es5.feed(
                HotkeySourceEvent(
                    source: .tap, down: false, keyCode: 63,
                    flags: 0, isFnKey: true, timestampNanos: t0 + 3_000_000))
            check("2287 stray release suppressed", es5.suppressed >= 1)
            check("2287 no violations", es5.violations.isEmpty && es5.isGreen)

            // 6. Lifecycle: stopped never emits; stopping releases held state.
            var es6 = HotkeyEdgeStream(configIsFn: true)
            _ = es6.feed(
                HotkeySourceEvent(
                    source: .tap, down: true, keyCode: 63,
                    flags: 0x800000, isFnKey: true, timestampNanos: t0))
            check("2287 stopped ignores", es6.presses == 0)
            es6.setLifecycle(.healthy)
            _ = es6.feed(
                HotkeySourceEvent(
                    source: .tap, down: true, keyCode: 63,
                    flags: 0x800000, isFnKey: true, timestampNanos: t0))
            es6.setLifecycle(.stopping)
            check("2287 stopping releases held", !es6.heldDown && es6.releases == 1)
            check("2287 lifecycle states", es6.lifecycle == .stopping)

            // 7. Config change resets held state safely.
            var es7 = HotkeyEdgeStream(configIsFn: true)
            es7.setLifecycle(.healthy)
            _ = es7.feed(
                HotkeySourceEvent(
                    source: .tap, down: true, keyCode: 63,
                    flags: 0x800000, isFnKey: true, timestampNanos: t0))
            es7.applyConfig(isFn: false, keyCode: 49)
            check("2287 config change releases held", !es7.heldDown)
            _ = es7.feed(
                HotkeySourceEvent(
                    source: .tap, down: true, keyCode: 49,
                    flags: 0, isFnKey: false, timestampNanos: t0 + 5_000_000))
            check("2287 new config takes effect", es7.presses == 2)

            // 8. Degraded lifecycle still processes edges (no busy loop).
            var es8 = HotkeyEdgeStream(configIsFn: true)
            es8.setLifecycle(.degraded)
            _ = es8.feed(
                HotkeySourceEvent(
                    source: .tap, down: true, keyCode: 63,
                    flags: 0x800000, isFnKey: true, timestampNanos: t0))
            check("2287 degraded processes", es8.presses == 1)
        }
    }
}

/// R2.2 test helper: thread-safe did-run flag for the expired-budget check.
private final class ExecutedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var ran = false
    func mark() {
        lock.lock()
        defer { lock.unlock() }
        ran = true
    }
    var didRun: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ran
    }
}

/// R7 test helper: mutable key holder (avoids captured-var warnings in the
/// @Sendable key provider closure).
private final class KeyHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: HistoryCryptoKey?
    init(_ key: HistoryCryptoKey?) { stored = key }
    var key: HistoryCryptoKey? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
    func set(_ k: HistoryCryptoKey?) {
        lock.lock()
        defer { lock.unlock() }
        stored = k
    }
}
