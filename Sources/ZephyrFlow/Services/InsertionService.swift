import Foundation
import AppKit
import ApplicationServices
import ZephyrFlowCore

actor InsertionService: InsertionServiceProtocol {
    static let shared = InsertionService()

    func insert(_ text: String) async -> InsertionResult {
        await insert(text, preferPaste: true, mode: .automatic, targetBundleID: nil)
    }

    /// - Parameters:
    ///   - preferPaste: Legacy hint when mode is automatic (after focus restore).
    ///   - mode: User insertion mode from settings.
    ///   - targetBundleID: Bundle id captured before panel focus steal.
    func insert(
        _ text: String,
        preferPaste: Bool,
        mode: InsertionMode = .automatic,
        targetBundleID: String? = nil
    ) async -> InsertionResult {
        guard !text.isEmpty else { return .failed("Empty text") }

        let role = await focusedRole()
        let frontBundle = await frontmostBundleID()
        let bundle = targetBundleID ?? frontBundle
        ZFLog.info(
            "Insert request len=\(text.count) ax=\(AXIsProcessTrusted()) mode=\(mode.rawValue) bundle=\(bundle ?? "nil") role=\(role ?? "nil")"
        )

        let secureFocused = AXIsProcessTrusted() ? await isSecureFieldFocused() : false
        if InsertionStrategyResolver.isSecureRole(role) || secureFocused {
            await copyToClipboard(text)
            ZFLog.info("insert strategy=copyOnly bundle=\(bundle ?? "nil") result=secure")
            return .copiedToClipboard
        }

        var strategies = InsertionStrategyResolver.strategies(
            bundleID: bundle,
            role: role,
            mode: mode
        )
        // Honor preferPaste=false by trying AX before paste when automatic.
        if mode == .automatic, !preferPaste {
            strategies = strategies.filter { $0 != .clipboardPaste && $0 != .terminalPaste }
                + strategies.filter { $0 == .clipboardPaste || $0 == .terminalPaste }
        }

        for strategy in strategies {
            switch strategy {
            case .copyOnly:
                await copyToClipboard(text)
                ZFLog.info("insert strategy=copyOnly bundle=\(bundle ?? "nil") result=ok")
                return .copiedToClipboard

            case .clipboardPaste, .terminalPaste:
                let settle: UInt64 = InsertionStrategyResolver.isTerminal(bundle ?? "")
                    ? 40_000_000 : 16_000_000
                try? await Task.sleep(nanoseconds: settle)
                if await pasteViaClipboard(text) {
                    ZFLog.info("insert strategy=\(strategy.rawValue) bundle=\(bundle ?? "nil") result=ok")
                    return .pasted
                }
                ZFLog.info("insert strategy=\(strategy.rawValue) bundle=\(bundle ?? "nil") result=fail")

            case .axSelectedText:
                guard AXIsProcessTrusted() else { continue }
                if await insertViaAccessibility(text, allowValueFallback: false) {
                    ZFLog.info("insert strategy=axSelectedText bundle=\(bundle ?? "nil") result=ok")
                    return .inserted
                }
                ZFLog.info("insert strategy=axSelectedText bundle=\(bundle ?? "nil") result=fail")

            case .axValue:
                guard AXIsProcessTrusted() else { continue }
                if await insertViaAccessibility(text, allowValueFallback: true) {
                    ZFLog.info("insert strategy=axValue bundle=\(bundle ?? "nil") result=ok")
                    return .inserted
                }
                ZFLog.info("insert strategy=axValue bundle=\(bundle ?? "nil") result=fail")
            }
        }

        await copyToClipboard(text)
        ZFLog.info("insert strategy=copyOnly bundle=\(bundle ?? "nil") result=fallback")
        return .copiedToClipboard
    }

    // MARK: - Accessibility path

    private func insertViaAccessibility(_ text: String, allowValueFallback: Bool) async -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard focusedResult == .success, let focused = focusedRef,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            ZFLog.info("AX: no focused element (\(focusedResult.rawValue))")
            return false
        }
        let element = unsafeBitCast(focused, to: AXUIElement.self)

        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success, pid == getpid() {
            ZFLog.info("AX: focused element is our own process — skip")
            return false
        }

        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String {
            ZFLog.info("AX focused role=\(role) pid=\(pid)")
            if InsertionStrategyResolver.isSecureRole(role) { return false }
        }

        var selectedRef: CFTypeRef?
        let hasSelected = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedRef
        ) == .success

        if hasSelected {
            let setResult = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextAttribute as CFString,
                text as CFTypeRef
            )
            if setResult == .success {
                return true
            }
            ZFLog.info("AX set selectedText failed \(setResult.rawValue)")
            if !allowValueFallback { return false }
        } else if !allowValueFallback {
            return false
        }

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &valueRef
        ) == .success,
              let current = valueRef as? String else {
            return false
        }

        var rangeRef: CFTypeRef?
        var insertionIndex = (current as NSString).length
        var selectionLength = 0
        if AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        ) == .success,
           let rangeValue = rangeRef,
           CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            var cfRange = CFRange(location: 0, length: 0)
            let axValue = unsafeBitCast(rangeValue, to: AXValue.self)
            if AXValueGetValue(axValue, .cfRange, &cfRange) {
                insertionIndex = max(0, cfRange.location)
                selectionLength = max(0, cfRange.length)
            }
        }

        let nsCurrent = current as NSString
        let safeLoc = min(insertionIndex, nsCurrent.length)
        let safeLen = min(selectionLength, nsCurrent.length - safeLoc)
        let replaceRange = NSRange(location: safeLoc, length: safeLen)
        let newValue = nsCurrent.replacingCharacters(in: replaceRange, with: text)
        let setVal = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            newValue as CFTypeRef
        )
        guard setVal == .success else { return false }

        var newRange = CFRange(location: safeLoc + (text as NSString).length, length: 0)
        if let axRange = AXValueCreate(.cfRange, &newRange) {
            AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                axRange
            )
        }
        return true
    }

    // MARK: - Clipboard paste path

    private func pasteViaClipboard(_ text: String) async -> Bool {
        let pasteboard = NSPasteboard.general

        let saved: [(NSPasteboard.PasteboardType, Data)] = (pasteboard.types ?? []).compactMap { type in
            guard let data = pasteboard.data(forType: type) else { return nil }
            return (type, data)
        }
        let changeBefore = pasteboard.changeCount

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return false }
        let ourChange = pasteboard.changeCount

        try? await Task.sleep(nanoseconds: 50_000_000)

        guard postCommandV() else {
            restorePasteboard(saved)
            return false
        }

        try? await Task.sleep(nanoseconds: 250_000_000)

        let savedCopy = saved
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            let pb = NSPasteboard.general
            if pb.changeCount == ourChange || pb.string(forType: .string) == text {
                self.restorePasteboard(savedCopy)
                ZFLog.debug("Clipboard restored (prior changeCount=\(changeBefore))")
            } else {
                ZFLog.debug("Clipboard left alone — user or app changed it")
            }
        }

        return true
    }

    private nonisolated func postCommandV() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    // MARK: - Focus helpers

    private func frontmostBundleID() async -> String? {
        await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
    }

    private func focusedRole() async -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success,
              let focused = focusedRef,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return nil
        }
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success else {
            return nil
        }
        return roleRef as? String
    }

    private func isSecureFieldFocused() async -> Bool {
        InsertionStrategyResolver.isSecureRole(await focusedRole())
    }

    // MARK: - Clipboard helpers

    private func copyToClipboard(_ text: String) async {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private nonisolated func restorePasteboard(_ items: [(NSPasteboard.PasteboardType, Data)]) {
        guard !items.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        for (type, data) in items {
            pb.setData(data, forType: type)
        }
    }
}
