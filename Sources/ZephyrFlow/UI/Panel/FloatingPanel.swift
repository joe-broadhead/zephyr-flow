import AppKit
import SwiftUI
import ZephyrFlowCore

/// Borderless, non-activating floating panel that can appear over other apps.
final class FloatingPanelController {
    static let shared = FloatingPanelController()

    private var panel: NSPanel?
    private var hostingView: NSHostingView<FloatingPanelRoot>?

    private init() {}

    @MainActor
    func prepare() {
        _ = ensurePanel()
        panel?.orderOut(nil)
        ZFLog.info("Floating panel prepared")
    }

    @MainActor
    func show(near point: NSPoint?) {
        let panel = ensurePanel()
        // Re-bind root so @ObservedObject subscriptions stay live across show cycles.
        hostingView?.rootView = FloatingPanelRoot()
        position(panel, near: point)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    @MainActor
    func hide() {
        panel?.orderOut(nil)
    }

    @MainActor
    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let root = FloatingPanelRoot()
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 120)

        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .utilityWindow
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = hosting
        panel.acceptsMouseMovedEvents = true
        panel.isMovableByWindowBackground = true

        self.panel = panel
        self.hostingView = hosting
        return panel
    }

    @MainActor
    private func position(_ panel: NSPanel, near point: NSPoint?) {
        let size = panel.frame.size
        let margin: CGFloat = 16
        let settings = SettingsStore.shared.settings

        // Honor user-dragged position when locked
        if settings.panelPositionLocked,
            let x = settings.panelOriginX,
            let y = settings.panelOriginY
        {
            var origin = NSPoint(x: x, y: y)
            origin = clamp(origin, size: size, margin: margin)
            panel.setFrameOrigin(origin)
            return
        }

        let mouse = point ?? NSEvent.mouseLocation
        let screen =
            NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first

        guard let screen else {
            panel.setFrameOrigin(mouse)
            return
        }

        let visible = screen.visibleFrame
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y + 24)

        if origin.x < visible.minX + margin { origin.x = visible.minX + margin }
        if origin.x + size.width > visible.maxX - margin {
            origin.x = visible.maxX - size.width - margin
        }
        if origin.y + size.height > visible.maxY - margin {
            origin.y = mouse.y - size.height - 24
        }
        if origin.y < visible.minY + margin { origin.y = visible.minY + margin }

        panel.setFrameOrigin(origin)
    }

    @MainActor
    private func clamp(_ origin: NSPoint, size: NSSize, margin: CGFloat) -> NSPoint {
        var o = origin
        let screen =
            NSScreen.screens.first { NSMouseInRect(o, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return o }
        if o.x < visible.minX + margin { o.x = visible.minX + margin }
        if o.x + size.width > visible.maxX - margin { o.x = visible.maxX - size.width - margin }
        if o.y < visible.minY + margin { o.y = visible.minY + margin }
        if o.y + size.height > visible.maxY - margin { o.y = visible.maxY - size.height - margin }
        return o
    }

    /// Persist current frame origin after the user may have dragged the panel
    /// (`isMovableByWindowBackground`). Only locks once origin is non-nil save.
    @MainActor
    func persistPositionIfNeeded() {
        guard let panel else { return }
        let origin = panel.frame.origin
        let prevX = SettingsStore.shared.settings.panelOriginX
        let prevY = SettingsStore.shared.settings.panelOriginY
        // Skip no-op writes when still at auto-placed first show without drag history
        // and nothing was ever locked — still save so next show can restore after move.
        if SettingsStore.shared.settings.panelPositionLocked,
            prevX == origin.x, prevY == origin.y
        {
            return
        }
        SettingsStore.shared.update {
            $0.panelOriginX = origin.x
            $0.panelOriginY = origin.y
            $0.panelPositionLocked = true
        }
    }

    @MainActor
    func resizeToFit() {
        guard let panel, let hosting = hostingView else { return }
        let fitting = hosting.fittingSize
        var frame = panel.frame
        let newSize = NSSize(
            width: max(72, min(360, fitting.width)),
            height: max(72, fitting.height)
        )
        let dx = (frame.width - newSize.width) / 2
        frame.origin.x += dx
        frame.origin.y += frame.height - newSize.height
        frame.size = newSize
        panel.setFrame(frame, display: true)
        hosting.frame = NSRect(origin: .zero, size: newSize)
    }
}

