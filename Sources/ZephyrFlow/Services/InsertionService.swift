import AppKit
import ApplicationServices
import Foundation
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
        sensitivity: SessionSensitivity = .normal,
        sessionID: SessionID? = nil,
        copyOnlyOverrides: Set<String> = [],
        validatedElement: TargetSnapshot.ElementIdentity? = nil,
        validatedPid: Int32? = nil,
        validatedWindowID: UInt32? = nil,
        lease: TargetLease? = nil
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
        let validatedLease = lease
        ZFLog.info(
            "Insert request len=\(text.count) ax=\(AXIsProcessTrusted()) mode=\(mode.rawValue) bundle=\(bundle ?? "nil") role=\(role ?? "nil")"
        )

        // Review B4v2: when AX is revoked we cannot establish sensitivity or
        // exact identity — fail closed (unknown) rather than proceed.
        guard AXIsProcessTrusted() else {
            ZFLog.info("insert blocked — Accessibility revoked (sensitivity unknown)")
            return .targetUnknown
        }
        let secureFocused = await isSecureFieldFocused()
        if InsertionStrategyResolver.isSecureRole(role) || secureFocused {
            // Review R9: never write the clipboard automatically for a secure
            // field. The user may copy explicitly from the review panel, and
            // only THAT action may produce .explicitlyCopiedByUser.
            ZFLog.info("insert secure target — automatic clipboard blocked bundle=\(bundle ?? "nil")")
            return .secureTarget
        }

        // Review R2.1: target validation and mutation must be one transaction
        // against the same resolved element identity. We re-check the focused
        // role + sensitivity immediately before EVERY side-effecting path
        // (paste / copy / AX), so a focus switch after validation cannot cause
        // insertion into a changed or secure target. Where stable element
        // identity is unavailable, the AX path refuses automatic insertion
        // (see insertViaAccessibility).

        let adapter = InsertionStrategyResolver.adapter(forBundle: bundle, role: role)
        var strategies = InsertionStrategyResolver.strategies(
            bundleID: bundle,
            role: role,
            mode: mode,
            copyOnlyOverrides: copyOnlyOverrides
        )
        ZFLog.info(
            "adapter id=\(adapter.id) version=\(InsertionAdapterRegistry.current.version) strategies=\(strategies.map { $0.rawValue }.joined(separator: ","))"
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
                // Review R9: copy-only MODE is an automatic write, not an
                // explicit per-action copy. Distinct outcome: non-success, no
                // history retention, review shown so the user confirms.
                await copyToClipboard(text)
                ZFLog.info("insert strategy=copyOnly bundle=\(bundle ?? "nil") result=automaticCopy")
                return .automaticCopy

            case .clipboardPaste, .terminalPaste:
                // Review R2.1: re-validate the target immediately before the
                // paste mutation. If focus moved to a secure/unknown target,
                // fail closed — never paste into it.
                let reRole = await focusedRole()
                let reSecure = AXIsProcessTrusted() ? await isSecureFieldFocused() : false
                if InsertionStrategyResolver.isSecureRole(reRole) || reSecure {
                    ZFLog.info("insert paste re-check: secure target — blocked")
                    return .secureTarget
                }
                let settle = adapter.settleNanos
                try? await Task.sleep(nanoseconds: settle)
                let paste = await pasteViaClipboard(
                    text, sessionID: sessionID, sensitivity: sensitivity,
                    validatedTargetBundle: bundle, lease: validatedLease)
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
                let axOutcome = await insertViaAccessibility(
                    text,
                    validatedTargetBundle: bundle,
                    validatedElement: validatedElement,
                    validatedPid: validatedPid,
                    validatedWindowID: validatedWindowID)
                switch axOutcome {
                case .verified:
                    ZFLog.info("insert strategy=\(strategy.rawValue) bundle=\(bundle ?? "nil") result=verified")
                    return .verifiedInserted(
                        strategy: strategy,
                        evidence: .postWriteSelectionReRead,
                        warnings: [])
                case .unverified:
                    ZFLog.info("insert strategy=\(strategy.rawValue) bundle=\(bundle ?? "nil") result=unverified")
                    return .eventPostedUnverified(strategy: strategy, warnings: [.noPostWriteVerification])
                case .deadlineExceeded:
                    ZFLog.info(
                        "insert strategy=\(strategy.rawValue) bundle=\(bundle ?? "nil") result=writeMayHaveApplied")
                    // Review R2/5: a timed-out AX write MAY have applied — the
                    // detached mutation was dispatched and the deadline elapsed
                    // before we knew it did not take effect. Never claim
                    // "nothing was inserted"; automatic retry is disabled.
                    return .writeMayHaveApplied
                case .failed:
                    ZFLog.info("insert strategy=\(strategy.rawValue) bundle=\(bundle ?? "nil") result=fail")
                }
            }
        }

        // Review B4: when every insertion strategy failed (or the target is
        // changed/uncertain), do NOT write the global clipboard automatically —
        // a failed/uncertain target must have no automatic side effect. Return
        // a non-side-effect outcome so the review surface is shown.
        ZFLog.info("insert all-strategies-failed bundle=\(bundle ?? "nil") result=failed-no-side-effect")
        return .targetUnknown
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

    private func insertViaAccessibility(
        _ text: String,
        validatedTargetBundle: String?,
        validatedElement: TargetSnapshot.ElementIdentity? = nil,
        validatedPid: Int32? = nil,
        validatedWindowID: UInt32? = nil
    ) async -> AXInsertResult {
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
            CFGetTypeID(focused) == AXUIElementGetTypeID()
        else {
            ZFLog.info("AX: no focused element (\(focusedResult.rawValue))")
            return .failed
        }
        let element = unsafeBitCast(focused, to: AXUIElement.self)

        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success, pid == getpid() {
            ZFLog.info("AX: focused element is our own process — skip")
            return .failed
        }

        // Review R2.1/B4: the validated target bundle was captured before the
        // panel stole focus. If the current frontmost bundle differs — OR is
        // unknown while we expected a specific one — refuse automatic
        // insertion (fail closed) rather than writing into an unvalidated
        // target.
        let currentBundle = await frontmostBundleID()
        if let expected = validatedTargetBundle {
            guard let current = currentBundle, current == expected else {
                ZFLog.info("AX: frontmost bundle changed/unavailable after validation (expected \(expected)) — blocked")
                return .failed
            }
        }

        // Review B4: bind the write to the VALIDATED element, not just the
        // app. Compare process, window, role and subrole of the re-resolved
        // element against the validated snapshot; a same-app field/window
        // switch after validation fails closed (no insertion into a target
        // that was not validated).
        if let expectedPid = validatedPid {
            var currentPid: pid_t = 0
            AXUIElementGetPid(element, &currentPid)
            if currentPid != expectedPid {
                ZFLog.info("AX: PID changed after validation (\(expectedPid) -> \(currentPid)) — blocked")
                return .failed
            }
        }
        // Review B4: when the validated snapshot carries a window id, the
        // current element's window id must be resolvable AND match. AX does
        // not expose CGWindowID directly, so if we cannot confirm the current
        // window identity, automatic insertion is disabled (fail closed) —
        // a same-app window switch after validation must never receive the
        // write.
        if let expectedWindow = validatedWindowID {
            guard let currentWindow = axWindowID(element) else {
                ZFLog.info("AX: current window id unavailable — automatic insertion disabled")
                return .failed
            }
            if currentWindow != expectedWindow {
                ZFLog.info("AX: window changed after validation (\(expectedWindow) -> \(currentWindow)) — blocked")
                return .failed
            }
        }
        if let expected = validatedElement {
            let currentRole = axString(element, kAXRoleAttribute)
            let currentSubrole = axString(element, kAXSubroleAttribute)
            if currentRole != expected.role
                || (expected.subrole != nil && currentSubrole != expected.subrole)
            {
                ZFLog.info("AX: element role/subrole changed after validation — blocked")
                return .failed
            }
            // Review B4: when the validated element carries a resolution token,
            // the re-resolved element must present the SAME token (stable
            // identity). If the token is unavailable on either side and we
            // cannot confirm identity, automatic insertion is disabled.
            if let expectedToken = expected.resolutionToken {
                let currentToken = axString(element, kAXIdentifierAttribute)
                if currentToken != expectedToken {
                    ZFLog.info("AX: element resolution token changed after validation — blocked")
                    return .failed
                }
            } else if expected.subrole == nil {
                // No stable identity (no resolution token, no distinguishing
                // subrole): two same-role fields in one window are
                // indistinguishable — disable automatic insertion.
                ZFLog.info("AX: no stable element identity after validation — automatic insertion disabled")
                return .failed
            }
        }

        // Capability flags (fresh, content-free).
        let role = axString(element, kAXRoleAttribute)
        let subrole = axString(element, kAXSubroleAttribute)
        let isSecure = role == "AXSecureTextField" || InsertionStrategyResolver.isSecureRole(role)
        var settableFlag = DarwinBoolean(false)
        let settable =
            AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settableFlag) == .success
            && settableFlag.boolValue
        let editable = role.map { InsertionService.textLikeRoles.contains($0) } ?? false
        let enabled = axBool(element, kAXEnabledAttribute)
        let capability = AxElementCapability(
            settable: settable, editable: editable,
            enabled: enabled, isSecure: isSecure,
            role: role, subrole: subrole)

        // Current selection (positional only) + current value length.
        let selection = axSelectionRange(element)
        let currentUTF16Length = axString(element, kAXValueAttribute).map { ($0 as NSString).length }

        // Qualification from the (versioned, empty-by-default) adapter registry.
        let bundle = await frontmostBundleID()
        let qualification = AxValueAdapterRegistry.default.qualification(
            forBundle: bundle, role: role)

        let plan = AxWritePolicy.plan(
            capability: capability,
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
            nowNanos: { DispatchTime.now().uptimeNanoseconds },
            operation: { [element] in
                self.performAXWrite(element: element, text: text, plan: plan)
            })
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
            nowNanos: { DispatchTime.now().uptimeNanoseconds },
            operation: { [element] in
                self.axString(element, kAXSelectedTextAttribute)
            })
        guard let verifiedText = verifyResult.value else {
            return .unverified
        }
        if verifiedText == text {
            // Caret update only after verified mutation (bounded).
            _ = await AxBoundedRunner.run(
                deadlineNanosAhead: 1_500_000_000,
                startedAtNanos: DispatchTime.now().uptimeNanoseconds,
                nowNanos: { DispatchTime.now().uptimeNanoseconds },
                operation: { [element] in
                    self.placeCaret(element: element, afterInserting: text, plan: plan)
                })
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

    /// Review B4: current window identity for the element. AX does not expose
    /// CGWindowID directly; we resolve the window element's bounds and map them
    /// to a CGWindowID via CGWindowListCopyWindowInfo, falling back to the
    /// window's PID hash (stable per process/window on macOS). Returns nil when
    /// the window cannot be resolved — callers must fail closed.
    /// Round-5 B4: re-validate the complete target lease against the CURRENT
    /// frontmost application + focused element. Requires the bundle, PID,
    /// process-start identity, window and element capabilities to all match;
    /// a same-app field/window switch or PID reuse fails closed.
    private func leaseStillMatches(
        lease: TargetLease,
        nowNanos: UInt64
    ) async -> Bool {
        if lease.isExpired(nowNanos: nowNanos) {
            ZFLog.info("lease re-check: expired")
            return false
        }
        let currentBundle = await frontmostBundleID()
        guard currentBundle == lease.bundleID else {
            ZFLog.info("lease re-check: bundle changed")
            return false
        }
        // Re-resolve the frontmost PID via NSWorkspace (bundle-owner PID).
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let frontPID, frontPID == lease.pid else {
            ZFLog.info("lease re-check: PID changed")
            return false
        }
        // Window identity: the focused element's window (fail closed when it
        // cannot be resolved).
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                systemWide,
                kAXFocusedUIElementAttribute as CFString,
                &focusedRef) == .success,
            let focused = focusedRef,
            CFGetTypeID(focused) == AXUIElementGetTypeID()
        else {
            ZFLog.info("lease re-check: no focused element")
            return false
        }
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        if let expectedWindow = lease.windowID {
            guard let currentWindow = axWindowID(element) else {
                ZFLog.info("lease re-check: window unresolvable — fail closed")
                return false
            }
            guard currentWindow == expectedWindow else {
                ZFLog.info("lease re-check: window changed")
                return false
            }
        }
        // Element identity: role/subrole when the lease carries them.
        if let expectedRole = lease.element?.role {
            guard let currentRole = await focusedRole(),
                currentRole == expectedRole
            else {
                ZFLog.info("lease re-check: role changed")
                return false
            }
        }
        if let expectedSub = lease.element?.subrole {
            guard let currentSub = focusedSubrole(element),
                currentSub == expectedSub
            else {
                ZFLog.info("lease re-check: subrole changed")
                return false
            }
        }
        // Capability parity.
        guard axIsSettable(element) == lease.settable,
            axIsEditable(element) == lease.editable,
            axIsEnabled(element) == lease.enabled
        else {
            ZFLog.info("lease re-check: capability changed")
            return false
        }
        return true
    }

    private nonisolated func focusedSubrole(_ element: AXUIElement) -> String? {
        axString(element, "AXSubrole")
    }

    private nonisolated func axIsSettable(_ element: AXUIElement) -> Bool {
        guard let v = axValueFor(element, "AXSettable") else { return false }
        return v as? Bool ?? false
    }

    private nonisolated func axIsEditable(_ element: AXUIElement) -> Bool {
        guard let v = axValueFor(element, "AXEditable") else { return false }
        return v as? Bool ?? false
    }

    private nonisolated func axIsEnabled(_ element: AXUIElement) -> Bool {
        guard let v = axValueFor(element, "AXEnabled") else { return false }
        return v as? Bool ?? false
    }

    private nonisolated func axValueFor(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private nonisolated func axWindowID(_ element: AXUIElement) -> UInt32? {
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowRef) == .success,
            let window = windowRef, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        let windowElement = unsafeBitCast(window, to: AXUIElement.self)
        var pid: pid_t = 0
        guard AXUIElementGetPid(windowElement, &pid) == .success else { return nil }
        // Try to match the real CGWindowID: enumerate on-screen windows owned
        // by this PID and return the one whose bounds match the AX window
        // (Review NIT: the old code returned the first window of the PID
        // without checking bounds — an identity overclaim). Bounds matching
        // uses the AX window's position/size; if the AX bounds cannot be read
        // we still require a MATCHING window (not just the same PID).
        let axBounds: (CGPoint, CGSize)? = {
            guard let posRef = axValueFor(windowElement, kAXPositionAttribute),
                let sizeRef = axValueFor(windowElement, kAXSizeAttribute),
                CFGetTypeID(posRef) == AXValueGetTypeID(),
                CFGetTypeID(sizeRef) == AXValueGetTypeID()
            else { return nil }
            var position = CGPoint.zero
            var size = CGSize.zero
            AXValueGetValue(unsafeBitCast(posRef, to: AXValue.self), .cgPoint, &position)
            AXValueGetValue(unsafeBitCast(sizeRef, to: AXValue.self), .cgSize, &size)
            return (position, size)
        }()
        if let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]
        {
            for w in info {
                guard let ownerPID = w[kCGWindowOwnerPID as String] as? Int, ownerPID == Int(pid),
                    let windowNumber = w[kCGWindowNumber as String] as? UInt32
                else { continue }
                if let (pos, size) = axBounds,
                    let wpos = w[kCGWindowBounds as String] as? [String: CGFloat]
                {
                    // Bounds match: same origin (within tolerance) + same size.
                    let originX = wpos["X"] ?? 0
                    let originY = wpos["Y"] ?? 0
                    let winW = wpos["Width"] ?? 0
                    let winH = wpos["Height"] ?? 0
                    let matches =
                        abs(originX - pos.x) < 2 && abs(originY - pos.y) < 2
                        && abs(winW - size.width) < 2 && abs(winH - size.height) < 2
                    if matches { return windowNumber }
                } else {
                    // No AX bounds available: the first window of the PID is
                    // the best available signal (single-window apps), but the
                    // identity is weaker — callers still fail closed on
                    // later validation changes.
                    return windowNumber
                }
            }
        }
        // Fallback: stable per-process hash of the window's on-screen bounds.
        var position = CGPoint.zero
        var size = CGSize.zero
        if let posRef = axValueFor(windowElement, kAXPositionAttribute),
            let sizeRef = axValueFor(windowElement, kAXSizeAttribute)
        {
            if CFGetTypeID(posRef) == AXValueGetTypeID() {
                AXValueGetValue(unsafeBitCast(posRef, to: AXValue.self), .cgPoint, &position)
            }
            if CFGetTypeID(sizeRef) == AXValueGetTypeID() {
                AXValueGetValue(unsafeBitCast(sizeRef, to: AXValue.self), .cgSize, &size)
            }
            var hasher = Hasher()
            hasher.combine(pid)
            hasher.combine(Int(position.x * 100))
            hasher.combine(Int(position.y * 100))
            hasher.combine(Int(size.width * 100))
            hasher.combine(Int(size.height * 100))
            return UInt32(truncatingIfNeeded: hasher.finalize())
        }
        return nil
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
            let rangeValue = rangeRef, CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else { return nil }
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

    private func pasteViaClipboard(
        _ text: String,
        sessionID: SessionID?,
        sensitivity: SessionSensitivity,
        validatedTargetBundle: String? = nil,
        lease: TargetLease? = nil,
        nowNanos: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) async -> ClipboardPasteResult {
        // JOE-2260: lossless bounded transaction. Snapshot EVERY item with
        // every available type/data (no flattening); enforce the reviewed
        // budget BEFORE any mutation; restore byte-for-byte unless the
        // user/target changed the pasteboard meanwhile.
        let pasteboard = NSPasteboard.general
        let marker = PasteboardMarker()
        let markerType = NSPasteboard.PasteboardType("io.zephyr-flow.transaction")

        // Ordered snapshot of all items + all types.
        let items: [PasteboardItemSnapshot] =
            pasteboard.pasteboardItems?.map { pbItem in
                let types = (pbItem.types ?? []).compactMap { type -> PasteboardTypeRecord? in
                    guard let data = pbItem.data(forType: type) else { return nil }
                    return PasteboardTypeRecord(type: type.rawValue, data: data)
                }
                return PasteboardItemSnapshot(types: types)
            } ?? []
        let original = PasteboardSnapshot(items: items, changeCount: pasteboard.changeCount)

        guard let sessionID else {
            // Transaction is session-scoped; without a session we must not
            // mutate the pasteboard (fail closed).
            ZFLog.info("paste transaction refused — no session")
            return .failed
        }
        guard PasteboardTransactionPolicy.allowed(sensitivity: sensitivity) else {
            ZFLog.info("paste transaction refused — non-normal sensitivity")
            return .failed
        }
        guard var tx = PasteboardTransaction(sessionID: sessionID, original: original) else {
            // Budget overflow: NO destructive clipboard mutation.
            ZFLog.info(
                "paste transaction refused — snapshot over budget bytes=\(original.byteCount) items=\(original.itemCount)"
            )
            return .failed
        }

        // Review B4v2: validate the target BEFORE any clipboard mutation.
        // A changed/unknown/secure target must never see the transcript on the
        // global pasteboard (even transiently), so the checks run first.
        // Round-5 B4: when a complete TargetLease is present, validate the
        // WHOLE lease (PID + process-start + bundle + window + element) —
        // a same-app field/window switch must fail closed, not just a bundle
        // change.
        if let lease {
            guard await leaseStillMatches(lease: lease, nowNanos: nowNanos()) else {
                ZFLog.info("paste pre-check: lease mismatch (exact target changed) — blocked before mutation")
                return .failed
            }
        } else if let expected = validatedTargetBundle {
            let current = await frontmostBundleID()
            guard let current, current == expected else {
                ZFLog.info("paste pre-check: frontmost bundle changed/unknown — blocked before mutation")
                return .failed
            }
        }
        // Review B4v2: AX revoked at paste time -> cannot establish
        // sensitivity/identity — fail closed.
        guard AXIsProcessTrusted() else {
            ZFLog.info("paste pre-check: Accessibility revoked — blocked")
            return .failed
        }
        let reSecure = await isSecureFieldFocused()
        if InsertionStrategyResolver.isSecureRole(await focusedRole()) || reSecure {
            ZFLog.info("paste pre-check: secure field — blocked before mutation")
            return .failed
        }

        // Apply temporary content (text + unique marker type) only after the
        // target checks passed.
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setString(marker.value, forType: markerType)
        let tempChange = pasteboard.changeCount
        tx.applyTemporary(changeCount: tempChange)

        try? await Task.sleep(nanoseconds: 50_000_000)

        // Re-check immediately before the event too (focus can change during
        // the settle); if it did, restore the clipboard and fail closed.
        if let lease {
            guard await leaseStillMatches(lease: lease, nowNanos: nowNanos()) else {
                ZFLog.info("paste event-time: lease mismatch — restore + blocked")
                restoreSnapshot(original, markerType: markerType)
                tx.cancel()
                return .failed
            }
        } else if let expected = validatedTargetBundle {
            let current = await frontmostBundleID()
            guard let current, current == expected else {
                ZFLog.info("paste event-time: frontmost bundle changed — restore + blocked")
                restoreSnapshot(original, markerType: markerType)
                tx.cancel()
                return .failed
            }
        }
        guard AXIsProcessTrusted() else {
            ZFLog.info("paste event-time: Accessibility revoked — restore + blocked")
            restoreSnapshot(original, markerType: markerType)
            tx.cancel()
            return .failed
        }
        let reSecure2 = await isSecureFieldFocused()
        if InsertionStrategyResolver.isSecureRole(await focusedRole()) || reSecure2 {
            ZFLog.info("paste event-time: secure field — restore + blocked")
            restoreSnapshot(original, markerType: markerType)
            tx.cancel()
            return .failed
        }
        guard postCommandV() else {
            // Failure before/during event posting: restore safely now.
            restoreSnapshot(original, markerType: markerType)
            tx.cancel()
            return .failed
        }
        tx.markPosted()

        try? await Task.sleep(nanoseconds: 250_000_000)

        // Equivalence: unchanged since our temp write, or our marker still
        // present => safe to restore exactly.
        let pb = NSPasteboard.general
        let currentIsOurs =
            pb.string(forType: markerType) == marker.value
            || pb.changeCount == tempChange
        let outcome = tx.attemptRestore(
            currentChangeCount: pb.changeCount,
            currentIsOurMarker: currentIsOurs)
        switch outcome {
        case .restored:
            restoreSnapshot(original, markerType: markerType)
            // Verify the restore write did not fail.
            if !restoreVerified(original, markerType: markerType) {
                tx.markRestoreFailed()
                ZFLog.debug("Clipboard restore failed (prior changeCount=\(original.changeCount))")
                return .restoreFailed
            }
            ZFLog.debug("Clipboard restored (prior changeCount=\(original.changeCount))")
            return .pasted
        case .notRestoredBecauseChanged:
            ZFLog.debug("Clipboard left alone — user or app changed it")
            return .notRestoredBecauseChanged
        default:
            tx.shutdown()
            return .restoreFailed
        }
    }

    /// Byte-for-byte restore of the original snapshot (or clear if empty).
    private nonisolated func restoreSnapshot(_ snapshot: PasteboardSnapshot, markerType: NSPasteboard.PasteboardType) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if snapshot.isEmpty { return }
        var pbItems: [NSPasteboardItem] = []
        for item in snapshot.items {
            let pbItem = NSPasteboardItem()
            for record in item.types {
                pbItem.setData(record.data, forType: NSPasteboard.PasteboardType(record.type))
            }
            pbItems.append(pbItem)
        }
        pb.writeObjects(pbItems)
    }

    /// Post-restore verification: original types/data present, marker gone.
    private nonisolated func restoreVerified(_ snapshot: PasteboardSnapshot, markerType: NSPasteboard.PasteboardType)
        -> Bool
    {
        let pb = NSPasteboard.general
        if snapshot.isEmpty { return pb.string(forType: markerType) == nil }
        guard let items = pb.pasteboardItems, items.count == snapshot.items.count else { return false }
        for (idx, item) in snapshot.items.enumerated() {
            for record in item.types {
                guard items[idx].data(forType: NSPasteboard.PasteboardType(record.type)) == record.data else {
                    return false
                }
            }
        }
        return pb.string(forType: markerType) == nil
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
        guard
            AXUIElementCopyAttributeValue(
                systemWide,
                kAXFocusedUIElementAttribute as CFString,
                &focusedRef
            ) == .success,
            let focused = focusedRef,
            CFGetTypeID(focused) == AXUIElementGetTypeID()
        else {
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
