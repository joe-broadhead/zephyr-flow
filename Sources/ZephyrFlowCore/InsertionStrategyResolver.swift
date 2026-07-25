import Foundation

/// Pure bundle-ID → strategy order. Unit-tested; no AppKit.
public enum InsertionStrategyResolver: Sendable {
    public static func strategies(
        bundleID: String?,
        role: String?,
        mode: InsertionMode
    ) -> [InsertionStrategy] {
        if isSecureRole(role) {
            return [.copyOnly]
        }

        switch mode {
        case .alwaysCopy:
            return [.copyOnly]
        case .alwaysPaste:
            return [.clipboardPaste, .copyOnly]
        case .automatic:
            break
        }

        let id = bundleID ?? ""

        if isTerminal(id) {
            return [.terminalPaste, .clipboardPaste, .copyOnly]
        }
        if isEditorIDE(id) {
            return [.clipboardPaste, .axSelectedText, .axValue, .copyOnly]
        }
        if isElectronOrBrowser(id) {
            return [.clipboardPaste, .axSelectedText, .axValue, .copyOnly]
        }

        // Default: paste first (after focus restore), then AX, then copy
        return [.clipboardPaste, .axSelectedText, .axValue, .copyOnly]
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