// MARK: - SwiftUI root

struct FloatingPanelRoot: View {
    @ObservedObject private var controller = DictationController.shared
    @State private var keyMonitor: Any?

    var body: some View {
        ZStack {
            switch controller.panelState {
            case .hidden:
                Color.clear.frame(width: 1, height: 1)
            case .warning:
                PanelWarningView(
                    text: controller.interimText,
                    message: controller.statusMessage ?? "",
                    onDiscard: {
                        controller.clearStatusLater()
                        controller.panelState = .hidden
                    })
            default:
                FloatingPanelView(
                    state: controller.panelState,
                    text: controller.interimText,
                    levels: controller.audioLevels,
                    activeStyle: controller.activeFlowStyle,
                    onStyle: { controller.applyQuickAction($0) },
                    onStop: { controller.stopAndInsert() },
                    onCancel: { controller.cancelSession() },
                    onReviewCopy: { controller.copyReviewContent() },
                    onReviewRetry: { controller.retryReview() },
                    onReviewDiscard: { controller.discardReview() },
                    onReviewSettings: { controller.openAccessibilitySettings() },
                    reviewTitle: controller.reviewTitle,
                    reviewDetail: controller.reviewDetail,
                    reviewAllowsRetry: controller.reviewAllowsRetry,
                    reviewWarnsCopy: controller.reviewWarnsCopy,
                    reviewAllowsSettings: controller.reviewAllowsSettings
                )
                .transition(.scale(scale: 0.88).combined(with: .opacity))
            }
        }
        .animation(ZephyrTheme.spring, value: controller.panelState)
        .preferredColorScheme(.dark)
        .onChange(of: controller.panelState) { _, new in
            handleStateChange(new)
        }
        .onChange(of: controller.interimText) { _, _ in
            FloatingPanelController.shared.resizeToFit()
        }
        .onDisappear { removePanelKeyMonitor() }
    }

    private func installPanelKeyMonitor() {
        removePanelKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let controller = DictationController.shared
            guard
                controller.panelState == .listening
                    || controller.panelState == .processing
                    || controller.panelState == .reviewing
                    || controller.panelState == .warning
                    || {
                        if case .error = controller.panelState { return true }
                        return false
                    }()
            else {
                return event
            }
            // Esc or ⌘. clears review / cancels session
            if event.keyCode == 53
                || (event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == ".")
            {
                if controller.panelState == .reviewing {
                    controller.discardReview()  // JOE-2272: discard clears text + model
                } else if controller.panelState == .warning {
                    controller.clearStatusLater()
                    controller.panelState = .hidden
                } else {
                    controller.cancelSession()
                }
                return nil
            }
            // Return / ⌘Return → stop & insert; in review it is the explicit copy.
            if event.keyCode == 36 {
                if controller.panelState == .reviewing {
                    controller.copyReviewContent()
                } else {
                    controller.stopAndInsert()
                }
                return nil
            }
            return event
        }
    }

    private func removePanelKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    private func handleStateChange(_ state: PanelState) {
        switch state {
        case .hidden:
            FloatingPanelController.shared.persistPositionIfNeeded()
            FloatingPanelController.shared.hide()
            removePanelKeyMonitor()
        case .listening, .processing, .reviewing, .success, .warning, .error:
            FloatingPanelController.shared.show(near: NSEvent.mouseLocation)
            installPanelKeyMonitor()
            DispatchQueue.main.async {
                FloatingPanelController.shared.resizeToFit()
            }
        }
    }
}

