import SwiftUI
import ZephyrFlowCore

/// Stepped dark setup flow. One system permission prompt at a time for clean UX.
struct OnboardingView: View {
    @ObservedObject private var privacy = PrivacyService.shared
    @ObservedObject private var settings = SettingsStore.shared
    var onFinished: () -> Void

    @State private var step: Step = .welcome
    @State private var isRequesting = false

    enum Step: Int, CaseIterable {
        case welcome
        case microphone
        case speech
        case accessibility
        case dictation
        case ready

        var title: String {
            switch self {
            case .welcome: return "Private dictation,\non your machine"
            case .microphone: return "Microphone"
            case .speech: return "Speech Recognition"
            case .accessibility: return "Accessibility"
            case .dictation: return "System Dictation"
            case .ready: return "You're set"
            }
        }

        var subtitle: String {
            switch self {
            case .welcome:
                return "Hold Fn, speak, release — text appears at your cursor. Local Only is on by default."
            case .microphone:
                return "ZephyrFlow needs the mic to capture your voice. Audio is processed on-device."
            case .speech:
                return "Apple’s on-device speech engine turns voice into text. We’ll show one system prompt."
            case .accessibility:
                return "Lets Fn work globally and insert text at the caret in other apps."
            case .dictation:
                return
                    "macOS blocks Apple Speech unless Keyboard → Dictation is On. This is a system switch, not an app permission."
            case .ready:
                return "Click into any text field, hold Fn, speak, and release."
            }
        }

        var icon: String {
            switch self {
            case .welcome: return "wind"
            case .microphone: return "mic.fill"
            case .speech: return "waveform"
            case .accessibility: return "accessibility"
            case .dictation: return "keyboard"
            case .ready: return "checkmark"
            }
        }
    }

