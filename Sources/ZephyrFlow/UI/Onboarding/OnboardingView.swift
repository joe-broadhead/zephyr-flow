import SwiftUI
import ZephyrFlowCore

/// Stepped dark setup flow driven by the capability graph (JOE-2282).
/// Steps are derived from the selected product path (engine + insertion),
/// only the missing delta is requested when settings change, every
/// permission/network action is explained, and completed capabilities are
/// persisted (not just a boolean).
struct OnboardingView: View {
    @ObservedObject private var privacy = PrivacyService.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var controller = DictationController.shared
    @ObservedObject private var modelReadiness = ModelReadinessStore.shared
    var onFinished: () -> Void

    @State private var steps: [OnboardingStep] = []
    @State private var index = 0
    @State private var isRequesting = false
    @State private var completed: Set<OnboardingCapability> = []
    @State private var skipNote: String?
    @State private var actionTask: Task<Void, Never>?
    @State private var actionGeneration = UUID()

    private var readiness: OnboardingReadinessSnapshot {
        .init(
            microphone: privacy.status.microphone, speech: privacy.status.speechRecognition,
            accessibility: privacy.status.accessibility, downloadConsent: settings.settings.allowModelDownloads,
            engineLoaded: controller.isSelectedEnginePrepared)
    }

    private var currentCapabilities: Set<OnboardingCapability> {
        Set(completed.filter { readiness.satisfies($0) })
    }

    private var pathReady: Bool {
        CapabilityGraph.isComplete(for: productPath, completed: currentCapabilities.union([.localOnlyImplications]))
    }

    private var current: OnboardingStep? {
        index >= 0 && index < steps.count ? steps[index] : nil
    }

