import Foundation
import AppKit
import ApplicationServices
import ZephyrFlowCore

actor InsertionService: InsertionServiceProtocol {
    static let shared = InsertionService()

    func insert(_ text: String) async -> InsertionOutcome {
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
        targetBundleID: String? = nil,
        sensitivity: SessionSensitivity = .normal
    ) async -> InsertionOutcome {
        guard !text.isEmpty else { return .failed("Empty text") }
        // JOE-2259: domain rejection of automatic insertion for secure/unknown
        // sessions — cannot be bypassed by calling this service directly.
        guard SensitiveSessionPolicy.autoPasteAllowed(sensitivity: sensitivity) else {
            ZFLog.info("insert rejected by sensitivity policy sensitivity=\(sensitivity.rawValue)")
            return .failed("Sensitivity policy blocks automatic insertion")
        }

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
            return .explicitlyCopiedByUser
        }

        var strategies = InsertionStrategyResolver.strategies(
            bundleID: bundle,
            role: role,
            mode: mode
        )
        // Honor preferPaste=false by trying AX before paste when automatic.
        // Keep copyOnly strictly last so paste remains a fallback.
        if mode == .automatic, !preferPaste {
            let copyTail = strategies.filter { $0 == .copyOnly }
            let paste = strategies.filter { $0 == .clipboardPaste || $0 == .terminalPaste }
            let ax = strategies.filter {
                $0 != .copyOnly && $0 != .clipboardPaste && $0 != .terminalPaste
            }
            strategies = ax + paste + copyTail
        }

        for strategy in strategies {
            switch strategy {
            case .copyOnly:
                await copyToClipboard(text)
                ZFLog.info("insert strategy=copyOnly bundle=\(bundle ?? "nil") result=ok")
                return .explicitlyCopiedByUser

            case .clipboardPaste, .terminalPaste:
                let settle: UInt64 = InsertionStrategyResolver.isTerminal(bundle ?? "")
                    ? 40_000_000 : 16_000_000
                try? await Task.sleep(nanoseconds: settle)
                let paste = await pasteViaClipboard(text)
                switch paste {
                case .pasted:
                    ZFLog.info("insert strategy=\(strategy.rawValue) bundle=\(bundle ?? "nil") result=posted")
                    // Cmd-V was posted but the target never confirmed receipt —
                    // never describe this as verified insertion.
                    return .eventPostedUnverified(strategy: strategy, warnings: [.noPostWriteVerification])
                case .notRestoredBecauseChanged:
                    ZFLog.info("insert strategy=\(strategy.rawValue) clipboard left changed")
                    return .clipboardNotRestoredBecauseChanged
                case .restoreFailed:
                    ZFLog.info("insert strategy=\(strategy.rawValue) clipboard restore failed")
                    return .clipboardRestoreFailed
                case .failed:
                    ZFLog.info("insert strategy=\(strategy.rawValue) bundle=\(bundle ?? "nil") result=fail")
                }

            case .axSelectedText, .axValue:
                guard AXIsProcessTrusted() else { continue }
                let allowFallback = strategy == .axValue
                let axOutcome = await insertViaAccessibility(text, allowValueFallback: allowFallback)
                switch axOutcome {
                case .verified:
                    ZFLog.info("insert strategy=\(strategy.rawValue) bundle=\(bundle ?? "nil") result=verified")
                    return .verifiedInserted(strategy: strategy,
                                             evidence: .postWriteSelectionReRead,
                                             warnings: [])
                case .unverified:
                    ZFLog.info("insert strategy=\(strategy.rawValue) bundle=\(bundle ?? "nil") result=unverified")
                    return .eventPostedUnverified(strategy: strategy, warnings: [.noPostWriteVerification])
                case .deadlineExceeded:
                    ZFLog.info("insert strategy=\(strategy.rawValue) bundle=\(bundle ?? "nil") result=deadline")
                    return .deadlineExceeded
                case .failed:
                    ZFLog.info("insert strategy=\(strategy.rawValue) bundle=\(bundle ?? "nil") result=fail")
                }
            }
        }

        await copyToClipboard(text)
        ZFLog.info("insert strategy=copyOnly bundle=\(bundle ?? "nil") result=fallback")
        return .explicitlyCopiedByUser
    }

    // MARK: - Accessibility path

    private enum AXInsertResult: Sendable {
        case verified
        case unverified
        case failed
        case deadlineExceeded
    }

    private static let textLikeRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSecureTextField",
        "AXTextView", "AXSearchField",
    ]

    private func insertViaAccessibility(_ text: String, allowValueFallback: Bool) async -> AXInsertResult {
        // JOE-2270: consult the deterministic write policy before ANY write.
        // Re-resolve capability + selection immediately before the write, then
        // route the actual AX mutation through the bounded runner.
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
            return .failed
        }
        let element = unsafeBitCast(focused, to: AXUIElement.self)

        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success, pid == getpid() {
            ZFLog.info("AX: focused element is our own process — skip")
            return .failed
        }

        // Capability flags (fresh, content-free).
        let role = axString(element, kAXRoleAttribute)
        let subrole = axString(element, kAXSubroleAttribute)
        let isSecure = role == "AXSecureTextField" || InsertionStrategyResolver.isSecureRole(role)
        var settableFlag = DarwinBoolean(false)
        let settable = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settableFlag) == .success
            && settableFlag.boolValue
        let editable = role.map { InsertionService.textLikeRoles.contains($0) } ?? false
        let enabled = axBool(element, kAXEnabledAttribute)
        let capability = AxElementCapability(settable: settable, editable: editable,
                                             enabled: enabled, isSecure: isSecure,
                                             role: role, subrole: subrole)

        // Current selection (positional only) + current value length.
        let selection = axSelectionRange(element)
        let currentUTF16Length = axString(element, kAXValueAttribute).map { ($0 as NSString).length }

        // Qualification from the (versioned, empty-by-default) adapter registry.
        let bundle = await frontmostBundleID()
        let qualification = AxValueAdapterRegistry.default.qualification(
            forBundle: bundle, role: role)

        let plan = AxWritePolicy.plan(capability: capability,
                                      selection: selection,
                                      currentUTF16Length: currentUTF16Length,
                                      text: text,
                                      qualification: qualification)
        switch plan {
        case .rejected(let reason):
            ZFLog.info("AX write rejected reason=\(reason.rawValue) role=\(role ?? "nil")")
            if reason == .secure { return .failed }
            return .failed
        case .selectedTextReplacement, .rangeMutation:
            break
        }

        // Bounded write: a hung target must not block the session.
        let startNanos = DispatchTime.now().uptimeNanoseconds
        let writeResult = await AxBoundedRunner.run(
            deadlineNanosAhead: 1_500_000_000,
            startedAtNanos: startNanos,
            nowNanos: { DispatchTime.now().uptimeNanoseconds }
        ) { [element] in
            self.performAXWrite(element: element, text: text, plan: plan)
        }
        guard let outcome = writeResult.value else {
            return .deadlineExceeded
        }
        guard outcome.rawValue == 0 else {
            let mapped = AxErrorOutcome.map(rawValue: outcome.rawValue)
            ZFLog.info("AX write failed code=\(outcome.rawValue) mapped=\(mapped.rawValue)")
            return .failed
        }

        // Post-write verification (bounded re-read, in-memory compare only).
        let verifyStart = DispatchTime.now().uptimeNanoseconds
        let verifyResult = await AxBoundedRunner.run(
            deadlineNanosAhead: 1_500_000_000,
            startedAtNanos: verifyStart,
            nowNanos: { DispatchTime.now().uptimeNanoseconds }
        ) { [element] in
            self.axString(element, kAXSelectedTextAttribute)
        }
        guard let verifiedText = verifyResult.value else {
            return .unverified
        }
        if verifiedText == text {
            // Caret update only after verified mutation (bounded).
            _ = await AxBoundedRunner.run(
                deadlineNanosAhead: 1_500_000_000,
                startedAtNanos: DispatchTime.now().uptimeNanoseconds,
                nowNanos: { DispatchTime.now().uptimeNanoseconds }
            ) { [element] in
                self.placeCaret(element: element, afterInserting: text, plan: plan)
            }
            return .verified
        }
        return .unverified
    }

    // MARK: - AX primitives (JOE-2270)

    /// Synchronous AX mutation; runs on the bounded runner's thread.
    private nonisolated func performAXWrite(element: AXUIElement, text: String, plan: AxWritePlan) -> AXError {
        switch plan {
        case .selectedTextReplacement:
            return AXUIElementSetAttributeValue(
                element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        case .rangeMutation(let range, _):
            guard let current = axString(element, kAXValueAttribute) else { return .failure }
            let ns = current as NSString
            let loc = min(max(0, range.location), ns.length)
            let len = min(max(0, range.length), ns.length - loc)
            let newValue = ns.replacingCharacters(in: NSRange(location: loc, length: len), with: text)
            return AXUIElementSetAttributeValue(
                element, kAXValueAttribute as CFString, newValue as CFTypeRef)
        case .rejected:
            return .failure
        }
    }

    /// Positional caret placement (only after a verified mutation).
    private nonisolated func placeCaret(element: AXUIElement, afterInserting text: String, plan: AxWritePlan) {
        let insertionIndex: Int
        switch plan {
        case .selectedTextReplacement:
            guard let current = axString(element, kAXValueAttribute) else { return }
            insertionIndex = (current as NSString).length
        case .rangeMutation(let range, _):
            insertionIndex = range.location + (text as NSString).length
        case .rejected:
            return
        }
        var newRange = CFRange(location: insertionIndex, length: 0)
        if let axRange = AXValueCreate(.cfRange, &newRange) {
            AXUIElementSetAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString, axRange)
        }
    }

    private nonisolated func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private nonisolated func axBool(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return false }
        return value as? Bool ?? false
    }

    /// Positional AXSelectedTextRange as AxSelection (never field content).
    private nonisolated func axSelectionRange(_ element: AXUIElement) -> AxSelection? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = rangeRef, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var cfRange = CFRange(location: 0, length: 0)
        let axValue = unsafeBitCast(rangeValue, to: AXValue.self)
        guard AXValueGetValue(axValue, .cfRange, &cfRange) else { return nil }
        return AxSelection(location: max(0, cfRange.location), length: max(0, cfRange.length))
    }