    var body: some View {
        ZStack {
            // Tech backdrop
            ZephyrTheme.bgDeep.ignoresSafeArea()
            RadialGradient(
                colors: [ZephyrTheme.violet.opacity(0.18), .clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 420
            )
            .ignoresSafeArea()
            RadialGradient(
                colors: [ZephyrTheme.cyan.opacity(0.12), .clear],
                center: .bottomLeading,
                startRadius: 10,
                endRadius: 360
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                progressBar
                    .padding(.top, 18)
                    .padding(.horizontal, 28)

                Spacer(minLength: 12)

                stepContent
                    .padding(.horizontal, 36)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        )
                    )
                    .id(step)

                Spacer(minLength: 12)

                footer
                    .padding(24)
            }
        }
        .frame(width: 540, height: 580)
        .zephyrDarkChrome()
        .onAppear {
            privacy.refresh()
            advancePastGrantedSteps()
        }
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
            privacy.refresh()
            // Auto-advance when the current step becomes satisfied
            autoAdvanceIfGranted()
        }
    }

    // MARK: Progress

    private var progressBar: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.rawValue) { s in
                Capsule()
                    .fill(s.rawValue <= step.rawValue ? ZephyrTheme.cyan : ZephyrTheme.border)
                    .frame(height: 3)
                    .animation(ZephyrTheme.spring, value: step)
            }
        }
    }

    // MARK: Content

    private var stepContent: some View {
        VStack(spacing: 22) {
            Group {
                if step == .welcome || step == .ready {
                    ZephyrMarkBadge(size: 88)
                } else {
                    ZStack {
                        Circle()
                            .fill(ZephyrTheme.brandGradient.opacity(0.25))
                            .frame(width: 96, height: 96)
                            .blur(radius: 2)
                        Circle()
                            .strokeBorder(ZephyrTheme.borderGlow, lineWidth: 1)
                            .frame(width: 88, height: 88)
                        Circle()
                            .fill(ZephyrTheme.bgCard)
                            .frame(width: 80, height: 80)
                            .overlay(
                                Image(systemName: step.icon)
                                    .font(.system(size: 32, weight: .semibold))
                                    .foregroundStyle(ZephyrTheme.brandGradient)
                            )
                    }
                }
            }

            VStack(spacing: 10) {
                Text(step.title)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(ZephyrTheme.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text(step.subtitle)
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .foregroundStyle(ZephyrTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if step != .welcome && step != .ready {
                statusChip
            }

            if step == .ready {
                readyTips
            }
        }
    }

    private var statusChip: some View {
        let ok = stepSatisfied(step)
        return HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? ZephyrTheme.mint : ZephyrTheme.textMuted)
            Text(ok ? "Ready" : "Waiting for permission…")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(ok ? ZephyrTheme.mint : ZephyrTheme.textSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(ZephyrTheme.bgCard))
        .overlay(Capsule().strokeBorder(ZephyrTheme.border, lineWidth: 1))
    }

    private var readyTips: some View {
        VStack(alignment: .leading, spacing: 10) {
            tipRow(icon: "fn", text: "Hold Fn to talk · release to insert")
            tipRow(
                icon: "lock.shield.fill",
                text: "Local Only — your voice stays on this Mac; Whisper Tiny may download once")
            tipRow(icon: "gearshape", text: "Menu bar mic → Settings anytime")
        }
        .padding(16)
        .frame(maxWidth: 400, alignment: .leading)
        .background(ZephyrCardBackground())
    }

    private func tipRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ZephyrTheme.cyan)
                .frame(width: 22)
            Text(text)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(ZephyrTheme.textSecondary)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if step != .welcome {
                Button("Back") { goBack() }
                    .buttonStyle(ZephyrSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }

            Spacer()

            if step == .welcome {
                Button("Get started") { goForward() }
                    .buttonStyle(ZephyrPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            } else if step == .ready {
                Button("Start using ZephyrFlow") { finish(limited: false) }
                    .buttonStyle(ZephyrPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            } else if stepSatisfied(step) {
                Button("Continue") { goForward() }
                    .buttonStyle(ZephyrPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(primaryActionTitle) {
                    Task { await runPrimaryAction() }
                }
                .buttonStyle(ZephyrPrimaryButtonStyle(enabled: !isRequesting))
                .disabled(isRequesting)
                .keyboardShortcut(.defaultAction)

                if step == .microphone || step == .speech || step == .accessibility {
                    Button("Skip for now") { goForward() }
                        .buttonStyle(ZephyrSecondaryButtonStyle())
                }
            }
        }
    }

    private var primaryActionTitle: String {
        switch step {
        case .microphone: return isRequesting ? "Waiting…" : "Allow Microphone"
        case .speech: return isRequesting ? "Waiting…" : "Allow Speech Recognition"
        case .accessibility: return isRequesting ? "Waiting…" : "Enable Accessibility"
        case .dictation: return "Open Keyboard Settings"
        default: return "Continue"
        }
    }

    // MARK: Actions

    private func runPrimaryAction() async {
        isRequesting = true
        defer { isRequesting = false }
        privacy.refresh()

        switch step {
        case .microphone:
            // Bring app forward so the system sheet attaches cleanly
            WindowRouter.presentForPermissionPrompt()
            let ok = await privacy.requestMicrophone()
            if !ok { privacy.openMicrophoneSettings() }
        case .speech:
            WindowRouter.presentForPermissionPrompt()
            let ok = await privacy.requestSpeechRecognition()
            if !ok { privacy.openSpeechSettings() }
        case .accessibility:
            WindowRouter.presentForPermissionPrompt()
            if !privacy.requestAccessibility() {
                privacy.openAccessibilitySettings()
            }
        case .dictation:
            privacy.openDictationSettings()
        default:
            break
        }
        privacy.refresh()
        if stepSatisfied(step) {
            withAnimation(ZephyrTheme.spring) { goForward() }
        }
    }

    private func stepSatisfied(_ s: Step) -> Bool {
        switch s {
        case .welcome, .ready, .dictation: return true
        case .microphone: return privacy.status.microphone
        case .speech: return privacy.status.speechRecognition
        case .accessibility: return privacy.status.accessibility
        }
    }

    private func goForward() {
        withAnimation(ZephyrTheme.spring) {
            if let next = Step(rawValue: step.rawValue + 1) {
                step = next
            } else {
                finish(limited: false)
            }
        }
    }

    private func goBack() {
        withAnimation(ZephyrTheme.spring) {
            if let prev = Step(rawValue: step.rawValue - 1) {
                step = prev
            }
        }
    }

    private func autoAdvanceIfGranted() {
        guard step == .microphone || step == .speech || step == .accessibility else { return }
        if stepSatisfied(step), !isRequesting {
            // Small delay so user sees the green chip
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                if stepSatisfied(step) {
                    goForward()
                }
            }
        }
    }

    private func advancePastGrantedSteps() {
        // If user already granted everything, land on dictation or ready
        if privacy.status.microphone && privacy.status.speechRecognition && privacy.status.accessibility {
            step = .dictation
        }
    }

    private func finish(limited: Bool) {
        settings.update { $0.hasCompletedOnboarding = true }
        onFinished()
        WindowRouter.closeOnboarding()
        _ = limited
    }
}
