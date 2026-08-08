import Foundation

// JOE-2271: evidence-backed insertion adapter registry.
//
// Insertion behavior is a versioned capability contract matched by exact
// bundle identity (+ optional role/subrole, app-version range, macOS range) —
// never broad `contains("chrome")`-style guesses. Unknown apps use the
// conservative default. AppKit-free and unit-testable.

/// How an adapter confirms an insertion actually happened.
public enum AdapterVerification: String, Codable, Sendable, Equatable {
    /// Post-write re-read of the selection/value (AX paths).
    case postWriteReRead
    /// No confirmation available (paste events are inherently unverified).
    case none
}

/// Named qualification record for a set of exact bundle identities.
public struct InsertionAdapter: Sendable, Equatable {
    /// Stable, versioned adapter id (surfaced in UI/support bundle, no content).
    public let id: String
    /// Exact bundle identities this adapter applies to (empty = default).
    public let bundleIDs: Set<String>
    /// Optional role/subrole filter; nil = any role.
    public let roles: Set<String>?
    /// Optional app-version range (semver-ish strings; exact string compare
    /// per component). nil = any version.
    public let appVersionRange: ClosedRange<String>?
    /// Optional minimum macOS version; nil = any.
    public let macOSMin: String?
    /// Permitted strategies in preferred order.
    public let strategies: [InsertionStrategy]
    /// Settle/completion condition (replaces fixed delay assumptions).
    public let settleNanos: UInt64
    /// Verification method for confirmed success.
    public let verification: AdapterVerification
    /// Known limitations (content-free).
    public let limitations: [String]
    /// Evidence reference (doc id / report path) backing this adapter.
    public let evidenceReference: String
    /// Whether strategy failure may cascade to the NEXT strategy in the list.
    /// False => first failure aborts (never cascades into a less-safe path).
    public let allowsStrategyCascade: Bool

    public init(
        id: String, bundleIDs: Set<String>, roles: Set<String>?,
        appVersionRange: ClosedRange<String>?, macOSMin: String?,
        strategies: [InsertionStrategy], settleNanos: UInt64,
        verification: AdapterVerification, limitations: [String],
        evidenceReference: String, allowsStrategyCascade: Bool
    ) {
        self.id = id
        self.bundleIDs = bundleIDs
        self.roles = roles
        self.appVersionRange = appVersionRange
        self.macOSMin = macOSMin
        self.strategies = strategies
        self.settleNanos = settleNanos
        self.verification = verification
        self.limitations = limitations
        self.evidenceReference = evidenceReference
        self.allowsStrategyCascade = allowsStrategyCascade
    }

    /// Conservative default: no whole-value mutation, paste unverified,
    /// AX selected-text preferred over paste, explicit copy last.
    public static let conservativeDefault = InsertionAdapter(
        id: "default.v1",
        bundleIDs: [],
        roles: nil,
        appVersionRange: nil,
        macOSMin: nil,
        strategies: [.clipboardPaste, .axSelectedText, .copyOnly],
        settleNanos: 16_000_000,
        verification: .none,
        limitations: ["paste events are unverified", "no whole-value AX mutation"],
        evidenceReference: "docs/development/evidence/JOE-2271",
        allowsStrategyCascade: true)

    /// Whether an exact bundle matches this adapter (plus optional filters).
    public func matches(
        bundleID: String?, role: String?, appVersion: String?,
        macOSVersion: String?
    ) -> Bool {
        guard let bundleID, bundleIDs.contains(bundleID) else { return false }
        if let roles, let role, !roles.contains(role) { return false }
        if let appVersionRange, let appVersion,
            !Self.version(appVersion, within: appVersionRange)
        {
            return false
        }
        if let macOSMin, let macOSVersion,
            !Self.version(macOSVersion, atLeast: macOSMin)
        {
            return false
        }
        return true
    }

    /// Next strategy after the given one (nil when cascade is not permitted
    /// or the list is exhausted) — deterministic, unit-testable.
    public func nextStrategy(after strategy: InsertionStrategy) -> InsertionStrategy? {
        guard allowsStrategyCascade,
            let idx = strategies.firstIndex(of: strategy),
            idx + 1 < strategies.count
        else { return nil }
        return strategies[idx + 1]
    }

    private static func version(_ v: String, within range: ClosedRange<String>) -> Bool {
        let lower = range.lowerBound.compare(v, options: .numeric) != .orderedDescending
        let upper = range.upperBound.compare(v, options: .numeric) != .orderedAscending
        return lower && upper
    }

    private static func version(_ v: String, atLeast min: String) -> Bool {
        v.compare(min, options: .numeric) != .orderedAscending
    }
}

