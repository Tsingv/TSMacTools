import Foundation

public struct NativeWindowID: Hashable, Codable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct NativeWindowContent: Equatable, Codable, Sendable {
    public enum Body: Equatable, Codable, Sendable {
        case markdown(String)
        case html(String)
        case plainText(String)
    }

    public var title: String
    public var body: Body

    public init(title: String, body: Body) {
        self.title = title
        self.body = body
    }
}

public enum AutomationCommand: Equatable, Sendable {
    case showWindow(id: NativeWindowID, content: NativeWindowContent)
    case closeWindow(id: NativeWindowID)
    case reloadConfiguration
}
