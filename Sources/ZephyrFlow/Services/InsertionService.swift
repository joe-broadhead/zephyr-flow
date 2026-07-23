import Foundation
import AppKit
import ApplicationServices
import ZephyrFlowCore

actor InsertionService: InsertionServiceProtocol {
    static let shared = InsertionService()

    /// Protocol entry — defaults to balanced strategy.
    func insert(_ text: String) async -> InsertionResult {
        await insert(text, preferPaste: true)
    }

    /// - Parameter preferPaste: When true (after focus restore), try Cmd+V first.
    func insert(_ text: String, preferPaste: Bool) async -> InsertionResult {
        guard !text.isEmpty else { return .failed("Empty text") }
        ZFLog.info("Insert request len=\(text.count) ax=\(AXIsProcessTrusted()) preferPaste=\(preferPaste)")

        // Password / secure fields – never inject, copy instead
        if AXIsProcessTrusted(), await isSecureFieldFocused() {
            await copyToClipboard(text)
            ZFLog.info("Secure field — copied")
            return .copiedToClipboard
        }

        if preferPaste {
            // 1) Clipboard + Cmd+V into restored frontmost app
            if await pasteViaClipboard(text) {
                ZFLog.info("Inserted via paste")
                return .pasted
            }
            // 2) AX fallback
            if AXIsProcessTrusted(), await insertViaAccessibility(text) {
                ZFLog.info("Inserted via AX (after paste fail)")
                return .inserted
            }
        } else {
            if AXIsProcessTrusted(), await insertViaAccessibility(text) {
                ZFLog.info("Inserted via AX")
                return .inserted
            }
            if await pasteViaClipboard(text) {
                ZFLog.info("Inserted via paste")
                return .pasted
            }
        }

        await copyToClipboard(text)
        ZFLog.info("Fell back to clipboard only")
        return .copiedToClipboard
    }

    // MARK: - Accessibility path

    private func insertViaAccessibility(_ text: String) async -> Bool {
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

        // Refuse to "insert" into our own UI
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success, pid == getpid() {
            ZFLog.info("AX: focused element is our own process — skip")
            return false
        }

        // Log role for debugging
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String {
            ZFLog.info("AX focused role=\(role) pid=\(pid)")
        }

        // Prefer selected text attribute (inserts / replaces selection)
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
        }

        // Fallback: value + selected range splicing
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
        // changeCount lets us detect if the user copied something else mid-restore.
        let changeBefore = pasteboard.changeCount

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return false }
        let ourChange = pasteboard.changeCount

        try? await Task.sleep(nanoseconds: 50_000_000)

        guard postCommandV() else {
            restorePasteboard(saved)
            return false
        }

        // Let the target app consume the paste
        try? await Task.sleep(nanoseconds: 250_000_000)

        let savedCopy = saved
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            let pb = NSPasteboard.general
            // Only restore if clipboard still holds what we posted (user didn't copy).
            // changeCount == ourChange means nothing else wrote; string match is belt-and-suspenders.
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
        // 0x09 = kVK_ANSI_V
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

    // MARK: - Secure field detection

    private func isSecureFieldFocused() async -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success,
              let focused = focusedRef,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return false
        }
        let element = unsafeBitCast(focused, to: AXUIElement.self)

        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String {
            if role == "AXSecureTextField" { return true }
            var subroleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef) == .success,
               let subrole = subroleRef as? String,
               subrole == (kAXSecureTextFieldSubrole as String) || subrole == "AXSecureTextField" {
                return true
            }
        }
        return false
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
