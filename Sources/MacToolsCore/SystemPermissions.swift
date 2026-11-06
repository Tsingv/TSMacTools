import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation

public enum SystemPermissionKind: String, CaseIterable, Codable, Sendable {
    case accessibility
    case inputMonitoring
    case screenRecording
    case automation
}

public enum SystemPermissionStatus: Equatable, Codable, Sendable {
    case granted
    case missing
    case unknown
}

public struct SystemPermissionSnapshot: Equatable, Codable, Sendable {
    public var accessibility: SystemPermissionStatus
    public var screenRecording: SystemPermissionStatus

    public init(
        accessibility: SystemPermissionStatus,
        screenRecording: SystemPermissionStatus = .unknown
    ) {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
    }
}

public protocol SystemPermissionChecking: Sendable {
    func snapshot() -> SystemPermissionSnapshot
    @discardableResult
    func requestAccessibilityPrompt() -> Bool
}

public struct AccessibilityPermissionClient: SystemPermissionChecking {
    public init() {}

    public func snapshot() -> SystemPermissionSnapshot {
        SystemPermissionSnapshot(
            accessibility: AXIsProcessTrusted() ? .granted : .missing,
            screenRecording: ScreenRecordingPermission.status()
        )
    }

    @discardableResult
    public func requestAccessibilityPrompt() -> Bool {
        let options = [
            "AXTrustedCheckOptionPrompt": true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

public enum ScreenRecordingPermission {
    public static let authorizationGuidance =
        "Click Allow on the system prompt if it appears. Otherwise enable TSMacTools in System Settings ▸ Privacy & Security ▸ Screen Recording, then relaunch the app."

    public static let microphoneGuidance =
        "macOS only lists TSMacTools under Microphone after the system Allow dialog. The app cannot be added manually. If Request Access opens Settings but the list has no TSMacTools entry, fully quit the app, run `tccutil reset Microphone local.clearain.MacTools`, relaunch, then click Request Access again and choose Allow on the dialog."

    public static func status() -> SystemPermissionStatus {
        CGPreflightScreenCaptureAccess() ? .granted : .missing
    }

    /// Presents the system Screen Recording consent UI when TCC still allows a prompt.
    /// Returns true only when access is granted afterward.
    @discardableResult
    public static func requestAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        // Prefer the dedicated Screen Capture prompt before opening Settings.
        _ = CGRequestScreenCaptureAccess()
        return CGPreflightScreenCaptureAccess()
    }
}

public enum MicrophonePermission {
    public enum AuthorizationState: String, Sendable {
        case authorized
        case denied
        case restricted
        case notDetermined
        case unknown

        public var systemStatus: SystemPermissionStatus {
            switch self {
            case .authorized:
                return .granted
            case .denied, .restricted:
                return .missing
            case .notDetermined, .unknown:
                return .unknown
            }
        }

        public var displayName: String {
            switch self {
            case .authorized: "authorized"
            case .denied: "denied"
            case .restricted: "restricted"
            case .notDetermined: "notDetermined"
            case .unknown: "unknown"
            }
        }
    }

    public static func authorizationState() -> AuthorizationState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .unknown
        }
    }

    public static func status() -> SystemPermissionStatus {
        authorizationState().systemStatus
    }

    /// Shows the native microphone prompt while status is undetermined.
    /// Uses both `requestAccess` and a temporary capture-input probe because
    /// menu-bar apps sometimes skip the sheet when only the API request runs.
    /// Does not open System Settings.
    @MainActor
    public static func requestAccess() async -> Bool {
        let state = authorizationState()
        switch state {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined, .unknown:
            break
        }

        _ = AVCaptureDevice.default(for: .audio)
        let apiGranted = await AVCaptureDevice.requestAccess(for: .audio)
        if apiGranted || authorizationState() == .authorized {
            return true
        }

        // If the sheet still did not settle into authorized/denied, force a device-input probe.
        if authorizationState() == .notDetermined || authorizationState() == .unknown {
            _ = await probeCaptureInput()
        }
        return authorizationState() == .authorized
    }

    /// Attempts to attach the default microphone briefly. Creating `AVCaptureDeviceInput`
    /// is what actually registers many apps in the Microphone privacy list.
    @MainActor
    public static func probeCaptureInput() async -> Bool {
        guard let device = AVCaptureDevice.default(for: .audio) else {
            return false
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let session = AVCaptureSession()
                    let input = try AVCaptureDeviceInput(device: device)
                    session.beginConfiguration()
                    if session.canAddInput(input) {
                        session.addInput(input)
                    }
                    session.commitConfiguration()
                    session.startRunning()
                    session.stopRunning()
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }
}