    private var productPath: OnboardingProductPath {
        CapabilityGraph.path(
            model: settings.settings.preferredModel,
            insertionMode: settings.settings.insertionMode.rawValue)
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
                colors: [ZephyrTheme.cyan.opacity(0.10), .clear],
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

                ScrollView {
                    stepContent
                        .padding(.horizontal, 36)
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)
                            )
                        )
                        .id(index)
                }

                Spacer(minLength: 12)

                footer
                    .padding(24)
            }
        }
        .frame(width: 540, height: 580)
        .zephyrDarkChrome()
        .onAppear {
            privacy.refresh()
            modelReadiness.refreshAll()
            rebuildSteps()
        }
        .onDisappear { cancelPendingAction() }
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
            privacy.refresh()
            autoAdvanceIfGranted()
        }
    }

    // MARK: - Graph-driven steps

    private func rebuildSteps() {
        // Synthetic welcome + graph steps for the CURRENT product path.
        var all: [OnboardingStep] = [
            OnboardingStep(
                id: "welcome", capability: .localOnlyImplications,
                title: AppStrings.key("onboarding.welcome.title"),
                explanation:
                    "Hold Fn, speak, release — text appears at your cursor. Local Only is on by default. Steps below ask only for what the selected product path needs.",
                requiresSystemPrompt: false)
        ]
        all.append(contentsOf: CapabilityGraph.steps(for: productPath))
        steps = all
        index = 0
        // Restore previously persisted capabilities.
        completed = Set(
            settings.settings.completedCapabilities.compactMap {
                OnboardingCapability(rawValue: $0)
            })
        skipNote = nil
        advancePastGrantedSteps()
    }

    /// Only the missing delta is requested; already-granted capabilities are
    /// skipped WITHOUT hiding required system switches.
    private func advancePastGrantedSteps() {
        // Skip granted permission steps, never an unread disclosure, a model
        // preparation action, a language check or the final status page.
        while let s = current, s.requiresSystemPrompt, stepSatisfied(s) {
            completed.insert(s.capability)
            index += 1
        }
    }

    private func stepSatisfied(_ s: OnboardingStep) -> Bool {
        readiness.satisfies(s.capability)
    }

    private func icon(for capability: OnboardingCapability) -> String {
        switch capability {
        case .microphone: return "mic.fill"
        case .speechRecognition: return "waveform"
        case .accessibility: return "accessibility"
        case .modelAcquisition, .networkModelDownload: return "cpu"
        case .clipboardDisclosure: return "doc.on.clipboard"
        case .systemDictation: return "keyboard"
        case .languageAvailability: return "globe"
        case .localOnlyImplications: return "lock.shield"
        case .networkUpdateCheck: return "arrow.triangle.2.circlepath"
        }
    }

    // MARK: - Content

    private var progressBar: some View {
        HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, _ in
                Capsule()
                    .fill(i <= index ? ZephyrTheme.cyan : ZephyrTheme.border)
                    .frame(height: 3)
                    .animation(ZephyrTheme.spring, value: index)
            }
        }
    }

    private var stepContent: some View {
        VStack(spacing: 22) {
            Group {
                if current?.id == "welcome" || current?.id == "ready" {
                    ZephyrMarkBadge(size: 88)
                } else if let current {
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
                                Image(systemName: icon(for: current.capability))
                                    .font(.system(size: 32, weight: .semibold))
                                    .foregroundStyle(ZephyrTheme.brandGradient)
                            )
                    }
                }
            }

            VStack(spacing: 10) {
                Text(
                    current?.id == "ready" && !pathReady
                        ? AppStrings.key("onboarding.limited.title")
                        : current.map { AppStrings.key($0.titleKey) } ?? ""
                )
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(ZephyrTheme.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

                Text(
                    current?.id == "ready" && !pathReady
                        ? AppStrings.key("onboarding.limited.explanation")
                        : current.map { AppStrings.key($0.explanationKey) } ?? ""
                )
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundStyle(ZephyrTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let current, current.id != "welcome", current.id != "ready" {
                statusChip(for: current.capability)
            }

            if current?.capability == .modelAcquisition {
                Picker(
                    AppStrings.key("settings.section.model"),
                    selection: Binding(
                        get: { settings.settings.preferredModel },
                        set: { model in
                            cancelPendingAction()
                            controller.cancelModelPreparation()
                            settings.update { $0.preferredModel = model }
                        })
                ) {
                    ForEach(ModelIdentifier.allCases.filter(\.isWhisperKit)) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                Text(settings.settings.preferredModel.detail).font(.caption)
                Text(AppStrings.key("engine.downloads.disclosure")).font(.caption2)
                    .foregroundStyle(ZephyrTheme.textSecondary)
                Button(AppStrings.key("engine.preparation.apple")) { useAppleSpeech() }
            }
            if current?.capability == .modelAcquisition || current?.capability == .languageAvailability {
                if let message = controller.statusMessage { Text(message).font(.caption) }
                if isRequesting {
                    ProgressView(AppStrings.key("engine.preparation.progress"))
                    Button(AppStrings.key("engine.preparation.cancel")) {
                        cancelPendingAction()
                        controller.cancelModelPreparation()
                    }
                }
            }

            if let skipNote {
                Text(skipNote)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(ZephyrTheme.warning)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
        }
    }

    private func statusChip(for capability: OnboardingCapability) -> some View {
        let satisfied = readiness.satisfies(capability)
        let isEngine = capability == .modelAcquisition || capability == .languageAvailability
        let label =
            isEngine
            ? AppStrings.key(satisfied ? "engine.preparation.ready" : "engine.preparation.notloaded")
            : AppStrings.key(satisfied ? "onboarding.granted" : "onboarding.notGranted")
        return Label(
            label,
            systemImage: satisfied ? "checkmark.seal.fill" : "circle.dashed"
        )
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(satisfied ? ZephyrTheme.cyan : ZephyrTheme.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(ZephyrTheme.bgCard.opacity(0.8)))
        .accessibilityLabel(label)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if index > 0 {
                Button(AppStrings.key("onboarding.back")) { goBack() }
                    .buttonStyle(ZephyrSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }

            Spacer()

            if current?.id == "welcome" {
                Button(AppStrings.key("onboarding.getStarted")) { goForward() }
                    .buttonStyle(ZephyrPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            } else if current?.id == "ready" {
                Button(AppStrings.key(pathReady ? "onboarding.startUsing" : "onboarding.limited.continue")) { finish() }
                    .buttonStyle(ZephyrPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            } else if let current {
                Button(primaryActionTitle(for: current)) {
                    let id = UUID()
                    actionGeneration = id
                    actionTask = Task { await runPrimaryAction(current, generation: id) }
                }
                .buttonStyle(ZephyrPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(isRequesting)

                if current.skippable {
                    Button(AppStrings.key("onboarding.skip")) {
                        cancelPendingAction()
                        let skip = CapabilityGraph.skipExplanation(for: productPath, step: current)
                        skipNote = skip.limitations
                        completed.remove(current.capability)
                        goForward()
                    }
                    .buttonStyle(ZephyrSecondaryButtonStyle())
                }
            }
        }
    }

    private func primaryActionTitle(for step: OnboardingStep) -> String {
        switch step.capability {
        case .microphone: return AppStrings.key("onboarding.allowMic")
        case .speechRecognition: return AppStrings.key("onboarding.allowSpeech")
        case .accessibility: return AppStrings.key("onboarding.enableAX")
        case .modelAcquisition:
            if controller.isSelectedEnginePrepared { return AppStrings.key("onboarding.continue") }
            if modelReadiness.readiness(for: settings.settings.preferredModel).state.isReady {
                return AppStrings.key("onboarding.preparelocal")
            }
            return AppStrings.key(
                settings.settings.allowModelDownloads ? "engine.preparation.retry" : "onboarding.downloadModel")
        case .languageAvailability: return AppStrings.key("onboarding.checklanguage")
        default: return AppStrings.key("onboarding.continue")
        }
    }

    // MARK: - Actions

    private func runPrimaryAction(_ step: OnboardingStep, generation: UUID) async {
        guard !Task.isCancelled, generation == actionGeneration, current?.id == step.id else { return }
        let selectedModel = settings.settings.preferredModel
        isRequesting = true
        defer {
            if generation == actionGeneration {
                isRequesting = false
                actionTask = nil
            }
        }
        privacy.refresh()

        switch step.capability {
        case .microphone:
            WindowRouter.presentForPermissionPrompt()
            let ok = await privacy.requestMicrophone()
            if !ok { privacy.openMicrophoneSettings() }
        case .speechRecognition:
            WindowRouter.presentForPermissionPrompt()
            let ok = await privacy.requestSpeechRecognition()
            if !ok { privacy.openSpeechSettings() }
        case .accessibility:
            WindowRouter.presentForPermissionPrompt()
            if !privacy.requestAccessibility() {
                privacy.openAccessibilitySettings()
            }
        case .modelAcquisition:
            // Explicit download consent (independent of Local Only audio).
            if !controller.isSelectedEnginePrepared {
                if !modelReadiness.readiness(for: selectedModel).state.isReady {
                    settings.update { $0.allowModelDownloads = true }
                }
                _ = await controller.prepareSelectedEngine(retry: true)
            }
        case .networkModelDownload:
            settings.update { $0.allowModelDownloads = true }
        case .languageAvailability:
            _ = await controller.prepareSelectedEngine(retry: true)
        default:
            break
        }
        privacy.refresh()
        guard !Task.isCancelled, generation == actionGeneration, current?.id == step.id,
            settings.settings.preferredModel == selectedModel
        else { return }

        // Only advance when the step's requirement is satisfied (or it is an
        // informational step). Otherwise the user stays with an actionable
        // limited mode — never a dead end.
        if stepSatisfied(step) {
            completed.insert(step.capability)
            withAnimation(ZephyrTheme.spring) { goForward() }
        }
    }

    private func goForward() {
        withAnimation(ZephyrTheme.spring) {
            if index + 1 < steps.count {
                index += 1
                advancePastGrantedSteps()
            } else {
                finish()
            }
        }
    }

    private func goBack() {
        cancelPendingAction()
        skipNote = nil
        withAnimation(ZephyrTheme.spring) {
            if index > 0 { index -= 1 }
        }
    }

    private func autoAdvanceIfGranted() {
        guard let s = current, s.requiresSystemPrompt else { return }
        if stepSatisfied(s), !isRequesting {
            completed.insert(s.capability)
            goForward()
        }
    }

    /// Persist completed capabilities (not merely a boolean); the onboarding
    /// boolean is derived from graph completeness for the current path.
    private func finish() {
        cancelPendingAction()
        let confirmed = currentCapabilities.union([.localOnlyImplications])
        settings.update {
            $0.completedCapabilities = Array(confirmed.map(\.rawValue)).sorted()
            $0.hasCompletedOnboarding = CapabilityGraph.isComplete(
                for: productPath, completed: confirmed)
        }
        onFinished()
        WindowRouter.closeOnboarding()
    }

    private func cancelPendingAction() {
        actionGeneration = UUID()
        actionTask?.cancel()
        actionTask = nil
        isRequesting = false
    }

    private func useAppleSpeech() {
        cancelPendingAction()
        controller.cancelModelPreparation()
        settings.update { $0.preferredModel = .appleSpeech }
        rebuildSteps()
        index = 1
        advancePastGrantedSteps()
    }
}
