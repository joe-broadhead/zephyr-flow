import Foundation
import ZephyrFlowCore

// JOE-2243: production AppEnvironment assembly — composed ONCE at launch.
// UI/infrastructure singletons (panel, readiness, focus, privacy, hotkey)
// remain the production providers; session-domain code receives them through
// the environment boundary.
extension AppEnvironment {
    @MainActor
    static func production() -> AppEnvironment {
        AppEnvironment(
            clock: SystemClock(),
            sleeper: SystemSleeper(),
            idGenerator: SystemIDGenerator(),
            metrics: ZFLogMetricsSink(),
            settings: SettingsStoreRepository(),
            history: HistoryStoreRepository(),
            permissions: PrivacyPermissionProvider(),
            engines: EngineRegistry(
                makeWhisper: { WhisperKitEngine() },
                makeAppleSpeech: { AppleSpeechEngine() }),
            flow: FlowRouter.shared,
            insertion: InsertionService.shared,
            targetValidation: TargetValidationService.shared)
    }
}

/// Wall-clock provider (uptime nanos).
struct SystemClock: ClockProviding {
    func nowNanos() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
}

/// Real sleeper.
struct SystemSleeper: Sleeper {
    func sleep(nanoseconds: UInt64) async { try? await Task.sleep(nanoseconds: nanoseconds) }
}

/// UUID-based IDs.
struct SystemIDGenerator: IDGenerating {
    func next() -> UInt64 { UInt64(abs(UUID().hashValue)) }
}

/// Metrics sink logging counts only.
struct ZFLogMetricsSink: MetricsSinking {
    func record(_ event: MetricsEvent) async {
        ZFLog.info("metric kind=\(event.kind.rawValue) value=\(event.value)")
    }
}

/// Settings repository backed by SettingsStore.
@MainActor struct SettingsStoreRepository: SettingsRepository {
    private let read: @MainActor @Sendable () -> AppSettings

    init(read: @escaping @MainActor @Sendable () -> AppSettings = { SettingsStore.shared.settings }) {
        self.read = read
    }

    var current: AppSettings { read() }
}

/// History repository backed by the actor repository (JOE-2261).
struct HistoryStoreRepository: HistoryRepository {
    func add(_ entry: HistoryEntry) async {
        await ActorHistoryRepository.shared.add(entry)
    }
}

/// Permission provider backed by PrivacyService.
@MainActor struct PrivacyPermissionProvider: PermissionProviding {
    private let read: @MainActor @Sendable () -> PermissionStatus

    init(read: @escaping @MainActor @Sendable () -> PermissionStatus = { PrivacyService.shared.status }) {
        self.read = read
    }

    var microphoneGranted: Bool { read().microphone }
    var accessibilityTrusted: Bool { read().accessibility }
    var speechRecognitionGranted: Bool { read().speechRecognition }
}