// MARK: - Clipboard paste path

    private enum ClipboardPasteResult: Sendable {
        case pasted
        case notRestoredBecauseChanged
        case restoreFailed
        case failed
    }

    private func pasteViaClipboard(_ text: String) async -> ClipboardPasteResult {
        let pasteboard = NSPasteboard.general

        let saved: [(NSPasteboard.PasteboardType, Data)] = (pasteboard.types ?? []).compactMap { type in
            guard let data = pasteboard.data(forType: type) else { return nil }
            return (type, data)
        }
        let changeBefore = pasteboard.changeCount

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return .failed }
        let ourChange = pasteboard.changeCount

        try? await Task.sleep(nanoseconds: 50_000_000)

        guard postCommandV() else {
            restorePasteboard(saved)
            return .failed
        }

        try? await Task.sleep(nanoseconds: 250_000_000)

        // Await clipboard restoration so the outcome is typed and controlled:
        // the target received the paste event, and we restore our prior
        // clipboard content unless the user/app changed it meanwhile.
        try? await Task.sleep(nanoseconds: 400_000_000)
        let pb = NSPasteboard.general
        if pb.changeCount == ourChange || pb.string(forType: .string) == text {
            restorePasteboard(saved)
            let restored = pb.changeCount != ourChange || saved.isEmpty
            if !restored {
                ZFLog.debug("Clipboard restore failed (prior changeCount=\(changeBefore))")
                return .restoreFailed
            }
            ZFLog.debug("Clipboard restored (prior changeCount=\(changeBefore))")
            return .pasted
        } else {
            ZFLog.debug("Clipboard left alone — user or app changed it")
            return .notRestoredBecauseChanged
        }
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
