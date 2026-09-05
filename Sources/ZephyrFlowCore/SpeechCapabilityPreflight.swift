import Foundation

/// Controlled recovery categories; no framework description or transcript
/// enters preparation UI. Capability checks never request permissions.
public enum SpeechCapabilityFailure: Error, Sendable, Equatable {
    case speechAuthorizationRequired, microphoneAuthorizationRequired
    case languageUnavailable, onDeviceUnavailable, recognizerUnavailable

    public var message: String {
        switch self {
        case .speechAuthorizationRequired: return AppStrings.key("engine.capability.speechpermission")
        case .microphoneAuthorizationRequired: return AppStrings.key("engine.capability.microphonepermission")
        case .languageUnavailable: return AppStrings.key("engine.capability.language")
        case .onDeviceUnavailable: return AppStrings.key("engine.capability.ondevice")
        case .recognizerUnavailable: return AppStrings.key("engine.capability.unavailable")
        }
    }
}

public struct SpeechReadinessCapabilities: Sendable, Equatable {
    public let speechAuthorized: Bool
    public let microphoneAuthorized: Bool
    public let requestedLocaleAvailable: Bool
    public let recognizerAvailable: Bool
    public let supportsOnDevice: Bool

    public init(
        speechAuthorized: Bool, microphoneAuthorized: Bool,
        requestedLocaleAvailable: Bool, recognizerAvailable: Bool, supportsOnDevice: Bool
    ) {
        self.speechAuthorized = speechAuthorized
        self.microphoneAuthorized = microphoneAuthorized
        self.requestedLocaleAvailable = requestedLocaleAvailable
        self.recognizerAvailable = recognizerAvailable
        self.supportsOnDevice = supportsOnDevice
    }

    /// Returns whether recognition must run on device. Even with Local Only
    /// off, prefer on-device recognition when the selected locale supports it.
    public func validate(localOnly: Bool) throws -> Bool {
        guard speechAuthorized else { throw SpeechCapabilityFailure.speechAuthorizationRequired }
        guard microphoneAuthorized else { throw SpeechCapabilityFailure.microphoneAuthorizationRequired }
        guard requestedLocaleAvailable else { throw SpeechCapabilityFailure.languageUnavailable }
        guard !localOnly || supportsOnDevice else { throw SpeechCapabilityFailure.onDeviceUnavailable }
        guard recognizerAvailable else { throw SpeechCapabilityFailure.recognizerUnavailable }
        return supportsOnDevice
    }
}
