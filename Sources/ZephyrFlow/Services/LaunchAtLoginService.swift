import AppKit
import Foundation
import ServiceManagement
import ZephyrFlowCore

// JOE-2290: Launch at Login transaction service — authoritative SMAppService
// status, pending/commit/rollback semantics, typed diagnostics, recovery.
@MainActor
final class LaunchAtLoginService {
    static let shared = LaunchAtLoginService()

    private(set) var transaction = LaunchAtLoginTransaction()
    @Published private(set) var lastError: String?

    private init() {}

    func authoritativeStatus() -> LaunchAtLoginState {
        switch SMAppService.mainApp.status {
        case .enabled: return .registered
        case .notRegistered: return .notRegistered
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        default: return .unsupported
        }
    }

    /// Transactional toggle: pending -> register/unregister -> verify ->
    /// commit or rollback. Settings JSON is committed ONLY after verification.
    func apply(enabled: Bool) async -> LaunchAtLoginTransactionState {
        var tx = LaunchAtLoginTransaction()
        tx.begin(desiredEnabled: enabled)
        transaction = tx

        do {
            if enabled {
                try await SMAppService.mainApp.register()
            } else {
                try await SMAppService.mainApp.unregister()
            }
        } catch {
            let reason = (error as NSError).localizedDescription
            tx.rollback(reason: reason)
            transaction = tx
            lastError = reason
            ZFLog.error("Launch at login \(enabled ? "register" : "unregister") failed: \(reason)")
            return tx.state
        }

        // Verify the resulting status converges with the desired value.
        let status = authoritativeStatus()
        if LaunchAtLoginTransaction.statusConverges(status: status, desiredEnabled: enabled) {
            tx.commit(verifiedStatus: status)
        } else {
            tx.rollback(reason: "status did not converge: \(status.rawValue)")
            lastError = "Login item change needs approval or is unavailable (status: \(status.rawValue))"
            ZFLog.error("Launch at login status did not converge: \(status.rawValue)")
        }
        transaction = tx
        return tx.state
    }

    /// Recovery: open Login Items settings when user approval is required.
    func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Development/unpackaged builds: explain why the control is unavailable.
    func availabilityMessage() -> String? {
        switch authoritativeStatus() {
        case .notFound:
            return "Launch at login is unavailable in this unpackaged development build."
        case .unsupported, .denied:
            return "Launch at login is not supported in this environment."
        case .requiresApproval:
            return "Approval required — open Login Items settings to confirm."
        default:
            return nil
        }
    }
}