// MARK: - Panel visual (dark tech glass)

struct FloatingPanelView: View {
    let state: PanelState
    let text: String
    let levels: [Float]
    let activeStyle: FlowStyle
    let onStyle: (FlowStyle) -> Void
    let onStop: () -> Void
    let onCancel: () -> Void
    let onReviewCopy: () -> Void

    let onReviewRetry: () -> Void
    let onReviewDiscard: () -> Void
    let onReviewSettings: () -> Void
    let reviewTitle: String?
    let reviewDetail: String?
    let reviewAllowsRetry: Bool
    let reviewWarnsCopy: Bool
    let reviewAllowsSettings: Bool

    init(
        state: PanelState, text: String, levels: [Float], activeStyle: FlowStyle,
        onStyle: @escaping (FlowStyle) -> Void, onStop: @escaping () -> Void,
        onCancel: @escaping () -> Void, onReviewCopy: @escaping () -> Void,
        onReviewRetry: @escaping () -> Void, onReviewDiscard: @escaping () -> Void,
        onReviewSettings: @escaping () -> Void,
        reviewTitle: String?, reviewDetail: String?,
        reviewAllowsRetry: Bool, reviewWarnsCopy: Bool, reviewAllowsSettings: Bool
    ) {
        self.state = state
        self.text = text
        self.levels = levels
        self.activeStyle = activeStyle
        self.onStyle = onStyle
        self.onStop = onStop
        self.onCancel = onCancel
        self.onReviewCopy = onReviewCopy
        self.onReviewRetry = onReviewRetry
        self.onReviewDiscard = onReviewDiscard
        self.onReviewSettings = onReviewSettings
        self.reviewTitle = reviewTitle
        self.reviewDetail = reviewDetail
        self.reviewAllowsRetry = reviewAllowsRetry
        self.reviewWarnsCopy = reviewWarnsCopy
        self.reviewAllowsSettings = reviewAllowsSettings
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showText: Bool {
        !text.isEmpty || state == .processing || state == .reviewing || isError
    }

    private var isError: Bool {
        if case .error = state { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                orb
                if showText { textBlock }
            }

            if state == .listening || state == .processing {
                quickActions
            }

            if state == .reviewing {
                reviewActions
            }
        }
        .padding(.horizontal, showText ? 18 : 14)
        .padding(.vertical, showText ? 16 : 14)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
        )
        .shadow(color: glowColor.opacity(0.35), radius: 20, x: 0, y: 8)
        .shadow(color: .black.opacity(0.45), radius: 28, x: 0, y: 14)
        .frame(minWidth: 72, maxWidth: 340)
    }

    private var borderColor: Color {
        switch state {
        case .listening: return ZephyrTheme.cyan.opacity(0.35)
        case .processing: return ZephyrTheme.violet.opacity(0.4)
        case .success: return ZephyrTheme.mint.opacity(0.45)
        case .error: return ZephyrTheme.danger.opacity(0.5)
        default: return ZephyrTheme.border
        }
    }

    private var glowColor: Color {
        switch state {
        case .listening: return ZephyrTheme.cyan
        case .processing: return ZephyrTheme.violet
        case .success: return ZephyrTheme.mint
        case .error: return ZephyrTheme.danger
        default: return .clear
        }
    }

    // MARK: Orb

    private var orb: some View {
        // TimelineView owns the pulse + bar clock so frequent parent redraws
        // (interim text / levels) cannot freeze SwiftUI repeatForever animations.
        TimelineView(.animation(minimumInterval: reduceMotion ? 60 : 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse: CGFloat = {
                guard !reduceMotion, state == .listening else { return 1.0 }
                return 1.0 + 0.08 * CGFloat(sin(t * 2 * Double.pi / 0.9))
            }()

            ZStack {
                Circle()
                    .fill(orbGradient)

                if state == .listening {
                    listeningWaveform(time: t)
                }

                if state == .processing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }

                if state == .success {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                }

                if case .error = state {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 46, height: 46)
            .clipShape(Circle())
            .scaleEffect(pulse)
            .shadow(color: glowColor.opacity(0.55), radius: reduceMotion ? 0 : 12)
        }
        .accessibilityLabel(orbAccessibilityLabel)
    }

    private var orbGradient: LinearGradient {
        switch state {
        case .success:
            return LinearGradient(
                colors: [ZephyrTheme.mint, Color.green.opacity(0.85)], startPoint: .topLeading,
                endPoint: .bottomTrailing)
        case .error:
            return LinearGradient(
                colors: [ZephyrTheme.danger, Color.orange.opacity(0.85)], startPoint: .topLeading,
                endPoint: .bottomTrailing)
        case .processing:
            return LinearGradient(
                colors: [ZephyrTheme.violet, ZephyrTheme.cyan.opacity(0.7)], startPoint: .topLeading,
                endPoint: .bottomTrailing)
        default:
            return ZephyrTheme.brandGradient
        }
    }

    private var orbAccessibilityLabel: String {
        switch state {
        case .listening: return "Listening"
        case .processing: return "Processing"
        case .success: return "Inserted"
        case .error(let m): return "Error: \(m)"
        default: return "ZephyrFlow"
        }
    }

    /// Mic-reactive bars with a light idle bob so listening always *looks* live
    /// even when the meter is quiet; amplitude scales up with real levels.
    private func listeningWaveform(time: TimeInterval) -> some View {
        let bars = Array(levels.suffix(12))
        let count = max(bars.count, 12)
        return HStack(spacing: 1.5) {
            ForEach(0..<count, id: \.self) { i in
                let mic = CGFloat(i < bars.count ? bars[i] : 0.05)
                let bob = reduceMotion ? 0 : 0.2 * sin(time * 5.5 + Double(i) * 0.55)
                // Idle motion always visible while listening; voice raises the floor.
                let unit = min(1.0, max(0.0, 0.22 + mic * 0.95 + CGFloat(bob) * (0.25 + mic)))
                let height = max(4, min(22, unit * 22))
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(0.92))
                    .frame(width: 2, height: height)
            }
        }
        .frame(width: 30, height: 22)
    }

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            if case .error(let message) = state {
                Text(message)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(ZephyrTheme.danger.opacity(0.95))
                    .frame(maxWidth: 260, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if message.localizedCaseInsensitiveContains("microphone") {
                    Text(AppStrings.key("panel.openMicSettings"))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(ZephyrTheme.textSecondary)
                } else if message.localizedCaseInsensitiveContains("accessib") {
                    Text(AppStrings.key("panel.openAXSettings"))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(ZephyrTheme.textSecondary)
                }
            } else if state == .processing && text.isEmpty {
                Text(AppStrings.key("panel.processing"))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(ZephyrTheme.textSecondary)
            } else {
                Text(text.isEmpty ? "Listening…" : text)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(ZephyrTheme.textPrimary)
                    .lineLimit(6)
                    .frame(maxWidth: 260, minHeight: 18, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .animation(.easeOut(duration: 0.12), value: text)
                    .accessibilityLabel(text.isEmpty ? "Listening" : "Interim transcription")
            }
        }
    }

    private var reviewActions: some View {
        VStack(spacing: 10) {
            if let reviewTitle {
                Text(reviewTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(ZephyrTheme.warning)
                    .multilineTextAlignment(.center)
                    .accessibilityLabel(AppStrings.format("panel.reviewTitle", reviewTitle))
            }
            if let reviewDetail {
                Text(reviewDetail)
                    .font(.system(size: 11))
                    .foregroundColor(ZephyrTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .accessibilityLabel(reviewDetail)
            }
            HStack(spacing: 8) {
                if reviewAllowsRetry {
                    Button(action: onReviewRetry) {
                        Label(AppStrings.key("panel.retry"), systemImage: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(ZephyrTheme.bgElevated, in: Capsule())
                            .foregroundColor(ZephyrTheme.textPrimary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(AppStrings.key("panel.retryHint"))
                    .keyboardShortcut("r", modifiers: .command)
                }
                Button(action: onReviewCopy) {
                    Label(reviewWarnsCopy ? "Copy to Clipboard" : "Copy", systemImage: "doc.on.doc")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(ZephyrTheme.warning.opacity(0.9), in: Capsule())
                        .foregroundColor(.black)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    reviewWarnsCopy
                        ? "Copy to clipboard — this places the text on the global clipboard"
                        : "Copy text to clipboard"
                )
                .keyboardShortcut(.return, modifiers: [])
                if reviewAllowsSettings {
                    Button(action: onReviewSettings) {
                        Label(AppStrings.key("panel.settings"), systemImage: "gearshape")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(ZephyrTheme.bgElevated, in: Capsule())
                            .foregroundColor(ZephyrTheme.textPrimary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(AppStrings.key("panel.openAX"))
                }
                Button(action: onReviewDiscard) {
                    Label(AppStrings.key("panel.discard"), systemImage: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(ZephyrTheme.bgElevated, in: Capsule())
                        .foregroundColor(ZephyrTheme.danger)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppStrings.key("panel.discardHint"))
                .keyboardShortcut(.escape, modifiers: [])
            }
            Text(AppStrings.key("panel.autoClear"))
                .font(.system(size: 9))
                .foregroundColor(ZephyrTheme.textMuted)
        }
    }

    private var quickActions: some View {
        HStack(spacing: 6) {
            ForEach([FlowStyle.clean, .bullets, .professional, .raw], id: \.self) { style in
                Button {
                    onStyle(style)
                } label: {
                    Image(systemName: style.systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(activeStyle == style ? ZephyrTheme.cyan : ZephyrTheme.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(
                            Circle().fill(
                                activeStyle == style
                                    ? ZephyrTheme.cyan.opacity(0.18)
                                    : ZephyrTheme.bgElevated.opacity(0.9)
                            )
                        )
                }
                .buttonStyle(.plain)
                .help(style.displayName)
                .accessibilityLabel(style.displayName)
            }

            Spacer(minLength: 4)

            Button(action: onStop) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.black.opacity(0.85))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(ZephyrTheme.mint))
            }
            .buttonStyle(.plain)
            .help(AppStrings.key("panel.help.stopInsert"))
            .accessibilityLabel(AppStrings.key("panel.stopAndInsert"))

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(ZephyrTheme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(ZephyrTheme.bgElevated))
            }
            .buttonStyle(.plain)
            .help(AppStrings.key("panel.help.cancelDiscard"))
            .accessibilityLabel(AppStrings.key("panel.cancel"))
        }
    }

    private var panelBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(ZephyrTheme.panelGradient)
            // Top sheen
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.08), .clear],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
        }
    }
}

/// JOE-2284: persistent warning presentation (amber, no green, no auto
/// dismiss) with a VoiceOver label; discard is explicit.
struct PanelWarningView: View {
    let text: String
    let message: String
    let onDiscard: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18))
                .foregroundColor(ZephyrTheme.warning)
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundColor(ZephyrTheme.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
            }
            if !message.isEmpty {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(ZephyrTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            Button(AppStrings.key("panel.dismiss"), action: onDiscard)
                .font(.system(size: 12, weight: .semibold))
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(ZephyrTheme.bgElevated, in: Capsule())
                .foregroundColor(ZephyrTheme.textPrimary)
                .keyboardShortcut(.escape, modifiers: [])
                .accessibilityLabel(AppStrings.key("panel.dismissWarning"))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message.isEmpty ? "Warning" : "Warning: \(message)")
    }
}
