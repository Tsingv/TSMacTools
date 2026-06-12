import AppKit
import MacToolsCore
import MacToolsScripting

@MainActor
final class NativeWindowManager: WindowManaging {
    private var windows: [NativeWindowID: NSWindow] = [:]

    func showWindow(id: NativeWindowID, content: NativeWindowContent) {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
        textView.isEditable = false
        textView.string = render(content.body)

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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var runtime: AutomationRuntime?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let manager = NativeWindowManager()
        runtime = AutomationRuntime(windowManager: manager)
        runtime?.handle(.showWindow(
            id: NativeWindowID("welcome"),
            content: NativeWindowContent(
                title: "MacTools",
                body: .plainText("MacTools runtime started. Python script commands will drive native windows here.")
            )
        ))
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.activate(ignoringOtherApps: true)
    app.run()
}
