import AppKit
import MacToolsCore
import MacToolsScripting

@MainActor
final class NativeWindowManager: WindowManaging {
    private var windows: [NativeWindowID: NSWindow] = [:]

    func showWindow(id: NativeWindowID, content: NativeWindowContent) {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
        textView.isEditable = false
        textView.isRichText = true
        textView.textContainerInset = NSSize(width: 18, height: 18)
        textView.font = .systemFont(ofSize: 14)
        textView.string = render(content.body)
        if case let .markdown(markdown) = content.body,
           let data = markdown.data(using: .utf8),
           let attributed = try? NSAttributedString(
            markdown: data,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
           ) {
            textView.textStorage?.setAttributedString(attributed)
        }

        let scrollView = NSScrollView(frame: textView.frame)
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView

        let window = windows[id] ?? NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 640, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = content.title
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        windows[id] = window
    }

    func closeWindow(id: NativeWindowID) {
        windows[id]?.close()
        windows[id] = nil
    }

    private func render(_ body: NativeWindowContent.Body) -> String {
        switch body {
        case let .markdown(value), let .html(value), let .plainText(value):
            return value
        }
    }
}

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var runtime: AutomationRuntime?
    private var configurationBootstrap: UserConfigurationBootstrapResult?
    private var hotkeyController: GlobalHotkeyController?
    private var windowSwitcherController: WindowSwitcherController?

    static func main() {
        if CommandLine.arguments.contains("--check-accessibility") {
            let status = AccessibilityPermissionClient().snapshot().accessibility
            print("accessibility=\(status == .granted ? "granted" : "missing")")
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let manager = NativeWindowManager()
        let permissionClient = AccessibilityPermissionClient()
        configurationBootstrap = try? UserConfigurationStore().bootstrap()
        runtime = AutomationRuntime(
            windowManager: manager,
            permissionChecker: permissionClient
        )
        if let runtime, let configuration = configurationBootstrap?.configuration {
            windowSwitcherController = WindowSwitcherController(runtime: runtime, configuration: configuration)
            windowSwitcherController?.start()
            hotkeyController = GlobalHotkeyController(
                runtime: runtime,
                configuration: configuration,
                windowSwitcherController: windowSwitcherController
            )
            hotkeyController?.start()
        }

        let configPath = configurationBootstrap?.configURL.path ?? "~/.config/tsmactool/config.json"
        let scriptsPath = configurationBootstrap?.scriptsDirectoryURL.path ?? "~/.config/tsmactool/scripts"
        let permissions = runtime?.permissionSnapshot()
        if permissions?.accessibility == .granted {
            runtime?.handle(.showWindow(
                id: NativeWindowID("welcome"),
                content: NativeWindowContent(
                    title: "TSMacTools",
                    body: .markdown("""
                    # TSMacTools

                    Runtime started.

                    Configuration: `\(configPath)`

                    Scripts: `\(scriptsPath)`

                    Python script commands can drive native windows through the typed command protocol.
                    """)
                )
            ))
        } else {
            runtime?.requestAccessibilityPermissionPrompt()
            runtime?.handle(.showWindow(
                id: NativeWindowID("permissions"),
                content: NativeWindowContent(
                    title: "TSMacTools Permissions",
                    body: .markdown("""
                    # Accessibility Required

                    Accessibility permission is required for window management, hotkeys, and event capture.

                    Grant TSMacTools access in System Settings > Privacy & Security > Accessibility, then restart the app.

                    Configuration: `\(configPath)`
                    """)
                )
            ))
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
