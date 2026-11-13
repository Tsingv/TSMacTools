import AppKit
import MacToolsCore
import MacToolsScripting

@MainActor
final class NativeWindowManager: NSObject, WindowManaging {
    static let translationLoadingBody = "__TSMacToolsTranslationLoading__"

    private var windows: [NativeWindowID: NSWindow] = [:]
    private var pinButtons: [NativeWindowID: PinButton] = [:]
    /// Pushed by AppDelegate on configuration load, reload, and Settings save so showing or
    /// resigning a window never re-reads the configuration file from disk.
    private var translationWindow: TranslationWindowSettings?

    func updateTranslationWindowSettings(_ settings: TranslationWindowSettings) {
        translationWindow = settings
    }

    func showWindow(id: NativeWindowID, content: NativeWindowContent) {
        let translationWindow = translationWindowSettings(for: id)
        let isTranslationWindow = translationWindow != nil
        let size = translationWindow.map { NSSize(width: $0.width, height: $0.height) } ?? NSSize(width: 640, height: 420)
        let pinned = pinButtons[id]?.isPinned ?? translationWindow?.pinByDefault ?? false

        let existingWindow = windows[id]
        let isNewWindow = existingWindow == nil
        // Updates keep the user's current size; only a new window starts at the configured size.
        let contentSize = existingWindow?.contentView?.bounds.size ?? size
        let contentView = isTranslationLoading(content.body) ? loadingView() : textContentView(for: content, size: contentSize)

        let window = existingWindow ?? NSWindow(
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
        }

        if isNewWindow {
            window.setContentSize(size)
            centerOnMouseScreen(window)
            // Activate only on first presentation; content updates must not pull focus again.
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else if !window.isVisible {
            window.makeKeyAndOrderFront(nil)
        }
        focusFirstTextView(in: window)
        windows[id] = window
    }

    private func centerOnMouseScreen(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            window.center()
            return
        }
        let frame = window.frame
        window.setFrameOrigin(NSPoint(
            x: visible.midX - frame.width / 2,
            y: visible.midY - frame.height / 2
        ))
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

        let scrollView = NSTextView.scrollableTextView()
        scrollView.frame = NSRect(origin: .zero, size: size)
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }
        textView.isEditable = false
        textView.isSelectable = true
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

        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        return scrollView
    }

    private func focusFirstTextView(in window: NSWindow) {
        guard let textView = window.contentView?.firstDescendant(ofType: NSTextView.self) else {
            return
        }
        window.makeFirstResponder(textView)
    }

    private func loadingView() -> NSView {
        let container = DynamicLayerBackgroundView(color: .textBackgroundColor)

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
        guard let translationWindow, translationWindow.id == id.rawValue else {
            return nil
        }
        return translationWindow
    }

    private func dynamicColors(for attributedString: NSAttributedString) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attributedString)
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)
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
            .foregroundColor: NSColor.labelColor
        ]
        return NSAttributedString(string: text, attributes: attributes)
    }

    private static func dynamicColorsForDisplay(_ attributedString: NSAttributedString) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attributedString)
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)
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

/// Layer-backed view whose background follows light/dark changes. A `cgColor` captured once
/// is a static snapshot, so it is resolved again in `updateLayer` for the current appearance.
private class DynamicLayerBackgroundView: NSView {
    var backgroundColor: NSColor {
        didSet { needsDisplay = true }
    }
    private let cornerRadius: CGFloat

    init(color: NSColor, cornerRadius: CGFloat = 0) {
        backgroundColor = color
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        var resolved = backgroundColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = backgroundColor.cgColor
        }
        layer?.backgroundColor = resolved
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = cornerRadius > 0
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
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
private final class CollapsibleThinkingContentView: DynamicLayerBackgroundView {
    private let body: NativeWindowContent.Body
    private let textView: NSTextView
    private let toggleButton: NSButton
    private var showsThinking = false

