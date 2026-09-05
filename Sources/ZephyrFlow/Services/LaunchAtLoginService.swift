import AppKit
import Combine
import Foundation
import ServiceManagement
import ZephyrFlowCore

// JOE-2290: Launch at Login transaction service — authoritative SMAppService
// status, pending/commit/rollback semantics, typed diagnostics, recovery.
@MainActor
final class LaunchAtLoginService: ObservableObject {
    static let shared = LaunchAtLoginService()

    @Published private(set) var transaction = LaunchAtLoginTransaction()
    @Published private(set) var lastError: String?
    @Published private(set) var systemStatus: LaunchAtLoginState = .unsupported
    @Published private(set) var needsReconciliation = false
    private let readStatus: @MainActor () -> LaunchAtLoginState
    private let register: @MainActor () async throws -> Void
    private let unregister: @MainActor () async throws -> Void

    init(
        readStatus: @escaping @MainActor () -> LaunchAtLoginState = { LaunchAtLoginService.serviceStatus() },
        register: @escaping @MainActor () async throws -> Void = { try SMAppService.mainApp.register() },
        unregister: @escaping @MainActor () async throws -> Void = { try await SMAppService.mainApp.unregister() }
    ) {
        self.readStatus = readStatus
        self.register = register
        self.unregister = unregister
    }

    private static func serviceStatus() -> LaunchAtLoginState {
        switch SMAppService.mainApp.status {
        case .enabled: return .registered
        case .notRegistered: return .notRegistered
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        default: return .unsupported
        }
    }

    @discardableResult
    func authoritativeStatus() -> LaunchAtLoginState {
        let status = readStatus()
        systemStatus = status
        return status
    }

    /// Read-only reconciliation: never register, unregister or rewrite settings
    /// on launch/activation. An external revocation is not permission to reapply.
    func refresh(persistedEnabled: Bool) {
        let status = authoritativeStatus()
        guard !transaction.isPending else { return }
        needsReconciliation = !LaunchAtLoginTransaction.statusConverges(
            status: status, desiredEnabled: persistedEnabled)
        if needsReconciliation {
            lastError = availabilityMessage() ?? AppStrings.key("login.reconciliation.required")
        } else if lastError == AppStrings.key("login.reconciliation.required") {
            lastError = nil
        }
    }

    /// A saved desire is not evidence of enabled system registration.
    var observedEnabled: Bool { systemStatus == .registered }

    /// Transactional toggle: pending -> register/unregister -> verify ->
    /// commit or rollback. Settings JSON is committed ONLY after verification.
    func apply(enabled: Bool, commitSetting: @MainActor (Bool) -> Bool) async -> LaunchAtLoginTransactionState {
        // Global admission, not just one view's disabled Toggle. A second
        // caller may observe pending but cannot persist a dropped operation.
        guard !transaction.isPending else { return .pending }
        let previous = authoritativeStatus()
        var tx = LaunchAtLoginTransaction()
        tx.begin(desiredEnabled: enabled)
        transaction = tx
        lastError = nil
        needsReconciliation = false

        do {
            if !LaunchAtLoginTransaction.statusConverges(status: previous, desiredEnabled: enabled) {
                if enabled { try await register() } else { try await unregister() }
            }
        } catch {
            let reason = AppStrings.key("login.change.failed")
            tx.rollback(reason: reason)
            transaction = tx
            lastError = reason
            needsReconciliation = authoritativeStatus() != previous
            ZFLog.error("Launch at login operation failed")
            return tx.state
        }

        // Verify the resulting status converges with the desired value.
        let status = authoritativeStatus()
        if LaunchAtLoginTransaction.statusConverges(status: status, desiredEnabled: enabled) {
            if commitSetting(enabled) {
                tx.commit(verifiedStatus: status)
            } else {
                // Restore only a known prior on/off registration if our
                // external mutation succeeded but settings persistence failed.
                // Approval/unknown states cannot be reconstructed safely.
                if status != previous {
                    do {
                        if previous == .registered {
                            try await register()
                        } else if previous == .notRegistered {
                            try await unregister()
                        }
                    } catch { ZFLog.error("Launch at login compensation failed") }
                }
                needsReconciliation = authoritativeStatus() != previous
                let reason = AppStrings.key(
                    needsReconciliation ? "login.reconciliation.required" : "settings.persistence.failed")
                tx.rollback(reason: reason)
                lastError = reason
            }
        } else {
            tx.rollback(reason: "status did not converge: \(status.rawValue)")
            lastError = availabilityMessage() ?? AppStrings.key("login.change.failed")
            needsReconciliation = status != previous
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
        // Presentation reads the last explicit observation; never publish a
        // new observation as a side effect of evaluating a SwiftUI body.
        switch systemStatus {
        case .notFound:
            return AppStrings.key("login.unavailable")
        case .unsupported, .denied:
            return AppStrings.key("login.unsupported")
        case .requiresApproval:
            return AppStrings.key("login.approval")
        default:
            return nil
        }
    }
}