/// Versioned registry (drift is visible in tests/docs).
public struct InsertionAdapterRegistry: Sendable {
    public let version: Int
    public let adapters: [InsertionAdapter]

    public init(version: Int, adapters: [InsertionAdapter]) {
        self.version = version
        self.adapters = adapters
    }

    /// Current registry — exact-bundle entries only (guesses removed).
    public static let current = InsertionAdapterRegistry(
        version: 1,
        adapters: [
            // Terminals: paste-first (terminal paste), unverified, longer settle.
            InsertionAdapter(
                id: "terminal.v1",
                bundleIDs: [
                    "com.apple.Terminal", "com.googlecode.iterm2",
                    "dev.warp.Warp-Stable", "dev.warp.Warp",
                    "co.zeit.hyper", "com.github.wez.wezterm",
                ],
                roles: nil, appVersionRange: nil, macOSMin: nil,
                strategies: [.terminalPaste, .clipboardPaste, .copyOnly],
                settleNanos: 40_000_000,
                verification: .none,
                limitations: ["paste unverified in terminals"],
                evidenceReference: "docs/development/evidence/JOE-2271",
                allowsStrategyCascade: true),
            // Editors/IDEs: paste + AX selected-text + (qualified) value.
            InsertionAdapter(
                id: "editor.v1",
                bundleIDs: ["com.microsoft.VSCode", "com.apple.dt.Xcode"],
                roles: nil, appVersionRange: nil, macOSMin: nil,
                strategies: [.clipboardPaste, .axSelectedText, .axValue, .copyOnly],
                settleNanos: 16_000_000,
                verification: .postWriteReRead,
                limitations: ["axValue requires explicit adapter qualification (JOE-2270)"],
                evidenceReference: "docs/development/evidence/JOE-2271",
                allowsStrategyCascade: true),
            // Browsers: paste + AX selected-text only — never whole-value AX.
            InsertionAdapter(
                id: "browser.v1",
                bundleIDs: [
                    "com.apple.Safari", "com.google.Chrome",
                    "org.mozilla.firefox", "com.microsoft.edgemac",
                ],
                roles: nil, appVersionRange: nil, macOSMin: nil,
                strategies: [.clipboardPaste, .axSelectedText, .copyOnly],
                settleNanos: 16_000_000,
                verification: .postWriteReRead,
                limitations: ["no axValue in browsers", "paste unverified"],
                evidenceReference: "docs/development/evidence/JOE-2271",
                allowsStrategyCascade: true),
            // Electron/browser-shell apps: explicit exact entries (no guesses).
            InsertionAdapter(
                id: "electron-shell.v1",
                bundleIDs: [
                    "com.tinyspeck.slackmacgap", "notion.id",
                    "com.figma.Desktop", "com.linear",
                ],
                roles: nil, appVersionRange: nil, macOSMin: nil,
                strategies: [.clipboardPaste, .axSelectedText, .copyOnly],
                settleNanos: 16_000_000,
                verification: .postWriteReRead,
                limitations: ["shell apps vary; paste unverified"],
                evidenceReference: "docs/development/evidence/JOE-2271",
                allowsStrategyCascade: true),
        ])

    /// Resolve the adapter for a bundle: exact match or the conservative
    /// default. Never guesses.
    public func adapter(
        forBundle bundleID: String?, role: String?,
        appVersion: String?, macOSVersion: String?
    ) -> InsertionAdapter {
        guard let bundleID else { return .conservativeDefault }
        for adapter in adapters
        where adapter.matches(
            bundleID: bundleID, role: role,
            appVersion: appVersion,
            macOSVersion: macOSVersion)
        {
            return adapter
        }
        return .conservativeDefault
    }

    /// Registry hygiene: no bundle appears in two adapters, no duplicate ids.
    public var hasOverlaps: Bool {
        var seenBundles = Set<String>()
        var seenIDs = Set<String>()
        for adapter in adapters {
            if seenIDs.contains(adapter.id) { return true }
            seenIDs.insert(adapter.id)
            for bundle in adapter.bundleIDs {
                if seenBundles.contains(bundle) { return true }
                seenBundles.insert(bundle)
            }
        }
        return false
    }
}

/// Adapter identity reported to UI/support bundle (content-free).
public struct AdapterIdentity: Sendable, Equatable {
    public let adapterID: String
    public let registryVersion: Int
    public let strategy: InsertionStrategy?
    public let verification: AdapterVerification
    public let confidence: TargetConfidence

    public init(
        adapterID: String, registryVersion: Int, strategy: InsertionStrategy?,
        verification: AdapterVerification, confidence: TargetConfidence
    ) {
        self.adapterID = adapterID
        self.registryVersion = registryVersion
        self.strategy = strategy
        self.verification = verification
        self.confidence = confidence
    }
}
