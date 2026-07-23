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

        self.panel = panel
        self.hostingView = hosting
        return panel
    }

    @MainActor
    private func position(_ panel: NSPanel, near point: NSPoint?) {
        let mouse = point ?? NSEvent.mouseLocation
        let size = panel.frame.size
        let margin: CGFloat = 16

        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
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

    var body: some View {
        Group {
            switch controller.panelState {
            case .hidden:
                Color.clear.frame(width: 1, height: 1)
            default:
                FloatingPanelView(
                    state: controller.panelState,
                    text: controller.interimText,
                    levels: controller.audioLevels,
                    activeStyle: controller.activeFlowStyle,
                    onStyle: { controller.applyQuickAction($0) },
                    onStop: { controller.stopAndInsert() },
                    onCancel: { controller.cancelSession() }
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
    }

    private func handleStateChange(_ state: PanelState) {
        switch state {
        case .hidden:
            FloatingPanelController.shared.hide()
        case .listening, .processing, .success, .error:
            FloatingPanelController.shared.show(near: NSEvent.mouseLocation)
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showText: Bool {
        !text.isEmpty || state == .processing || isError
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
        ZStack {
            Circle()
                .fill(orbGradient)

            // Waveform stays *inside* the orb — clipped so bars never spill into text.
            if state == .listening {
                waveform
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
        .scaleEffect(orbScale)
        .shadow(color: glowColor.opacity(0.55), radius: reduceMotion ? 0 : 12)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
            value: state == .listening
        )
        .accessibilityLabel(orbAccessibilityLabel)
    }

    private var orbScale: CGFloat {
        if reduceMotion { return 1.0 }
        return state == .listening ? 1.08 : 1.0
    }

    private var orbGradient: LinearGradient {
        switch state {
        case .success:
            return LinearGradient(colors: [ZephyrTheme.mint, Color.green.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .error:
            return LinearGradient(colors: [ZephyrTheme.danger, Color.orange.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .processing:
            return LinearGradient(colors: [ZephyrTheme.violet, ZephyrTheme.cyan.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
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

    private var waveform: some View {
        // Fewer, shorter bars so the mark stays inside the 46pt orb diameter.
        let bars = Array(levels.suffix(12))
        return HStack(spacing: 1.5) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, level in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(0.92))
                    .frame(width: 2, height: max(4, min(20, CGFloat(level) * 20)))
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
            } else if state == .processing && text.isEmpty {
                Text("Processing…")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(ZephyrTheme.textSecondary)
            } else {
                Text(text.isEmpty ? "Listening…" : text)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(ZephyrTheme.textPrimary)
                    .lineLimit(6)
                    .frame(maxWidth: 260, alignment: .leading)
                    .animation(.easeOut(duration: 0.12), value: text)
            }
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
            .help("Stop & Insert")
            .accessibilityLabel("Stop and insert")

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(ZephyrTheme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(ZephyrTheme.bgElevated))
            }
            .buttonStyle(.plain)
            .help("Cancel (discard)")
            .accessibilityLabel("Cancel")
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
