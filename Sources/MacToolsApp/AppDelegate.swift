import AppKit
import MacToolsCore
import MacToolsScripting

@MainActor
final class NativeWindowManager: NSObject, WindowManaging {
    static let translationLoadingBody = "__TSMacToolsTranslationLoading__"

    private var windows: [NativeWindowID: NSWindow] = [:]
    private var pinButtons: [NativeWindowID: PinButton] = [:]
    private let configurationStore = UserConfigurationStore()

    func showWindow(id: NativeWindowID, content: NativeWindowContent) {
        let translationWindow = translationWindowSettings(for: id)
        let isTranslationWindow = translationWindow != nil
        let size = translationWindow.map { NSSize(width: $0.width, height: $0.height) } ?? NSSize(width: 640, height: 420)
        let pinned = pinButtons[id]?.isPinned ?? translationWindow?.pinByDefault ?? false

        let contentView = isTranslationLoading(content.body) ? loadingView() : textContentView(for: content, size: size)

        let window = windows[id] ?? NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: size.width, height: size.height),
            styleMask: isTranslationWindow ? [.titled, .closable, .resizable, .utilityWindow] : [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = content.title
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.level = isTranslationWindow ? .floating : .normal
        window.collectionBehavior = isTranslationWindow ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
        window.contentView = contentView

        if isTranslationWindow {
            installPinButton(for: id, in: window, pinned: pinned)
            window.setContentSize(size)
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        windows[id] = window
    }

    func closeWindow(id: NativeWindowID) {
        windows[id]?.close()
        windows[id] = nil
        pinButtons[id] = nil
    }

    private func textContentView(for content: NativeWindowContent, size: NSSize) -> NSView {
        let textView = NSTextView(frame: NSRect(origin: .zero, size: size))
        textView.isEditable = false
        textView.isRichText = true
        textView.textContainerInset = NSSize(width: 18, height: 18)
        textView.font = .systemFont(ofSize: 14)
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.string = render(content.body)
        if case let .markdown(markdown) = content.body,
           let data = markdown.data(using: .utf8),
           let attributed = try? NSAttributedString(
            markdown: data,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
           ) {
            textView.textStorage?.setAttributedString(dynamicColors(for: attributed))
        }

        let scrollView = NSScrollView(frame: textView.frame)
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.documentView = textView
        return scrollView
    }

    private func loadingView() -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .regular
        indicator.isIndeterminate = true
        indicator.startAnimation(nil)

        let label = NSTextField(labelWithString: "Translating...")
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .labelColor

        stack.addArrangedSubview(indicator)
        stack.addArrangedSubview(label)
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        return container
    }

    private func isTranslationLoading(_ body: NativeWindowContent.Body) -> Bool {
        guard case let .plainText(value) = body else {
            return false
        }
        return value == Self.translationLoadingBody
    }

    private func render(_ body: NativeWindowContent.Body) -> String {
        switch body {
        case let .markdown(value), let .html(value), let .plainText(value):
            return value
        }
    }

    private func translationWindowSettings(for id: NativeWindowID) -> TranslationWindowSettings? {
        guard let configuration = try? configurationStore.bootstrap().configuration,
              configuration.translation.nativeWindow.id == id.rawValue else {
            return nil
        }
        return configuration.translation.nativeWindow
    }

    private func dynamicColors(for attributedString: NSAttributedString) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attributedString)
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)
        mutable.addAttribute(.backgroundColor, value: NSColor.textBackgroundColor, range: fullRange)
        mutable.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            if value == nil {
                mutable.addAttribute(.font, value: NSFont.systemFont(ofSize: 14), range: range)
            }
        }
        return mutable
    }

    private func installPinButton(for id: NativeWindowID, in window: NSWindow, pinned: Bool) {
        if pinButtons[id] != nil {
            updatePinButton(for: id, pinned: pinned)
            return
        }

        let button = PinButton(nativeWindowID: id)
        button.target = self
        button.action = #selector(togglePin(_:))
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.setButtonType(.toggle)
        button.toolTip = "Pin translation window"
        button.isPinned = pinned

        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .right
        accessory.view = button
        window.addTitlebarAccessoryViewController(accessory)
        pinButtons[id] = button
        updatePinButton(for: id, pinned: pinned)
    }

    private func updatePinButton(for id: NativeWindowID, pinned: Bool) {
        guard let button = pinButtons[id] else {
            return
        }
        let label = pinned ? "Unpin translation window" : "Pin translation window"
        button.isPinned = pinned
        button.state = pinned ? .on : .off
        button.setAccessibilityLabel(label)
        if let image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin", accessibilityDescription: label) {
            button.image = image
            button.title = ""
        } else {
            button.title = pinned ? "Pinned" : "Pin"
        }
    }

    @objc private func togglePin(_ sender: PinButton) {
        updatePinButton(for: sender.nativeWindowID, pinned: !sender.isPinned)
    }
}

@MainActor
extension NativeWindowManager: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let (id, _) = windows.first(where: { $0.value === window }),
              translationWindowSettings(for: id) != nil,
              pinButtons[id]?.isPinned != true else {
            return
        }

        closeWindow(id: id)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = windows.first(where: { $0.value === window })?.key else {
            return
        }

        windows[id] = nil
        pinButtons[id] = nil
    }
}

private final class PinButton: NSButton {
    let nativeWindowID: NativeWindowID
    var isPinned = false

    init(nativeWindowID: NativeWindowID) {
        self.nativeWindowID = nativeWindowID
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 24))
    }

    required init?(coder: NSCoder) {
        nil
    }
}

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var runtime: AutomationRuntime?
    private var configurationBootstrap: UserConfigurationBootstrapResult?
    private var hotkeyController: GlobalHotkeyController?
    private var windowSwitcherController: WindowSwitcherController?
    private var statusItem: NSStatusItem?

    static func main() {
        if CommandLine.arguments.contains("--check-accessibility") {
            let status = AccessibilityPermissionClient().snapshot().accessibility
            print("accessibility=\(status == .granted ? "granted" : "missing")")
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()

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

        let permissions = runtime?.permissionSnapshot()
        if permissions?.accessibility != .granted {
            runtime?.requestAccessibilityPermissionPrompt()
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(named: "StatusBarIcon") ?? NSImage(systemSymbolName: "hammer", accessibilityDescription: "TSMacTools")
            button.image?.isTemplate = true
            button.title = button.image == nil ? "TS" : ""
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "TSMacTools", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Request Accessibility Permission", action: #selector(requestAccessibilityPermission), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Configuration Folder", action: #selector(openConfigurationFolder), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc private func requestAccessibilityPermission() {
        runtime?.requestAccessibilityPermissionPrompt()
    }

    @objc private func openConfigurationFolder() {
        guard let url = configurationBootstrap?.directoryURL else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
