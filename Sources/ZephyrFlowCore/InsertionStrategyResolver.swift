import Foundation

/// Pure bundle-ID → strategy order, backed by the evidence adapter registry
/// (JOE-2271). No `contains("chrome")` guesses: unknown apps get the
/// conservative default. Unit-tested; no AppKit.
public enum InsertionStrategyResolver: Sendable {
    public static func strategies(
        bundleID: String?,
        role: String?,
        mode: InsertionMode,
        copyOnlyOverrides: Set<String> = []
    ) -> [InsertionStrategy] {
        if isSecureRole(role) {
            return [.copyOnly]
        }

        switch mode {
        case .alwaysCopy:
            return [.copyOnly]
        case .alwaysPaste:
            // Review B4v2: paste mode never falls back to an automatic copy.
            return [.clipboardPaste]
        case .automatic:
            break
        }

        // Local user override: copy-only for problematic apps.
        if let bundleID, copyOnlyOverrides.contains(bundleID) {
            return [.copyOnly]
        }

        // Evidence-backed adapter registry (exact bundle identity).
        let adapter = InsertionAdapterRegistry.current.adapter(
            forBundle: bundleID, role: role, appVersion: nil, macOSVersion: nil)
        return adapter.strategies
    }

    /// Resolve the adapter for a bundle (content-free identity for UI/logs).
    public static func adapter(forBundle bundleID: String?, role: String?) -> InsertionAdapter {
        InsertionAdapterRegistry.current.adapter(
            forBundle: bundleID, role: role, appVersion: nil, macOSVersion: nil)
    }

    public static func isSecureRole(_ role: String?) -> Bool {
        guard let role else { return false }
        return role == "AXSecureTextField" || role.contains("SecureText")
    }

    public static func isTerminal(_ bundleID: String) -> Bool {
        let terminals: Set<String> = [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "dev.warp.Warp-Stable",
            "dev.warp.Warp",
            "co.zeit.hyper",
            "com.github.wez.wezterm",
        ]
        return terminals.contains(bundleID)
    }

    public static func isEditorIDE(_ bundleID: String) -> Bool {
        if bundleID == "com.microsoft.VSCode" || bundleID == "com.apple.dt.Xcode" {
            return true
        }
        if bundleID.hasPrefix("com.microsoft.VSCode") { return true }
        if bundleID.contains("VisualStudioCode") { return true }
        return false
    }

    public static func isElectronOrBrowser(_ bundleID: String) -> Bool {
        let known: Set<String> = [
            "com.tinyspeck.slackmacgap",
            "company.thebrowser.Browser",
            "com.apple.Safari",
            "com.google.Chrome",
            "org.mozilla.firefox",
            "com.microsoft.edgemac",
            "notion.id",
            "com.figma.Desktop",
            "com.linear",
        ]
        if known.contains(bundleID) { return true }
        if bundleID.contains("slack") { return true }
        if bundleID.contains("chrome") { return true }
        return false
    }
}
