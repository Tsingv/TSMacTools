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

public struct WindowActivationCapturePolicy: Equatable, Sendable {
    public let retryDelays: [TimeInterval]

    public init(retryDelays: [TimeInterval] = [0.05, 0.18, 0.45]) {
        precondition(!retryDelays.isEmpty)
        precondition(retryDelays.allSatisfy { $0 >= 0 })
        self.retryDelays = retryDelays
    }

    public func shouldCapture(
        expectedProcessIdentifier: Int32,
        frontmostProcessIdentifier: Int32?,
        generation: UInt64,
        currentGeneration: UInt64,
        completedGeneration: UInt64? = nil
    ) -> Bool {
        generation == currentGeneration
            && completedGeneration != generation
            && frontmostProcessIdentifier == expectedProcessIdentifier
    }
}

public enum WindowSwitcherWindowState: Equatable, Sendable {
    case active
    case dormant
    case indeterminate
    case destroyed
}

public enum WindowSwitcherCandidateOrderingPolicy {
    public static func orderedKeys(
        recentKeys: [String],
        enumeratedKeys: [String],
        stateByKey: [String: WindowSwitcherWindowState],
        frontmostKey: String?
    ) -> [String] {
        let viableRecentKeys = recentKeys.filter {
            stateByKey[$0] != nil && stateByKey[$0] != .destroyed
        }
        let recentSet = Set(viableRecentKeys)
        let activeRecentKeys = viableRecentKeys.filter { stateByKey[$0] != .dormant }
        let dormantRecentKeys = viableRecentKeys.filter { stateByKey[$0] == .dormant }
        var result = activeRecentKeys
            + enumeratedKeys.filter { !recentSet.contains($0) }
            + dormantRecentKeys

        if let frontmostKey,
           let currentIndex = result.firstIndex(of: frontmostKey) {
            result.remove(at: currentIndex)
            result.insert(frontmostKey, at: 0)
        }
        return result
    }
}

public enum WindowSwitcherSelectionPolicy {
    public static func previousIndex(currentIndex: Int, choiceCount: Int) -> Int? {
        guard choiceCount > 0, (0..<choiceCount).contains(currentIndex) else {
            return nil
        }
        return (currentIndex - 1 + choiceCount) % choiceCount
    }
}

public struct WindowSwitcherBackwardRepeatPolicy: Equatable, Sendable {
    public let initialDelay: TimeInterval
    public let repeatInterval: TimeInterval

    public init(initialDelay: TimeInterval, repeatInterval: TimeInterval) {
        precondition(initialDelay >= 0)
        precondition(repeatInterval > 0)
        self.initialDelay = initialDelay
        self.repeatInterval = repeatInterval
    }
}

public struct WindowSwitcherCommandModifierIsolation: Equatable, Sendable {
    public enum Input: Equatable, Sendable {
        case commandDown
        case commandUp
        case switcherKeyDown
        case other
    }

    public enum Action: Equatable, Sendable {
        case passCurrent
        case deferCurrent
        case replayDeferredAndCurrent
        case suppressCurrent
    }

    private var hasDeferredCommandDown = false
    private var hidesCommandForSwitcher = false

    public init() {}

    public mutating func handle(_ input: Input) -> Action {
        switch input {
        case .commandDown:
            guard !hidesCommandForSwitcher else {
                return .suppressCurrent
            }
            hasDeferredCommandDown = true
            return .deferCurrent
        case .switcherKeyDown:
            guard hasDeferredCommandDown else {
                return .passCurrent
            }
            hasDeferredCommandDown = false
            hidesCommandForSwitcher = true
            return .suppressCurrent
        case .commandUp:
            if hidesCommandForSwitcher {
                hidesCommandForSwitcher = false
                return .suppressCurrent
            }
            if hasDeferredCommandDown {
                hasDeferredCommandDown = false
                return .replayDeferredAndCurrent
            }
            return .passCurrent
        case .other:
            guard hasDeferredCommandDown else {
                return .passCurrent
            }
            hasDeferredCommandDown = false
            return .replayDeferredAndCurrent
        }
    }

    public mutating func expireDeferredCommandDown() -> Bool {
        guard hasDeferredCommandDown else {
            return false
        }
        hasDeferredCommandDown = false
        return true
    }

    public mutating func reset() -> Bool {
        let shouldReplayDeferredCommandDown = hasDeferredCommandDown
        hasDeferredCommandDown = false
        hidesCommandForSwitcher = false
        return shouldReplayDeferredCommandDown
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
