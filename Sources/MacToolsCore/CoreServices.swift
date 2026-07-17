import Foundation

@MainActor
public protocol WindowManaging: AnyObject {
    func showWindow(id: NativeWindowID, content: NativeWindowContent)
    func closeWindow(id: NativeWindowID)
}

public protocol HotkeyCapturing: AnyObject {
    func start() throws
    func stop()
}

public protocol SystemEventObserving: AnyObject {
    func start() throws
    func stop()
}

public enum WindowPresence: Equatable, Sendable {
    case present
    case absent
    case indeterminate
}

public enum WindowAbsenceDecision: Equatable, Sendable {
    case cancel
    case retry
    case restorePreviousApplication
}

public struct WindowAbsenceConfirmation: Equatable, Sendable {
    public let requiredConsecutiveAbsences: Int
    public private(set) var consecutiveAbsences = 0

    public init(requiredConsecutiveAbsences: Int = 3) {
        precondition(requiredConsecutiveAbsences > 0)
        self.requiredConsecutiveAbsences = requiredConsecutiveAbsences
    }

    public mutating func observe(_ presence: WindowPresence) -> WindowAbsenceDecision {
        switch presence {
        case .present:
            consecutiveAbsences = 0
            return .cancel
        case .indeterminate:
            consecutiveAbsences = 0
            return .retry
        case .absent:
            consecutiveAbsences += 1
            return consecutiveAbsences >= requiredConsecutiveAbsences
                ? .restorePreviousApplication
                : .retry
        }
    }
}

@MainActor
public final class AutomationRuntime {
    private let windowManager: WindowManaging
    private let permissionChecker: (any SystemPermissionChecking)?

    public init(
        windowManager: WindowManaging,
        permissionChecker: (any SystemPermissionChecking)? = nil
    ) {
        self.windowManager = windowManager
        self.permissionChecker = permissionChecker
    }

    public func handle(_ command: AutomationCommand) {
        switch command {
        case let .showWindow(id, content):
            windowManager.showWindow(id: id, content: content)
        case let .closeWindow(id):
            windowManager.closeWindow(id: id)
        case .reloadConfiguration:
            break
        }
    }

    public func permissionSnapshot() -> SystemPermissionSnapshot {
        permissionChecker?.snapshot() ?? SystemPermissionSnapshot(accessibility: .unknown)
    }

    @discardableResult
    public func requestAccessibilityPermissionPrompt() -> Bool {
        permissionChecker?.requestAccessibilityPrompt() ?? false
    }
}
