import ApplicationServices
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

    public init(accessibility: SystemPermissionStatus) {
        self.accessibility = accessibility
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
            accessibility: AXIsProcessTrusted() ? .granted : .missing
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
