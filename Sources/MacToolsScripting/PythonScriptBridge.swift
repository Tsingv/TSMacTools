import Foundation
import MacToolsCore

public enum ScriptBridgeError: Error, Equatable {
    case invalidCommand(String)
    case missingField(String)
}

public struct PythonScriptBridge {
    public init() {}

    public func decodeCommand(from data: Data) throws -> AutomationCommand {
        if let command = try? decodeSingleCommand(from: data) {
            return command
        }

        let commandData: Data
        let lines = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let lastLine = lines.last {
            commandData = Data(lastLine.utf8)
        } else {
            commandData = data
        }

        return try decodeSingleCommand(from: commandData)
    }

    private func decodeSingleCommand(from data: Data) throws -> AutomationCommand {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any],
              let command = dictionary["command"] as? String else {
            throw ScriptBridgeError.missingField("command")
        }

        switch command {
        case "window.show":
            guard let id = dictionary["id"] as? String else {
                throw ScriptBridgeError.missingField("id")
            }
            guard let title = dictionary["title"] as? String else {
                throw ScriptBridgeError.missingField("title")
            }
            guard let body = dictionary["body"] as? String else {
                throw ScriptBridgeError.missingField("body")
            }
            let format = dictionary["format"] as? String ?? "plainText"
            let contentBody: NativeWindowContent.Body
            switch format {
            case "markdown":
                contentBody = .markdown(body)
            case "html":
                contentBody = .html(body)
            case "plainText":
                contentBody = .plainText(body)
            default:
                throw ScriptBridgeError.invalidCommand("unsupported format: \(format)")
            }
            return .showWindow(
                id: NativeWindowID(id),
                content: NativeWindowContent(title: title, body: contentBody)
            )
        case "window.close":
            guard let id = dictionary["id"] as? String else {
                throw ScriptBridgeError.missingField("id")
            }
            return .closeWindow(id: NativeWindowID(id))
        case "config.reload":
            return .reloadConfiguration
        default:
            throw ScriptBridgeError.invalidCommand(command)
        }
    }
}
