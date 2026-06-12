import XCTest
import MacToolsCore
import MacToolsScripting

final class PythonScriptBridgeTests: XCTestCase {
    func testDecodeShowWindowCommand() throws {
        let bridge = PythonScriptBridge()
        let data = """
        {
          "command": "window.show",
          "id": "status",
          "title": "Status",
          "format": "markdown",
          "body": "# Ready"
        }
        """.data(using: .utf8)!

        let command = try bridge.decodeCommand(from: data)

        XCTAssertEqual(
            command,
            .showWindow(
                id: NativeWindowID("status"),
                content: NativeWindowContent(title: "Status", body: .markdown("# Ready"))
            )
        )
    }

    func testDecodeCloseWindowCommand() throws {
        let bridge = PythonScriptBridge()
        let data = #"{"command":"window.close","id":"status"}"#.data(using: .utf8)!

        XCTAssertEqual(
            try bridge.decodeCommand(from: data),
            .closeWindow(id: NativeWindowID("status"))
        )
    }

    func testDecodeUsesLastJSONCommandAfterLogOutput() throws {
        let bridge = PythonScriptBridge()
        let data = """
        debug: script started
        {"command":"window.close","id":"status"}
        """.data(using: .utf8)!

        XCTAssertEqual(
            try bridge.decodeCommand(from: data),
            .closeWindow(id: NativeWindowID("status"))
        )
    }
}

private struct FakePermissionChecker: SystemPermissionChecking {
    var snapshotValue: SystemPermissionSnapshot

    func snapshot() -> SystemPermissionSnapshot {
        snapshotValue
    }

    func requestAccessibilityPrompt() -> Bool {
        false
    }
}

final class AutomationRuntimePermissionTests: XCTestCase {
    @MainActor
    func testPermissionSnapshotUsesInjectedChecker() {
        let runtime = AutomationRuntime(
            windowManager: RecordingWindowManager(),
            permissionChecker: FakePermissionChecker(
                snapshotValue: SystemPermissionSnapshot(accessibility: .missing)
            )
        )

        XCTAssertEqual(runtime.permissionSnapshot().accessibility, .missing)
    }
}

@MainActor
private final class RecordingWindowManager: WindowManaging {
    func showWindow(id: NativeWindowID, content: NativeWindowContent) {}
    func closeWindow(id: NativeWindowID) {}
}
