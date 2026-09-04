import AVFoundation
import AppKit
import ApplicationServices
import Foundation
import Speech
import ZephyrFlowCore

@MainActor
final class PrivacyService: ObservableObject {
    static let shared = PrivacyService()

    @Published private(set) var status: PermissionStatus = .unknown

    private init() {
        refresh()
    }

    func refresh() {
        status = PermissionStatus(
            microphone: microphoneGranted,
            accessibility: accessibilityGranted,
            speechRecognition: speechGranted
        )
    }

    var microphoneGranted: Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        default: return false
        }
    }

    var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    var speechGranted: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    @discardableResult
    func requestMicrophone() async -> Bool {
        let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                cont.resume(returning: ok)
            }
        }
        refresh()
        return granted
    }

    @discardableResult
    func requestSpeechRecognition() async -> Bool {
        let current = SFSpeechRecognizer.authorizationStatus()
        if current == .authorized {
            refresh()
            return true
        }
        if current == .denied || current == .restricted {
            refresh()
            return false
        }
        // .notDetermined — ensure we're active so the system dialog can show
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        refresh()
        return granted
    }

    /// Prompts the user with the system accessibility trust dialog when possible.
    @discardableResult
    func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        refresh()
        return trusted
    }

    func openMicrophoneSettings() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    func openAccessibilitySettings() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openSpeechSettings() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
    }

    /// System Dictation master switch (required for SFSpeechRecognizer / Apple Speech).
    func openDictationSettings() {
        // macOS Ventura+ Keyboard settings; fall back to legacy speech pane.
        let candidates = [
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Dictation",
            "x-apple.systempreferences:com.apple.preference.keyboard?Dictation",
            "x-apple.systempreferences:com.apple.preference.speech",
        ]
        for s in candidates {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }

    private func openSettings(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