    init(content: NativeWindowContent, size: NSSize) {
        self.body = content.body
        self.textView = NSTextView(frame: NSRect(origin: .zero, size: size))
        self.toggleButton = NSButton(title: "", target: nil, action: nil)
        super.init(color: .textBackgroundColor)
        frame = NSRect(origin: .zero, size: size)
        buildView(size: size)
        updateContent()
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func buildView(size: NSSize) {
        toggleButton.target = self
        toggleButton.action = #selector(toggleThinking)
        toggleButton.bezelStyle = .rounded
        toggleButton.controlSize = .small
        toggleButton.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.textContainerInset = NSSize(width: 18, height: 18)
        // Standard scrollable text configuration: width tracks the clip view, height grows with
        // content so long results scroll instead of being clipped.
        textView.minSize = NSSize(width: 0, height: size.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: size.width, height: CGFloat.greatestFiniteMagnitude)
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
        // Non-activating HUD toast: never steals focus from the restored app after screenshot/copy.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 128),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let container = DynamicLayerBackgroundView(
            color: NSColor.windowBackgroundColor.withAlphaComponent(0.96),
            cornerRadius: 12
        )

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

@objc private protocol ResponderChainUndoRedoActions {
    func undo(_ sender: Any?)
    func redo(_ sender: Any?)
}

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let configurationStore = UserConfigurationStore()
    private var runtime: AutomationRuntime?
    private var configurationBootstrap: UserConfigurationBootstrapResult?
    private var hotkeyController: GlobalHotkeyController?
    private var settingsHotkeyCaptureToken: GlobalHotkeyController.CaptureToken?
    private var windowSwitcherController: WindowSwitcherController?
    private var smoothScrollController: SmoothScrollController?
    private let fanRuntime = FanRuntime()
    private let screenshotController = ScreenshotCaptureController()
    private let screenRecordingController = ScreenRecordingController()
    private var settingsWindowController: SettingsWindowController?
    private var statusItem: NSStatusItem?
    private var menuBarVisibilityMenuController: MenuBarVisibilityMenuController?
    private var recordingStatusTimer: Timer?
    private var defaultStatusImage: NSImage?
    private var smoothScrollSuspendedForCapture = false
    private let nativeWindowManager = NativeWindowManager()

    static func main() {
        #if DEBUG
        if let optionIndex = CommandLine.arguments.firstIndex(of: "--render-settings-previews") {
            guard CommandLine.arguments.indices.contains(optionIndex + 1) else {
                fputs("error=--render-settings-previews requires an output directory\n", stderr)
                return
            }
            _ = NSApplication.shared
            let outputDirectory = URL(
                fileURLWithPath: CommandLine.arguments[optionIndex + 1],
                isDirectory: true
            )
            let controller = SettingsWindowController(
                configuration: .migratedHammerspoonDefault(),
                configURL: outputDirectory.appendingPathComponent("preview-config.jsonc"),
                configurationStore: UserConfigurationStore(),
                didSave: { _ in },
                didFail: { _ in }
            )
            do {
                for url in try controller.renderPreviews(to: outputDirectory) {
                    print("preview=\(url.path)")
                }
                controller.close()
            } catch {
                fputs("error=\(error.localizedDescription)\n", stderr)
            }
            return
        }
        #endif

        if CommandLine.arguments.contains("--check-accessibility") {
            let status = AccessibilityPermissionClient().snapshot().accessibility
            print("accessibility=\(status == .granted ? "granted" : "missing")")
            return
        }

        if CommandLine.arguments.contains("--check-microphone") {
            let state = MicrophonePermission.authorizationState()
            print("microphone=\(state.displayName)")
            print("bundle=\(Bundle.main.bundleIdentifier ?? "unknown")")
            print("path=\(Bundle.main.bundlePath)")
            return
        }

        if CommandLine.arguments.contains("--list-menu-bar-applications") {
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            let controller = MenuBarVisibilityController()
            controller.applications { result in
                switch result {
                case let .success(applications):
                    for application in applications {
                        print("allowed=\(application.isAllowed ? "yes" : "no")\t\(application.localizedName)")
                    }
                case let .failure(error):
                    fputs("error=\(error.localizedDescription)\n", stderr)
                }
                app.terminate(nil)
            }
            app.run()
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
        configureCaptureControllers()
        // Script stdin writes must surface a closed pipe as an error instead of killing the app.
        signal(SIGPIPE, SIG_IGN)

        let permissionClient = AccessibilityPermissionClient()
        var bootstrapError: Error?
        do {
            configurationBootstrap = try configurationStore.bootstrap()
        } catch {
            bootstrapError = error
        }
        runtime = AutomationRuntime(
            windowManager: nativeWindowManager,
            permissionChecker: permissionClient
        )
        if let runtime, let configuration = configurationBootstrap?.configuration {
            startAutomation(runtime: runtime, configuration: configuration)
        }

        let permissions = runtime?.permissionSnapshot()
        if permissions?.accessibility != .granted {
            runtime?.requestAccessibilityPermissionPrompt()
        }
        if let bootstrapError {
            showStatusWindow(
                title: "Configuration Error",
                body: "\(bootstrapError.localizedDescription) Fix the configuration file and choose Reload Configuration."
            )
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        smoothScrollController?.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        var replied = false
        // Fan restoration and recording finalization share one 1.5-second cap.
        var pending = 2
        let finish: @MainActor @Sendable () -> Void = {
            guard !replied else { return }; replied = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        let completeOne: @MainActor @Sendable () -> Void = {
            pending -= 1
            if pending <= 0 { finish() }
        }
        fanRuntime.shutdown { DispatchQueue.main.async { completeOne() } }
        screenRecordingController.stop { completeOne() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { finish() }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        settingsHotkeyCaptureToken = nil
        hotkeyController?.shutdown()
        windowSwitcherController?.stop()
        smoothScrollController?.shutdown()
        if screenRecordingController.isRecording {
            screenRecordingController.stop()
        }
        screenshotController.cancel()
        recordingStatusTimer?.invalidate()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(named: "StatusBarIcon") ?? NSImage(systemSymbolName: "hammer", accessibilityDescription: "TSMacTools")
            image?.isTemplate = true
            defaultStatusImage = image
            button.image = image
            button.title = image == nil ? "TS" : ""
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "TSMacTools", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        let visibilityMenuController = MenuBarVisibilityMenuController { [weak self] error in
            self?.showStatusWindow(title: "Menu Bar Visibility", body: error.localizedDescription)
        }
        let visibilityItem = NSMenuItem(title: "Menu Bar Icons", action: nil, keyEquivalent: "")
        visibilityItem.submenu = visibilityMenuController.menu
        menu.addItem(visibilityItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Capture Screenshot", action: #selector(captureScreenshot), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Toggle Screen Recording", action: #selector(toggleScreenRecording), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Reload Configuration", action: #selector(reloadConfiguration), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Open Configuration Folder", action: #selector(openConfigurationFolder), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
        menuBarVisibilityMenuController = visibilityMenuController
    }

    private func configureCaptureControllers() {
        screenshotController.onStatus = { [weak self] title, body in
            self?.showStatusWindow(title: title, body: body)
        }
        screenshotController.onActiveChange = { [weak self] isActive in
            self?.setSmoothScrollSuspendedForCapture(isActive)
        }
        screenRecordingController.onStatus = { [weak self] title, body in
            self?.showStatusWindow(title: title, body: body)
        }
        screenRecordingController.onRecordingStateChange = { [weak self] isRecording, _ in
            self?.updateRecordingStatusItem(isRecording: isRecording)
        }
    }

    /// Pause mouse-wheel smoothing while the screenshot overlay is adjusting sizes. Suspension
    /// only disables the existing event tap; it does not tear down and rebuild it.
    private func setSmoothScrollSuspendedForCapture(_ suspended: Bool) {
        guard smoothScrollSuspendedForCapture != suspended else { return }
        smoothScrollSuspendedForCapture = suspended
        smoothScrollController?.setSuspended(suspended)
    }

    @objc private func captureScreenshot() {
        screenshotController.beginCapture()
    }

    @objc private func toggleScreenRecording() {
        screenRecordingController.toggle()
    }

    private func updateRecordingStatusItem(isRecording: Bool) {
        recordingStatusTimer?.invalidate()
        recordingStatusTimer = nil
        guard let button = statusItem?.button else { return }
        button.image = defaultStatusImage
        if isRecording {
            // Keep the normal status icon and only append elapsed time.
            refreshRecordingElapsedTitle()
            let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshRecordingElapsedTitle()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            recordingStatusTimer = timer
        } else {
            button.title = defaultStatusImage == nil ? "TS" : ""
        }
    }

    private func refreshRecordingElapsedTitle() {
        guard screenRecordingController.isRecording, let button = statusItem?.button else { return }
        let elapsed = Int(screenRecordingController.elapsed())
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        button.title = String(format: " %d:%02d", minutes, seconds)
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
        editMenu.addItem(NSMenuItem(title: "Undo", action: #selector(ResponderChainUndoRedoActions.undo(_:)), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: #selector(ResponderChainUndoRedoActions.redo(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = NSEvent.ModifierFlags([.command, .shift])
        editMenu.addItem(redo)
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        let pasteAndMatchStyle = NSMenuItem(title: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
        pasteAndMatchStyle.keyEquivalentModifierMask = NSEvent.ModifierFlags([.command, .option, .shift])
        editMenu.addItem(pasteAndMatchStyle)
        editMenu.addItem(NSMenuItem(title: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: ""))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    private func startAutomation(runtime: AutomationRuntime, configuration: UserConfiguration) {
        nativeWindowManager.updateTranslationWindowSettings(configuration.translation.nativeWindow)
        fanRuntime.apply(configuration.fans)
        fanRuntime.start()
        let windowSwitcherController: WindowSwitcherController
        if let existing = self.windowSwitcherController {
            existing.apply(configuration: configuration)
            windowSwitcherController = existing
        } else {
            let controller = WindowSwitcherController(runtime: runtime, configuration: configuration)
            controller.start()
            self.windowSwitcherController = controller
            windowSwitcherController = controller
        }

        if let hotkeyController {
            hotkeyController.apply(
                configuration: configuration,
                windowSwitcherController: windowSwitcherController
            )
        } else {
            let controller = GlobalHotkeyController(
                runtime: runtime,
                configuration: configuration,
                windowSwitcherController: windowSwitcherController,
                reloadConfigurationHandler: { [weak self] in
                    self?.reloadConfiguration()
                },
                captureScreenshotHandler: { [weak self] in
                    self?.captureScreenshot()
                },
                toggleScreenRecordingHandler: { [weak self] in
                    self?.toggleScreenRecording()
                }
            )
            controller.start()
            hotkeyController = controller
        }

        if let smoothScrollController {
            smoothScrollController.apply(configuration.scroll)
        } else {
            let controller = SmoothScrollController(settings: configuration.scroll)
            if smoothScrollSuspendedForCapture {
                controller.setSuspended(true)
            }
            controller.start()
            smoothScrollController = controller
        }

        screenshotController.apply(configuration.capture)
        screenRecordingController.apply(configuration.capture)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    @objc private func showSettings() {
        if let settingsWindowController, settingsWindowController.isPresented {
            settingsWindowController.bringToFront()
            return
        }
        do {
            let previousConfiguration = configurationBootstrap?.configuration
            let result = try configurationStore.bootstrap()
            configurationBootstrap = result

            if let previousConfiguration {
                applyAutomationChange(from: previousConfiguration, to: result.configuration)
            } else if let runtime {
                startAutomation(runtime: runtime, configuration: result.configuration)
            }

            if let settingsWindowController {
                settingsWindowController.present(
                    configuration: result.configuration,
                    configURL: result.configURL
                )
            } else {
                let controller = SettingsWindowController(
                    configuration: result.configuration,
                    configURL: result.configURL,
                    configurationStore: configurationStore,
                    hotkeyRecordingDidChange: { [weak self] isRecording in
                        self?.settingsHotkeyRecordingDidChange(isRecording)
                    },
                    didSave: { [weak self] configuration in
                        self?.settingsDidSave(configuration)
                    },
                    didFail: { [weak self] error in
                        self?.showStatusWindow(title: "Settings Error", body: error.localizedDescription)
                    }
                )
                controller.fanRuntime = fanRuntime
                settingsWindowController = controller
                controller.present(configuration: result.configuration, configURL: result.configURL)
            }
        } catch {
            showStatusWindow(title: "Settings Error", body: error.localizedDescription)
        }
    }

    @objc private func openConfigurationFolder() {
        guard let url = configurationBootstrap?.directoryURL else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func reloadConfiguration() {
        do {
            let previousConfiguration = configurationBootstrap?.configuration
            let result = try configurationStore.bootstrap()
            configurationBootstrap = result

            if let previousConfiguration {
                applyAutomationChange(from: previousConfiguration, to: result.configuration)
            } else if let runtime {
                startAutomation(runtime: runtime, configuration: result.configuration)
            }
            settingsWindowController?.refresh(
                configuration: result.configuration,
                configURL: result.configURL
            )
            showStatusWindow(title: "TSMacTools", body: "Configuration reloaded from \(result.configURL.path)")
        } catch {
            showStatusWindow(title: "Reload Error", body: error.localizedDescription)
        }
    }

    private func settingsDidSave(_ configuration: UserConfiguration) {
        guard var bootstrap = configurationBootstrap else {
            return
        }
        let previousConfiguration = bootstrap.configuration
        bootstrap.configuration = configuration
        configurationBootstrap = bootstrap
        applyAutomationChange(from: previousConfiguration, to: configuration)
    }

    private func settingsHotkeyRecordingDidChange(_ isRecording: Bool) {
        if isRecording {
            guard settingsHotkeyCaptureToken == nil else { return }
            settingsHotkeyCaptureToken = hotkeyController?.beginHotkeyCapture()
            return
        }

        guard let token = settingsHotkeyCaptureToken else { return }
        settingsHotkeyCaptureToken = nil
        _ = hotkeyController?.endHotkeyCapture(token)
    }

    private func applyAutomationChange(from previous: UserConfiguration, to configuration: UserConfiguration) {
        nativeWindowManager.updateTranslationWindowSettings(configuration.translation.nativeWindow)
        fanRuntime.apply(configuration.fans)

        guard previous != configuration, let runtime else {
            return
        }
        startAutomation(runtime: runtime, configuration: configuration)
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
