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

@MainActor
public final class AutomationRuntime {
    private let windowManager: WindowManaging

    public init(windowManager: WindowManaging) {
        self.windowManager = windowManager
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
}
