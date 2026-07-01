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
        focusFirstTextView(in: window)
        windows[id] = window
    }

    func closeWindow(id: NativeWindowID) {
        windows[id]?.close()
        windows[id] = nil
        pinButtons[id] = nil
    }

    private func textContentView(for content: NativeWindowContent, size: NSSize) -> NSView {
        if render(content.body).localizedStandardContains("<think>") {
            return CollapsibleThinkingContentView(content: content, size: size)
        }

        let textView = NSTextView(frame: NSRect(origin: .zero, size: size))
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.textContainerInset = NSSize(width: 18, height: 18)
        textView.autoresizingMask = [.width, .height]
        textView.textContainer?.widthTracksTextView = true
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

    private func focusFirstTextView(in window: NSWindow) {
        guard let textView = window.contentView?.firstDescendant(ofType: NSTextView.self) else {
            return
        }
        window.makeFirstResponder(textView)
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

    static func attributedText(for body: NativeWindowContent.Body) -> NSAttributedString {
        let text = switch body {
        case let .markdown(value), let .html(value), let .plainText(value):
            value
        }

        if case .markdown = body,
           let data = text.data(using: .utf8),
           let attributed = try? NSAttributedString(
            markdown: data,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
           ) {
            return dynamicColorsForDisplay(attributed)
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.labelColor,
            .backgroundColor: NSColor.textBackgroundColor
        ]
        return NSAttributedString(string: text, attributes: attributes)
    }

    private static func dynamicColorsForDisplay(_ attributedString: NSAttributedString) -> NSAttributedString {
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

private extension NSView {
    func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
        if let view = self as? T {
            return view
        }
        for subview in subviews {
            if let found = subview.firstDescendant(ofType: type) {
                return found
            }
        }
        return nil
    }
}

@MainActor
private final class CollapsibleThinkingContentView: NSView {
    private let body: NativeWindowContent.Body
    private let textView: NSTextView
    private let toggleButton: NSButton
    private var showsThinking = false

    init(content: NativeWindowContent, size: NSSize) {
        self.body = content.body
        self.textView = NSTextView(frame: NSRect(origin: .zero, size: size))
        self.toggleButton = NSButton(title: "", target: nil, action: nil)
        super.init(frame: NSRect(origin: .zero, size: size))
        buildView(size: size)
        updateContent()
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func buildView(size: NSSize) {
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        toggleButton.target = self
        toggleButton.action = #selector(toggleThinking)
        toggleButton.bezelStyle = .rounded
        toggleButton.controlSize = .small
        toggleButton.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.textContainerInset = NSSize(width: 18, height: 18)
        textView.autoresizingMask = [.width, .height]
        textView.textContainer?.widthTracksTextView = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor

        let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.documentView = textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(toggleButton)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            toggleButton.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            toggleButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            scrollView.topAnchor.constraint(equalTo: toggleButton.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @objc private func toggleThinking() {
        showsThinking.toggle()
        updateContent()
    }

    private func updateContent() {
        let raw = render(body)
        let rendered = showsThinking ? expandThinking(in: raw) : collapseThinking(in: raw)
        let renderedBody = body.replacingText(with: rendered)
        textView.textStorage?.setAttributedString(NativeWindowManager.attributedText(for: renderedBody))
        window?.makeFirstResponder(textView)
        toggleButton.title = showsThinking ? "Hide Thinking" : "Show Thinking"
    }

    private func render(_ body: NativeWindowContent.Body) -> String {
        switch body {
        case let .markdown(value), let .html(value), let .plainText(value):
            return value
        }
    }

    private func collapseThinking(in text: String) -> String {
        text.replacingOccurrences(
            of: #"(?is)<think>.*?</think>"#,
            with: "\n\n[Thinking hidden]\n\n",
            options: .regularExpression
        )
    }

    private func expandThinking(in text: String) -> String {
        text.replacingOccurrences(
            of: #"(?is)<think>\s*(.*?)\s*</think>"#,
            with: "\n\n## Thinking\n\n$1\n\n",
            options: .regularExpression
        )
    }
}

private extension NativeWindowContent.Body {
    func replacingText(with text: String) -> NativeWindowContent.Body {
        switch self {
        case .markdown:
            return .markdown(text)
        case .html:
            return .html(text)
        case .plainText:
            return .plainText(text)
        }
    }
}

@MainActor
final class TransientAlertPresenter: NSObject, NSWindowDelegate {
    static let shared = TransientAlertPresenter()
    private var panels: [NSPanel] = []

    func show(title: String, body: String) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 128),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 14, weight: .semibold)
        titleField.textColor = .labelColor

        let bodyField = NSTextField(wrappingLabelWithString: body)
        bodyField.font = .systemFont(ofSize: 13)
        bodyField.textColor = .secondaryLabelColor
        bodyField.maximumNumberOfLines = 3

        stack.addArrangedSubview(titleField)
        stack.addArrangedSubview(bodyField)
        container.addSubview(stack)
        panel.contentView = container

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -16)
        ])

        position(panel)
        panels.append(panel)
        panel.orderFrontRegardless()

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self, weak panel] in
            guard let panel else {
                return
            }
            panel.close()
            self?.panels.removeAll { $0 === panel }
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel else {
            return
        }
        panels.removeAll { $0 === panel }
    }

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = panel.frame
        panel.setFrameOrigin(NSPoint(
            x: screen.maxX - frame.width - 24,
            y: screen.maxY - frame.height - 24 - CGFloat(panels.count * 14)
        ))
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
    private let configurationStore = UserConfigurationStore()
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
        installMainMenu()

        let manager = NativeWindowManager()
        let permissionClient = AccessibilityPermissionClient()
        configurationBootstrap = try? configurationStore.bootstrap()
        runtime = AutomationRuntime(
            windowManager: manager,
            permissionChecker: permissionClient
        )
        if let runtime, let configuration = configurationBootstrap?.configuration {
            startAutomation(runtime: runtime, configuration: configuration)
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
        menu.addItem(NSMenuItem(title: "Reload Configuration", action: #selector(reloadConfiguration), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Open Configuration Folder", action: #selector(openConfigurationFolder), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit TSMacTools", action: #selector(quit), keyEquivalent: "q"))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    private func startAutomation(runtime: AutomationRuntime, configuration: UserConfiguration) {
        windowSwitcherController?.stop()
        hotkeyController?.stop()

        let windowSwitcherController = WindowSwitcherController(runtime: runtime, configuration: configuration)
        windowSwitcherController.start()
        self.windowSwitcherController = windowSwitcherController

        hotkeyController = GlobalHotkeyController(
            runtime: runtime,
            configuration: configuration,
            windowSwitcherController: windowSwitcherController,
            reloadConfigurationHandler: { [weak self] in
                self?.reloadConfiguration()
            }
        )
        hotkeyController?.start()
    }

    @objc private func openConfigurationFolder() {
        guard let url = configurationBootstrap?.directoryURL else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func reloadConfiguration() {
        do {
            let result = try configurationStore.bootstrap()
            configurationBootstrap = result
            if let runtime {
                startAutomation(runtime: runtime, configuration: result.configuration)
            }
            showStatusWindow(title: "TSMacTools", body: "Configuration reloaded from \(result.configURL.path)")
        } catch {
            showStatusWindow(title: "Reload Error", body: error.localizedDescription)
        }
    }

    private func showStatusWindow(title: String, body: String) {
        TransientAlertPresenter.shared.show(title: title, body: body)
    }

    @objc private func copy(_ sender: Any?) {
        guard let textView = NSApp.keyWindow?.firstResponderTextView() else {
            return
        }

        let selected = textView.selectedRange()
        guard selected.location != NSNotFound, selected.length > 0 else {
            return
        }

        let text = (textView.string as NSString).substring(with: selected)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func selectAll(_ sender: Any?) {
        NSApp.keyWindow?.firstResponderTextView()?.selectAll(sender)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

private extension NSWindow {
    func firstResponderTextView() -> NSTextView? {
        if let textView = firstResponder as? NSTextView {
            return textView
        }
        return contentView?.firstDescendant(ofType: NSTextView.self)
    }
}
