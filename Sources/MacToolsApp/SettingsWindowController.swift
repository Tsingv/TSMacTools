import AppKit
import Security
import IOKit
import Carbon.HIToolbox
import MacToolsCore
import QuartzCore
import UniformTypeIdentifiers

private func hotkeyRecorderEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<HotkeyRecorderEventTap>.fromOpaque(userInfo).takeUnretainedValue()
    return tap.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}

private final class HotkeyRecorderEventTap {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    var onKeyDown: ((UInt16, CGEventFlags) -> Void)?

    func install() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        let createdTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyRecorderEventTapCallback,
            userInfo: userInfo
        ) ?? CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyRecorderEventTapCallback,
            userInfo: userInfo
        )
        guard let createdTap,
              let createdSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, createdTap, 0) else {
            return false
        }
        tap = createdTap
        source = createdSource
        CFRunLoopAddSource(CFRunLoopGetMain(), createdSource, .commonModes)
        CGEvent.tapEnable(tap: createdTap, enable: true)
        return CGEvent.tapIsEnabled(tap: createdTap)
    }

    func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard type == .keyDown else { return false }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        onKeyDown?(keyCode, event.flags)
        return true
    }

    func invalidate() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        tap = nil
        onKeyDown = nil
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate, NSWindowDelegate {
    private enum MutationError: LocalizedError {
        case hotkeyChangedExternally
        case hotkeyConflict(String)
        case invalidValue(String)
        case ambiguousLayout(String)

        var errorDescription: String? {
            switch self {
            case .hotkeyChangedExternally:
                "The hotkey list changed outside Settings. The latest file was reloaded; record the shortcut again."
            case let .hotkeyConflict(action):
                "This shortcut is already assigned to \(action). Press another combination or Escape to cancel."
            case let .invalidValue(message):
                message
            case let .ambiguousLayout(viewName):
                "Settings preview has ambiguous Auto Layout in \(viewName)."
            }
        }
    }

    private enum ConfigurationField: Int {
        case switcherWidth = 100
        case switcherHeight
        case switcherMaxRows
        case switcherDisplayDelay
        case pythonPath
        case finderBundleIdentifier
        case terminalBundleIdentifier
        case ignoredApplicationNames
        case googleSourceLanguage
        case googleTargetLanguage
        case googleTargetLanguageForChinese
        case copyKeystrokeDelay
        case endpoint
        case model
        case contextWindowTokens
        case outputTokenLimit
        case requestTokenLimit
        case apiKey
        case thinkingLevel
        case googleAPIKey
        case screenshotSaveDirectory
        case recordingSaveDirectory
        case recordingFrameRate
        case recordingBitrateKbps
    }

    private enum Page: Int, CaseIterable {
        case general
        case hotkeys
        case scrolling
        case capture
        case fans

        var title: String {
            switch self {
            case .general: "General"
            case .hotkeys: "Hotkeys"
            case .scrolling: "Scrolling"
            case .capture: "Capture"
            case .fans: "Fans"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .hotkeys: "keyboard"
            case .scrolling: "scroll"
            case .capture: "camera.viewfinder"
            case .fans: "fan"
            }
        }
    }

    private let configurationStore: UserConfigurationStore
    private let didSave: (UserConfiguration) -> Void
    private let didFail: (Error) -> Void
    private let hotkeyRecordingDidChange: (Bool) -> Void
    private var configuration: UserConfiguration
    private var lastKnownGoodConfiguration: UserConfiguration
    private var configURL: URL
    private var selectedPage: Page = .general
    private let contentContainer = NSView()
    private var pageButtons: [Page: NSButton] = [:]
    private var cachedPageViews: [Page: NSView] = [:]

    private let savingQueue = DispatchQueue(label: "TSMacTools.settings-save", qos: .utility)
    private var saveGeneration = 0
    private var applicationIcons: [String: NSImage] = [:]
    private var providerPopup: NSPopUpButton?
    private var modelPopup: NSPopUpButton?
    private var thinkingLevelPopup: NSPopUpButton?
    private var modelsStatusLabel: NSTextField?
    private var modelLimitsLabel: NSTextField?
    private var llmModels: [LLMModelDescriptor] = []
    private var modelsFetchGeneration = 0

    private var presetPopup: NSPopUpButton?
    private var presetSummary: NSTextField?
    private var stepSlider: NSSlider?
    private var speedSlider: NSSlider?
    private var durationSlider: NSSlider?
    private var accelerationSlider: NSSlider?
    private var deadZoneSlider: NSSlider?
    private var stepValue: NSTextField?
    private var speedValue: NSTextField?
    private var durationValue: NSTextField?
    private var accelerationValue: NSTextField?
    private var deadZoneValue: NSTextField?
    private var pendingTuningChanges: [Int: Double] = [:]
    private struct RowSpec {
        let title: String
        let hint: String?
        let control: NSView?
        let hintLabel: ((NSTextField) -> Void)?
    }

    private struct ConditionalRow {
        let condition: (UserConfiguration) -> Bool
        let setHidden: (Bool) -> Void
    }

    private var conditionalRows: [Page: [ConditionalRow]] = [:]
    private var reconciliationScheduled = false
    private weak var activeHotkeyRecorder: HotkeyRecorderButton?
    private weak var hotkeyTableView: NSTableView?
    private weak var hotkeyCountLabel: NSTextField?
    private var hotkeyTableHeightConstraint: NSLayoutConstraint?
    private var isHotkeyRecordingActive = false
    private var pendingHotkeyFocusID: String?
    private static let tuningSaveDelay: TimeInterval = 0.12
    private static let reconciliationDelay: TimeInterval = 0.05

    init(
        configuration: UserConfiguration,
        configURL: URL,
        configurationStore: UserConfigurationStore,
        hotkeyRecordingDidChange: @escaping (Bool) -> Void = { _ in },
        didSave: @escaping (UserConfiguration) -> Void,
        didFail: @escaping (Error) -> Void
    ) {
        self.configuration = configuration
        self.lastKnownGoodConfiguration = configuration
        self.configURL = configURL
        self.configurationStore = configurationStore
        self.hotkeyRecordingDidChange = hotkeyRecordingDidChange
        self.didSave = didSave
        self.didFail = didFail

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "TSMacTools Settings"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 760, height: 540)
        window.setContentSize(NSSize(width: 760, height: 650))
        window.center()
        super.init(window: window)
        window.delegate = self
        buildWindow()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func present(configuration: UserConfiguration, configURL: URL) {
        refresh(configuration: configuration, configURL: configURL)
        NSApp.setActivationPolicy(.regular)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        updateFanVisibility()
    }

    func refresh(configuration: UserConfiguration, configURL: URL) {
        endActiveHotkeyRecording()
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(persistPendingTuning),
            object: nil
        )
        pendingTuningChanges.removeAll(keepingCapacity: true)
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(reconcileVisiblePageWhenIdle),
            object: nil
        )
        reconciliationScheduled = false
        self.configuration = configuration
        lastKnownGoodConfiguration = configuration
        self.configURL = configURL
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        cachedPageViews.removeAll()
        conditionalRows.removeAll()
        showPage(selectedPage, animated: false)
    }

    private func buildWindow() {
        guard let root = window?.contentView else { return }

        let pageBar = NSStackView()
        pageBar.orientation = .horizontal
        pageBar.alignment = .centerY
        pageBar.distribution = .fillEqually
        pageBar.spacing = 8
        pageBar.edgeInsets = NSEdgeInsets(top: 8, left: 96, bottom: 6, right: 96)
        pageBar.translatesAutoresizingMaskIntoConstraints = false

        for page in Page.allCases {
            let button = SettingsPageButton(
                title: page.title,
                symbol: page.symbol,
                target: self,
                action: #selector(selectPage(_:))
            )
            button.tag = page.rawValue
            button.toolTip = page.title
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(equalToConstant: 54).isActive = true
            pageBar.addArrangedSubview(button)
            pageButtons[page] = button
        }

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(pageBar)
        root.addSubview(separator)
        root.addSubview(contentContainer)

        NSLayoutConstraint.activate([
            pageBar.topAnchor.constraint(equalTo: root.topAnchor),
            pageBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pageBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pageBar.heightAnchor.constraint(equalToConstant: 68),
            separator.topAnchor.constraint(equalTo: pageBar.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            contentContainer.topAnchor.constraint(equalTo: separator.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        showPage(.general)
    }

    @objc private func selectPage(_ sender: NSButton) {
        guard let page = Page(rawValue: sender.tag) else { return }
        showPage(page)
    }

    private func showPage(_ page: Page, rebuild: Bool = false, animated: Bool = true) {
        endActiveHotkeyRecording()
        let previousPage = selectedPage
        selectedPage = page
        defer { updateFanVisibility() }
        for (candidate, button) in pageButtons {
            let isSelected = candidate == page
            button.state = .off
            (button as? SettingsPageButton)?.isPageSelected = isSelected
        }
        if rebuild {
            cachedPageViews[page]?.removeFromSuperview()
            cachedPageViews[page] = nil
        }
        let pageView = cachedPageViews[page] ?? makePage(page)
        cachedPageViews[page] = pageView
        applyConditionalVisibility(for: page)
        if contentContainer.subviews.first === pageView { return }

        let previousView = contentContainer.subviews.first
        previousView?.removeFromSuperview()
        pageView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(pageView)
        NSLayoutConstraint.activate([
            pageView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            pageView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            pageView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            pageView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
        ])
        guard animated, previousPage != page, window?.isVisible == true else {
            pageView.alphaValue = 1
            return
        }
        pageView.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pageView.animator().alphaValue = 1
        }
    }

    private func applyConditionalVisibility(for page: Page) {
        guard let entries = conditionalRows[page] else { return }
        for entry in entries {
            entry.setHidden(!entry.condition(configuration))
        }
    }

    private func languagePicker(_ value: String, field: ConfigurationField) -> NSPopUpButton {
        let popup = NSPopUpButton()
        let values = ["auto", "en", "zh-CN", "zh-TW", "ja", "ko", "fr", "de", "es", "it", "pt", "ru", "ar", "hi"]
        popup.addItems(withTitles: values.contains(value) ? values : values + [value])
        popup.selectItem(withTitle: value)
        popup.tag = field.rawValue
        popup.target = self; popup.action = #selector(languageChanged(_:))
        return popup
    }
    @objc private func languageChanged(_ sender: NSPopUpButton) {
        let value = sender.titleOfSelectedItem ?? "auto"
        persist { latest in
            switch ConfigurationField(rawValue: sender.tag) {
            case .googleSourceLanguage: latest.translation.googleSourceLanguage = value
            case .googleTargetLanguage: latest.translation.googleTargetLanguage = value
            case .googleTargetLanguageForChinese: latest.translation.googleTargetLanguageForChinese = value
            default: break
            }
        }
    }
    private func filePicker(_ value: String, field: ConfigurationField) -> NSButton {
        let button = NSButton(title: value, target: self, action: #selector(chooseConfigurationFile(_:)))
        button.tag = field.rawValue; button.toolTip = value
        button.widthAnchor.constraint(equalToConstant: 320).isActive = true
        return button
    }
    @objc private func chooseConfigurationFile(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        let field = ConfigurationField(rawValue: sender.tag)
        if field != .pythonPath { panel.allowedContentTypes = [.applicationBundle] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let value = field == .pythonPath ? url.path : Bundle(url: url)?.bundleIdentifier
        guard let value else { return }
        persist { latest in
            switch field {
            case .pythonPath: latest.scripting.pythonPath = value
            case .finderBundleIdentifier: latest.application.finderBundleIdentifier = value
            case .terminalBundleIdentifier: latest.application.terminalBundleIdentifier = value
            default: break
            }
        }
        sender.title = value; sender.toolTip = value
    }

    private var fanEditorCount = 0
    var fanRuntime: FanRuntime?
    private var fanLivePanel: FanRuntime?
    private func makeFansPage() -> NSView {
        fanEditorCount = configuration.fans.rules.count
        let stack = pageStack()
        let live = fanRuntime ?? fanLivePanel ?? FanRuntime()
        live.onEnabledChange = { [weak self] value in self?.persist { $0.fans.enabled = value } }
        fanLivePanel = live
        stack.addArrangedSubview(live.monitoringView)
        var editors: [FanCurveEditor] = []
        for rule in configuration.fans.rules {
            let editor = FanCurveEditor(rule: rule)
            editors.append(editor)
            var expected = rule
            editor.onDelete = { [weak self] in
                self?.persist { latest in
                    guard let index = latest.fans.rules.firstIndex(where: { $0.id == expected.id && $0 == expected }) else { throw MutationError.invalidValue("Rule changed externally; reopen Fans.") }
                    latest.fans.rules.remove(at: index)
                }
            }
            editor.onChange = { [weak self] changed in
                self?.persist { latest in
                    guard let index = latest.fans.rules.firstIndex(where: { $0.id == expected.id && $0 == expected }), changed.fan == expected.fan else { throw MutationError.invalidValue("Rule changed externally; reopen Fans.") }
                    latest.fans.rules[index] = changed
                }
                expected = changed
            }
            stack.addArrangedSubview(editor)
        }
        let chooser = NSPopUpButton()
        chooser.setAccessibilityLabel("Fan for new rule")
        let add = NSButton(title: "Add rule", target: nil, action: nil)
        let creation = FanRuleCreationAction { [weak self, weak chooser] in
            guard let self, let id = chooser?.selectedItem?.representedObject as? Int else { return }
            let detected = Set(live.detectedFanIDs)
            self.persist { latest in
                guard detected.contains(id), !latest.fans.rules.contains(where: { $0.fan == id }) else { throw MutationError.invalidValue("Fan unavailable or already assigned. Choose an unassigned detected fan.") }
                latest.fans.rules.append(FanRule(fan: id))
            }
        }
        add.target = creation; add.action = #selector(FanRuleCreationAction.invoke)
        // Retain the action for exactly as long as its button.
        objc_setAssociatedObject(add, &fanCreationActionKey, creation, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        let refresh: (FanSnapshot?) -> Void = { [weak self] snapshot in
            editors.forEach { $0.update(snapshot: snapshot) }
            let selection = chooser.selectedItem?.representedObject as? Int
            chooser.removeAllItems()
            let assigned = Set(self?.configuration.fans.rules.map(\.fan) ?? [])
            for fan in snapshot?.fans ?? [] where !assigned.contains(fan.id) {
                chooser.addItem(withTitle: fan.name.map { "\($0) (\(fan.id))" } ?? "Fan \(fan.id)")
                chooser.lastItem?.representedObject = fan.id
            }
            if let selection, let item = chooser.itemArray.first(where: { ($0.representedObject as? Int) == selection }) { chooser.select(item) }
            add.isEnabled = chooser.numberOfItems > 0
            chooser.isEnabled = add.isEnabled
            if !add.isEnabled { chooser.addItem(withTitle: "No unassigned detected fans") }
        }
        live.onSnapshot = refresh
        live.apply(configuration.fans)
        live.refreshEditors()
        stack.addArrangedSubview(NSStackView(views: [chooser, add]))
        if !configuration.fans.duplicateFanIDs.isEmpty {
            stack.addArrangedSubview(note("Duplicate fan assignments: \(configuration.fans.duplicateFanIDs). Control is suspended. Delete duplicate rules so each fan has one rule, including disabled rules."))
        }
        stack.addArrangedSubview(note("Choose an unassigned detected fan before creating a rule. Its fan is fixed; its sensor and curve remain editable. Delete a rule to release its assignment."))
        return scrollable(stack)
    }

    private func makePage(_ page: Page) -> NSView {
        switch page {
        case .general: makeGeneralPage()
        case .hotkeys: makeHotkeysPage()
        case .scrolling: makeScrollingPage()
        case .capture: makeCapturePage()
        case .fans: makeFansPage()
        }
    }

    private func updateFanVisibility() {
        (fanRuntime ?? fanLivePanel)?.setMonitoringVisible(selectedPage == .fans && window?.isVisible == true && window?.isMiniaturized != true && window?.occlusionState.contains(.visible) == true)
    }
    func windowDidChangeOcclusionState(_ notification: Notification) { updateFanVisibility() }
    func windowDidMiniaturize(_ notification: Notification) { updateFanVisibility() }
    func windowDidDeminiaturize(_ notification: Notification) { updateFanVisibility() }

    func windowWillClose(_ notification: Notification) {
        (fanRuntime ?? fanLivePanel)?.setMonitoringVisible(false)
        NSApp.setActivationPolicy(.accessory)
        endActiveHotkeyRecording()
    }

    func windowDidResignKey(_ notification: Notification) {
        endActiveHotkeyRecording()
    }

    private func beginHotkeyRecording(_ recorder: HotkeyRecorderButton) {
        if let previous = activeHotkeyRecorder, previous !== recorder {
            activeHotkeyRecorder = nil
            previous.cancelRecording()
        }
        activeHotkeyRecorder = recorder
        setHotkeyRecordingActive(true)
    }

    private func endHotkeyRecording(_ recorder: HotkeyRecorderButton) {
        guard activeHotkeyRecorder === recorder else { return }
        activeHotkeyRecorder = nil
        setHotkeyRecordingActive(false)
    }

    private func endActiveHotkeyRecording() {
        let recorder = activeHotkeyRecorder
        activeHotkeyRecorder = nil
        recorder?.cancelRecording()
        setHotkeyRecordingActive(false)
    }

    private func setHotkeyRecordingActive(_ active: Bool) {
        guard isHotkeyRecordingActive != active else { return }
        isHotkeyRecordingActive = active
        hotkeyRecordingDidChange(active)
    }

    private func makeGeneralPage() -> NSView {
        let stack = pageStack()
        var deps: [ConditionalRow] = []

        let switcherOn: (UserConfiguration) -> Bool = { $0.windowSwitcher.enabled }
        let translationOn: (UserConfiguration) -> Bool = { $0.translation.enabled }
        func translationProviders(_ names: [String]) -> (UserConfiguration) -> Bool {
            { $0.translation.enabled && names.contains($0.translation.provider) }
        }

        let provider = NSPopUpButton()
        provider.addItems(withTitles: ["Google Web", "Google Cloud", "LLM"])
        provider.selectItem(at: ["google_web", "google", "llm"].firstIndex(of: configuration.translation.provider) ?? 0)
        provider.target = self
        provider.action = #selector(providerChanged(_:))
        provider.controlSize = .small
        provider.widthAnchor.constraint(equalToConstant: 170).isActive = true
        providerPopup = provider

        let openConfig = NSButton(title: "Open…", target: self, action: #selector(openConfigFile))
        openConfig.bezelStyle = .rounded
        openConfig.controlSize = .small

        stack.addArrangedSubview(section(header: "Window switching", rows: [
            (formRow(title: "Enable Command-Tab window switcher",
                     control: boolSwitch(tag: 1, on: configuration.windowSwitcher.enabled)), nil),
            (formRow(title: "Follow the focused screen",
                     hint: "Centers the overlay on the display of the focused window.",
                     control: boolSwitch(tag: 4, on: configuration.windowSwitcher.followFocusedScreen)), switcherOn),
            (formRow(title: "Restore previous app when empty",
                     hint: "Returns to the last application once the frontmost one has no usable windows.",
                     control: boolSwitch(tag: 6, on: configuration.windowSwitcher.restorePreviousApplicationWhenNoWindows)), switcherOn),
            (formRow(title: "Overlay delay",
                     hint: "Seconds before the overlay appears (0…2).",
                     control: editableField(String(format: "%.2f", configuration.windowSwitcher.displayDelay), field: .switcherDisplayDelay, width: 90)), switcherOn),
            (formRow(title: "Overlay width",
                     hint: "Points (320–1600).",
                     control: editableField(String(configuration.windowSwitcher.width), field: .switcherWidth, width: 90)), switcherOn),
            (formRow(title: "Overlay height",
                     hint: "Points (120–1200).",
                     control: editableField(String(configuration.windowSwitcher.height), field: .switcherHeight, width: 90)), switcherOn),
            (formRow(title: "Maximum visible rows",
                     hint: "Rows before the list scrolls (1–50).",
                     control: editableField(String(configuration.windowSwitcher.maxVisibleRows), field: .switcherMaxRows, width: 90)), switcherOn),
            (formRow(title: "Ignored applications",
                     hint: "Comma-separated names omitted from the candidate list.",
                     control: editableField(configuration.application.ignoredWindowApplicationNames.joined(separator: ", "), field: .ignoredApplicationNames, width: 320)), switcherOn)
        ], into: &deps))

        stack.addArrangedSubview(section(header: "Translation", rows: [
            (formRow(title: "Enable selected-text translation",
                     control: boolSwitch(tag: 2, on: configuration.translation.enabled)), nil),
            (formRow(title: "Provider",
                     hint: "Selects the translation backend.",
                     control: provider), translationOn),
            (formRow(title: "Base URL",
                     hint: "Root adds /v1/chat/completions; a path adds /chat/completions. Complete chat/completions URLs and queries are preserved.",
                     control: editableField(TranslationEndpoint.baseURL(configuration.translation.endpoint), field: .endpoint, width: 320)), translationProviders(["llm"])),
            (formRow(title: "LLM model",
                     hint: "Discovered from /v1/models when Base URL and API key are reachable.",
                     control: makeModelPicker()), translationProviders(["llm"])),
            (formRow(title: "Thinking level",
                     hint: "reasoning.effort values advertised by the selected model.",
                     control: makeThinkingLevelPicker()), translationProviders(["llm"])),
            (formRow(title: "Model catalog",
                     hint: "Refresh after changing Base URL or API key.",
                     control: makeModelsRefreshControl()), translationProviders(["llm"])),
            (formRow(title: "Model limits",
                     hint: "Filled from /v1/models for the selected model. Not edited manually.",
                     control: makeModelLimitsLabel()), translationProviders(["llm"])),
            (formRow(title: "LLM API key",
                     hint: "Stored in your local JSONC file and masked here.",
                     control: editableField(configuration.translation.apiKey, field: .apiKey, width: 320, secure: true)), translationProviders(["llm"])),
            (formRow(title: "Google API key",
                     hint: "Required only by the Google Cloud provider.",
                     control: editableField(configuration.translation.googleApiKey, field: .googleAPIKey, width: 320, secure: true)), translationProviders(["google"])),
            (formRow(title: "Source language",
                     hint: "Use auto for detection.",
                     control: languagePicker(configuration.translation.googleSourceLanguage, field: .googleSourceLanguage)), translationProviders(["google_web", "google"])),
            (formRow(title: "Target language",
                     hint: "Used when the selection is not Chinese.",
                     control: languagePicker(configuration.translation.googleTargetLanguage, field: .googleTargetLanguage)), translationProviders(["google_web", "google"])),
            (formRow(title: "Chinese target language",
                     hint: "Used when the selection is Chinese.",
                     control: languagePicker(configuration.translation.googleTargetLanguageForChinese, field: .googleTargetLanguageForChinese)), translationProviders(["google_web", "google"])),
            (formRow(title: "Join PDF hard-wrapped lines",
                     hint: "Keeps paragraphs and structural lines intact.",
                     control: boolSwitch(tag: 5, on: configuration.translation.normalizePDFLineBreaks)), translationOn),
            (formRow(title: "Copy delay",
                     hint: "Seconds to wait for the selected text.",
                     control: editableField(String(format: "%.2f", configuration.translation.copyKeystrokeDelay), field: .copyKeystrokeDelay, width: 90)), translationOn)
        ], into: &deps))

        stack.addArrangedSubview(section(header: "Scripting & applications", rows: [
            (formRow(title: "Python executable",
                     hint: "Runs script-backed hotkey actions.",
                     control: filePicker(configuration.scripting.pythonPath, field: .pythonPath)), nil),
            (formRow(title: "Finder bundle ID",
                     control: filePicker(configuration.application.finderBundleIdentifier, field: .finderBundleIdentifier)), nil),
            (formRow(title: "Terminal bundle ID",
                     control: filePicker(configuration.application.terminalBundleIdentifier, field: .terminalBundleIdentifier)), nil)
        ], into: &deps))

        stack.addArrangedSubview(section(header: "Diagnostics", rows: [
            (formRow(title: "Timing and event diagnostics",
                     hint: "Writes compact hotkey and window timing logs.",
                     control: boolSwitch(tag: 3, on: configuration.windowSwitcher.debug)), nil)
        ], into: &deps))

        stack.addArrangedSubview(section(header: "Advanced", rows: [
            (formRow(title: "Configuration file",
                     hint: "Endpoints, prompts, native windows, and switcher strategies stay JSONC-only.",
                     control: openConfig), nil)
        ], into: &deps))

        stack.addArrangedSubview(note("Accessibility permission is shared by window, hotkey, and mouse automation. TSMacTools never enables a disabled event tap after permission is revoked."))
        conditionalRows[.general] = deps
        return scrollable(stack)
    }

    private func makeHotkeysPage() -> NSView {
        let stack = pageStack()
        let focusID = pendingHotkeyFocusID
        pendingHotkeyFocusID = nil

        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 10
        toolbar.widthAnchor.constraint(equalToConstant: 680).isActive = true
        let countLabel = NSTextField(labelWithString: "\(configuration.hotkeys.count) bindings")
        countLabel.font = .systemFont(ofSize: 12, weight: .medium)
        countLabel.textColor = .secondaryLabelColor
        hotkeyCountLabel = countLabel
        let toolbarSpacer = NSView()
        toolbarSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let add = NSButton(title: "Add", target: self, action: #selector(addHotkey))
        add.bezelStyle = .rounded
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        add.imagePosition = .imageLeading
        toolbar.addArrangedSubview(countLabel)
        toolbar.addArrangedSubview(toolbarSpacer)
        toolbar.addArrangedSubview(add)
        stack.addArrangedSubview(toolbar)

        let list = SettingsCardView(cornerRadius: 10)
        list.widthAnchor.constraint(equalToConstant: 680).isActive = true

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        header.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 5, right: 12)
        let iconHeader = NSTextField(labelWithString: "")
        iconHeader.widthAnchor.constraint(equalToConstant: 38).isActive = true
        let triggerHeader = compactColumnHeader("Trigger", width: 120)
        let actionHeader = compactColumnHeader("Action", width: 160)
        let targetHeader = compactColumnHeader("Target", width: 205)
        let deleteHeader = NSTextField(labelWithString: "")
        deleteHeader.widthAnchor.constraint(equalToConstant: 28).isActive = true
        [iconHeader, triggerHeader, actionHeader, targetHeader, deleteHeader].forEach(header.addArrangedSubview)
        header.translatesAutoresizingMaskIntoConstraints = false
        list.addSubview(header)

        let table = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("HotkeyBinding"))
        column.width = 680
        column.resizingMask = []
        table.addTableColumn(column)
        table.headerView = nil
        table.delegate = self
        table.dataSource = self
        table.rowHeight = 60
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.backgroundColor = .clear
        table.focusRingType = .none
        table.gridStyleMask = []
        table.translatesAutoresizingMaskIntoConstraints = false
        let viewport = NSScrollView()
        viewport.hasVerticalScroller = true
        viewport.drawsBackground = false
        viewport.documentView = table
        viewport.translatesAutoresizingMaskIntoConstraints = false
        list.addSubview(viewport)
        hotkeyTableView = table

        let tableHeight = viewport.heightAnchor.constraint(
            equalToConstant: min(360, max(60, CGFloat(configuration.hotkeys.count) * table.rowHeight))
        )
        hotkeyTableHeightConstraint = tableHeight
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: list.topAnchor),
            header.leadingAnchor.constraint(equalTo: list.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: list.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 32),
            viewport.topAnchor.constraint(equalTo: header.bottomAnchor),
            viewport.leadingAnchor.constraint(equalTo: list.leadingAnchor),
            viewport.trailingAnchor.constraint(equalTo: list.trailingAnchor),
            viewport.bottomAnchor.constraint(equalTo: list.bottomAnchor),
            tableHeight
        ])

        stack.addArrangedSubview(list)
        stack.addArrangedSubview(note("Select a trigger to record a keyboard shortcut or mouse side button (optionally with modifiers). Simulated shortcuts post one key-down/key-up pair, and duplicate triggers are rejected."))
        let page = scrollable(stack)
        if let focusID {
            focusHotkeyRow(id: focusID)
        }
        return page
    }

    private func makeHotkeyTableCell(binding: HotkeyBinding, index: Int) -> NSView {
        let cell = HotkeyTableCellView()
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: cell.topAnchor),
            row.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: cell.bottomAnchor)
        ])

        row.addArrangedSubview(hotkeyIconView(for: binding.action))

        let recorder = HotkeyRecorderButton(binding: binding, allowsMouseButton: true)
        recorder.onRecordingBegan = { [weak self, weak recorder] in
            guard let self, let recorder else { return }
            self.beginHotkeyRecording(recorder)
        }
        recorder.onRecordingEnded = { [weak self, weak recorder] in
            guard let self, let recorder else { return }
            self.endHotkeyRecording(recorder)
        }
        recorder.onRecordAsync = { [weak self] modifiers, key, mouseButton, finish in
            guard let self, self.configuration.hotkeys.indices.contains(index) else {
                finish(.rejected(MutationError.hotkeyChangedExternally.localizedDescription)); return
            }
            let trigger: HotkeyTrigger = mouseButton.map {
                HotkeyTrigger.mouseButton($0, modifiers: modifiers)
            }
                ?? .keyboard(HotkeyShortcut(modifiers: modifiers, key: key))
            let result = self.persist(reportFailure: false, completion: { result in
                switch result {
                case .success: finish(.accepted)
                case let .failure(error): finish(.rejected(error.localizedDescription))
                }
            }) { latest in
                guard let latestIndex = self.resolveHotkeyIndex(
                    for: binding,
                    preferredIndex: index,
                    in: latest.hotkeys
                ) else { throw MutationError.hotkeyChangedExternally }
                if let conflict = latest.conflictingHotkey(for: trigger, excluding: latestIndex) {
                    throw MutationError.hotkeyConflict(self.hotkeyActionDescription(conflict.action))
                }
                latest.hotkeys[latestIndex].modifiers = modifiers
                latest.hotkeys[latestIndex].key = key
                latest.hotkeys[latestIndex].mouseButton = mouseButton
            }
            switch result {
            case .success: break
            case let .failure(error):
                finish(.rejected(error.localizedDescription))
            }
        }
        recorder.widthAnchor.constraint(equalToConstant: 120).isActive = true
        cell.recorder = recorder
        row.addArrangedSubview(recorder)

        let actionPopup = NSPopUpButton()
        for kind in editableHotkeyActionKinds {
            let item = NSMenuItem(title: hotkeyActionTitle(kind), action: nil, keyEquivalent: "")
            item.representedObject = kind.rawValue
            actionPopup.menu?.addItem(item)
        }
        actionPopup.selectItem(withTitle: hotkeyActionTitle(binding.action.kind))
        actionPopup.tag = index
        actionPopup.target = self
        actionPopup.action = #selector(hotkeyActionChanged(_:))
        actionPopup.controlSize = .small
        actionPopup.widthAnchor.constraint(equalToConstant: 160).isActive = true
        row.addArrangedSubview(actionPopup)

        let target = hotkeyTargetControl(for: binding, index: index)
        target.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(target)

        let delete = NSButton(
            image: NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete hotkey") ?? NSImage(),
            target: self,
            action: #selector(deleteHotkey(_:))
        )
        delete.tag = index
        delete.isBordered = false
        delete.contentTintColor = .secondaryLabelColor
        delete.toolTip = "Delete this binding"
        delete.widthAnchor.constraint(equalToConstant: 28).isActive = true
        delete.heightAnchor.constraint(equalToConstant: 28).isActive = true
        row.addArrangedSubview(delete)
        return cell
    }

    private func reloadHotkeyTable(focusID: String? = nil) {
        hotkeyCountLabel?.stringValue = "\(configuration.hotkeys.count) bindings"
        if let table = hotkeyTableView {
            hotkeyTableHeightConstraint?.constant = min(360, max(60, CGFloat(configuration.hotkeys.count) * table.rowHeight))
            table.reloadData()
        }
        if let focusID { focusHotkeyRow(id: focusID) }
    }

    private func focusHotkeyRow(id: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let table = self.hotkeyTableView,
                  let index = self.configuration.hotkeys.firstIndex(where: { $0.id == id }) else { return }
            self.contentContainer.layoutSubtreeIfNeeded()
            let rowRect = table.rect(ofRow: index).insetBy(dx: -10, dy: -8)
            _ = table.scrollToVisible(rowRect)
            table.layoutSubtreeIfNeeded()
            let cell = table.view(atColumn: 0, row: index, makeIfNecessary: true) as? HotkeyTableCellView
            cell?.recorder?.startRecording()
        }
    }

    private var editableHotkeyActionKinds: [HotkeyAction.Kind] {
        [
            .focusApplication,
            .simulateKeystroke,
            .runScript,
            .translateSelection,
            .captureScreenshot,
            .toggleScreenRecording,
            .showFocusedWindowInfo,
            .reloadConfiguration,
            .toggleFinder,
            .toggleTerminal,
            .callInterface
        ]
    }

    private func compactColumnHeader(_ title: String, width: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        return label
    }

    private func hotkeyActionTitle(_ kind: HotkeyAction.Kind) -> String {
        switch kind {
        case .focusApplication: "Focus Application"
        case .simulateKeystroke: "Simulate Keystroke"
        case .runScript: "Run Python Script"
        case .translateSelection: "Translate Selection"
        case .captureScreenshot: "Capture Screenshot"
        case .toggleScreenRecording: "Toggle Screen Recording"
        case .showFocusedWindowInfo: "Focused Window Info"
        case .reloadConfiguration: "Reload Configuration"
        case .toggleFinder: "Toggle Finder"
        case .toggleTerminal: "Toggle Terminal"
        case .callInterface: "Built-in Interface"
        }
    }

    private func defaultHotkeyAction(for kind: HotkeyAction.Kind) -> HotkeyAction {
        switch kind {
        case .simulateKeystroke:
            HotkeyAction(kind: kind, modifiers: ["ctrl"], key: "Down")
        case .runScript:
            HotkeyAction(kind: kind, function: "main")
        case .callInterface:
            HotkeyAction(kind: kind, interfaceName: "focusedWindowInfo")
        default:
            HotkeyAction(kind: kind)
        }
    }

    private func hotkeyTargetControl(for binding: HotkeyBinding, index: Int) -> NSView {
        switch binding.action.kind {
        case .focusApplication:
            let button = NSButton(
                title: selectedApplicationName(for: binding.action) ?? "Choose Application…",
                target: self,
                action: #selector(chooseHotkeyTarget(_:))
            )
            button.tag = index
            button.bezelStyle = .rounded
            button.image = applicationIcon(for: binding.action)
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = binding.action.path
            button.controlSize = .small
            button.widthAnchor.constraint(equalToConstant: 205).isActive = true
            return button
        case .runScript:
            let name = binding.action.path.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? "Choose Python Script…"
            let button = NSButton(title: name, target: self, action: #selector(chooseHotkeyTarget(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            button.image = NSImage(systemSymbolName: "doc.badge.gearshape", accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.toolTip = binding.action.path
            button.controlSize = .small
            button.widthAnchor.constraint(equalToConstant: 205).isActive = true
            return button
        case .simulateKeystroke:
            let syntheticBinding = HotkeyBinding(
                modifiers: binding.action.modifiers ?? ["ctrl"],
                key: binding.action.key ?? "Down",
                action: binding.action
            )
            let recorder = HotkeyRecorderButton(binding: syntheticBinding, allowsMouseButton: false)
            recorder.onRecordingBegan = { [weak self, weak recorder] in
                guard let self, let recorder else { return }
                self.beginHotkeyRecording(recorder)
            }
            recorder.onRecordingEnded = { [weak self, weak recorder] in
                guard let self, let recorder else { return }
                self.endHotkeyRecording(recorder)
            }
            recorder.onRecord = { [weak self] modifiers, key, _ in
                guard let self, self.configuration.hotkeys.indices.contains(index) else {
                    return .rejected(MutationError.hotkeyChangedExternally.localizedDescription)
                }
                let original = self.configuration.hotkeys[index]
                let result = self.persist(reportFailure: false) { latest in
                    guard let latestIndex = self.resolveHotkeyIndex(
                        for: original,
                        preferredIndex: index,
                        in: latest.hotkeys
                    ) else { throw MutationError.hotkeyChangedExternally }
                    latest.hotkeys[latestIndex].action.modifiers = modifiers
                    latest.hotkeys[latestIndex].action.key = key
                }
                switch result {
                case .success: return .accepted
                case let .failure(error):
                    self.didFail(error)
                    return .rejected(error.localizedDescription)
                }
            }
            recorder.controlSize = .small
            recorder.widthAnchor.constraint(equalToConstant: 205).isActive = true
            return recorder
        default:
            let label = NSTextField(labelWithString: hotkeyActionDescription(binding.action))
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
            label.widthAnchor.constraint(equalToConstant: 205).isActive = true
            return label
        }
    }

    private func hotkeyIconView(for action: HotkeyAction) -> NSView {
        let container = SettingsIconWell()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.widthAnchor.constraint(equalToConstant: 38).isActive = true
        container.heightAnchor.constraint(equalToConstant: 38).isActive = true

        let imageView = NSImageView()
        imageView.image = applicationIcon(for: action)
            ?? NSImage(systemSymbolName: hotkeyActionSymbol(action.kind), accessibilityDescription: nil)
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6)
        ])
        return container
    }

    private func hotkeyActionSymbol(_ kind: HotkeyAction.Kind) -> String {
        switch kind {
        case .focusApplication: "app"
        case .simulateKeystroke: "keyboard.badge.ellipsis"
        case .runScript: "terminal"
        case .translateSelection: "character.bubble"
        case .captureScreenshot: "camera.viewfinder"
        case .toggleScreenRecording: "record.circle"
        case .showFocusedWindowInfo: "info.window"
        case .reloadConfiguration: "arrow.clockwise"
        case .toggleFinder: "folder"
        case .toggleTerminal: "apple.terminal"
        case .callInterface: "switch.2"
        }
    }

    private func applicationIcon(for action: HotkeyAction) -> NSImage? {
        guard action.kind == .focusApplication else { return nil }
        let url = action.path.map(URL.init(fileURLWithPath:))
            ?? action.bundleIdentifier.flatMap(NSWorkspace.shared.urlForApplication(withBundleIdentifier:))
        guard let url else { return nil }
        if let cached = applicationIcons[url.path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 32, height: 32)
        applicationIcons[url.path] = icon
        return icon
    }

    private func selectedApplicationName(for action: HotkeyAction) -> String? {
        if let path = action.path {
            return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }
        if let bundleIdentifier = action.bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return url.deletingPathExtension().lastPathComponent
        }
        return nil
    }

    @objc private func hotkeyActionChanged(_ sender: NSPopUpButton) {
        endActiveHotkeyRecording()
        let index = sender.tag
        guard configuration.hotkeys.indices.contains(index),
              let rawValue = sender.selectedItem?.representedObject as? String,
              let kind = HotkeyAction.Kind(rawValue: rawValue) else { return }
        let original = configuration.hotkeys[index]
        let action = defaultHotkeyAction(for: kind)
        if case .success = persist({ latest in
            guard let latestIndex = self.resolveHotkeyIndex(
                for: original,
                preferredIndex: index,
                in: latest.hotkeys
            ) else { throw MutationError.hotkeyChangedExternally }
            latest.hotkeys[latestIndex].action = action
        }) {
            reloadHotkeyTable()
        }
    }

    @objc private func chooseHotkeyTarget(_ sender: NSButton) {
        endActiveHotkeyRecording()
        let index = sender.tag
        guard configuration.hotkeys.indices.contains(index), let window else { return }
        let original = configuration.hotkeys[index]
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.resolvesAliases = true
        switch original.action.kind {
        case .focusApplication:
            panel.title = "Choose an Application"
            panel.prompt = "Choose"
            panel.allowedContentTypes = [.application]
            panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        case .runScript:
            panel.title = "Choose a Python Script"
            panel.prompt = "Choose"
            if let python = UTType(filenameExtension: "py") { panel.allowedContentTypes = [python] }
        default:
            return
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            let bundleIdentifier = original.action.kind == .focusApplication
                ? Bundle(url: url)?.bundleIdentifier
                : nil
            let result = self.persist { latest in
                guard let latestIndex = self.resolveHotkeyIndex(
                    for: original,
                    preferredIndex: index,
                    in: latest.hotkeys
                ) else { throw MutationError.hotkeyChangedExternally }
                latest.hotkeys[latestIndex].action.path = url.path
                latest.hotkeys[latestIndex].action.bundleIdentifier = bundleIdentifier
                if latest.hotkeys[latestIndex].action.kind == .runScript,
                   latest.hotkeys[latestIndex].action.function == nil {
                    latest.hotkeys[latestIndex].action.function = "main"
                }
            }
            if case .success = result { self.reloadHotkeyTable() }
        }
    }

    @objc private func deleteHotkey(_ sender: NSButton) {
        endActiveHotkeyRecording()
        let index = sender.tag
        guard configuration.hotkeys.indices.contains(index) else { return }
        let original = configuration.hotkeys[index]
        if case .success = persist({ latest in
            guard let latestIndex = self.resolveHotkeyIndex(
                for: original,
                preferredIndex: index,
                in: latest.hotkeys
            ) else { throw MutationError.hotkeyChangedExternally }
            latest.hotkeys.remove(at: latestIndex)
        }) {
            reloadHotkeyTable()
        }
    }

    private func makeCapturePage() -> NSView {
        let stack = pageStack()
        var deps: [ConditionalRow] = []
        let capture = configuration.capture.sanitized

        stack.addArrangedSubview(section(header: "Screenshot", rows: [
            (formRow(
                title: "Save directory",
                hint: "PNG files are written here when Save is used.",
                control: directoryPicker(capture.screenshotSaveDirectory, field: .screenshotSaveDirectory)
            ), nil),
            (formRow(
                title: "Copy by default",
                hint: "Return and ⌘C still copy even when this is off.",
                control: boolSwitch(tag: 30, on: capture.copyScreenshotToClipboard, action: #selector(toggleCopyScreenshot))
            ), nil),
            (formRow(
                title: "Save to disk",
                hint: "Used by the Save button after annotation.",
                control: boolSwitch(tag: 31, on: capture.saveScreenshotToDisk, action: #selector(toggleSaveScreenshot))
            ), nil)
        ], into: &deps))

        let resolution = NSPopUpButton(frame: .zero, pullsDown: false)
        resolution.controlSize = .small
        for option in CaptureMediaSettings.RecordingResolution.allCases {
            resolution.addItem(withTitle: option.displayName)
            resolution.lastItem?.representedObject = option.rawValue
        }
        resolution.selectItem(withTitle: capture.recordingResolution.displayName)
        resolution.target = self
        resolution.action = #selector(changeRecordingResolution(_:))
        resolution.widthAnchor.constraint(equalToConstant: 170).isActive = true

        stack.addArrangedSubview(section(header: "Screen Recording", rows: [
            (formRow(
                title: "Save directory",
                hint: "MP4 recordings are written here.",
                control: directoryPicker(capture.recordingSaveDirectory, field: .recordingSaveDirectory)
            ), nil),
            (formRow(
                title: "Resolution",
                hint: "Energy caps the long edge near 1280 px.",
                control: resolution
            ), nil),
            (formRow(
                title: "Frame rate",
                hint: "8…30 fps. Lower values use less power.",
                control: editableField(String(capture.recordingFrameRate), field: .recordingFrameRate, width: 90)
            ), nil),
            (formRow(
                title: "Bitrate (kbps)",
                hint: "800…20000. Keep this modest for long recordings.",
                control: editableField(String(capture.recordingBitrateKbps), field: .recordingBitrateKbps, width: 90)
            ), nil),
            (formRow(
                title: "System audio",
                hint: "Requires Screen Recording permission.",
                control: boolSwitch(tag: 32, on: capture.captureSystemAudio, action: #selector(toggleSystemAudio))
            ), nil),
            (formRow(
                title: "Microphone",
                hint: "Turning this on shows the system Allow dialog. TSMacTools only appears in System Settings after that prompt; it cannot be added manually.",
                control: microphoneControls(on: capture.captureMicrophone)
            ), nil),
            (formRow(
                title: "Show cursor",
                hint: "Include the pointer in recorded frames.",
                control: boolSwitch(tag: 34, on: capture.showMouseCursorInRecording, action: #selector(toggleRecordingCursor))
            ), nil)
        ], into: &deps))

        stack.addArrangedSubview(note("Defaults: ⌥P screenshot, ⌥G toggle recording. Recording prefers low FPS, capped resolution, H.264 Baseline, and shallow capture queues."))
        conditionalRows[.capture] = deps
        return scrollable(stack)
    }

    @objc private func toggleCopyScreenshot(_ sender: NSSwitch) {
        let value = sender.state == .on
        configuration.capture.copyScreenshotToClipboard = value
        persist { $0.capture.copyScreenshotToClipboard = value }
    }

    @objc private func toggleSaveScreenshot(_ sender: NSSwitch) {
        let value = sender.state == .on
        configuration.capture.saveScreenshotToDisk = value
        persist { $0.capture.saveScreenshotToDisk = value }
    }

    @objc private func toggleSystemAudio(_ sender: NSSwitch) {
        let value = sender.state == .on
        configuration.capture.captureSystemAudio = value
        persist { $0.capture.captureSystemAudio = value }
    }

    private func microphoneControls(on: Bool) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        let toggle = boolSwitch(tag: 33, on: on, action: #selector(toggleMicrophone))
        let request = NSButton(title: "Request Access...", target: self, action: #selector(requestMicrophoneAccess))
        request.bezelStyle = .rounded
        request.controlSize = .small
        row.addArrangedSubview(toggle)
        row.addArrangedSubview(request)
        return row
    }

    @objc private func toggleMicrophone(_ sender: NSSwitch) {
        let value = sender.state == .on
        configuration.capture.captureMicrophone = value
        persist { $0.capture.captureMicrophone = value }
        if value {
            Task { @MainActor in
                await promptForMicrophoneAccess()
            }
        }
    }

    @objc private func requestMicrophoneAccess() {
        Task { @MainActor in
            await promptForMicrophoneAccess()
        }
    }

    @MainActor
    private func promptForMicrophoneAccess() async {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // Yield so activation finishes before TCC evaluates the frontmost app.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 150_000_000)

        let prior = MicrophonePermission.authorizationState()
        if prior == .authorized {
            TransientAlertPresenter.shared.show(
                title: "Microphone Ready",
                body: "TSMacTools already has Microphone access (state=\(prior.displayName))."
            )
            return
        }

        if prior == .denied || prior == .restricted {
            let alert = NSAlert()
            alert.messageText = "Microphone Still \(prior.displayName.capitalized)"
            alert.informativeText =
                "macOS still reports \(prior.displayName) for this process, so System Settings will not offer an Add button.\n\n1. Fully quit TSMacTools (status item ▸ Quit)\n2. Run: tccutil reset Microphone local.clearain.MacTools\n3. Relaunch this same app binary\n4. Click Request Access... again and choose Allow on the system dialog\n\nOpening Settings alone cannot register the app."
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Open Settings Anyway")
            if alert.runModal() == .alertSecondButtonReturn {
                openMicrophoneSettings()
            }
            return
        }

        let granted = await MicrophonePermission.requestAccess()
        let after = MicrophonePermission.authorizationState()
        if granted || after == .authorized {
            if !configuration.capture.captureMicrophone {
                configuration.capture.captureMicrophone = true
                persist { $0.capture.captureMicrophone = true }
                showPage(.capture, rebuild: true, animated: false)
            }
            TransientAlertPresenter.shared.show(
                title: "Microphone Allowed",
                body: "Microphone access is enabled for TSMacTools."
            )
            return
        }

        let alert = NSAlert()
        switch after {
        case .denied, .restricted:
            alert.messageText = "Microphone Access \(after.displayName.capitalized)"
            alert.informativeText =
                "The system dialog returned \(after.displayName). TSMacTools should now appear under System Settings ▸ Privacy & Security ▸ Microphone. If it still does not, quit the app and request again after `tccutil reset Microphone local.clearain.MacTools`."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn {
                openMicrophoneSettings()
            }
        case .notDetermined, .unknown, .authorized:
            alert.messageText = "Microphone Dialog Did Not Appear"
            alert.informativeText =
                "TCC state is still \(after.displayName), so System Settings will stay empty. Keep TSMacTools frontmost, click Request Access... again, and watch for the Allow dialog. Do not expect a manual Add button in Settings."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func openMicrophoneSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    @objc private func toggleRecordingCursor(_ sender: NSSwitch) {
        let value = sender.state == .on
        configuration.capture.showMouseCursorInRecording = value
        persist { $0.capture.showMouseCursorInRecording = value }
    }

    @objc private func changeRecordingResolution(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let value = CaptureMediaSettings.RecordingResolution(rawValue: raw) else { return }
        configuration.capture.recordingResolution = value
        persist { $0.capture.recordingResolution = value }
    }

    private func directoryPicker(_ value: String, field: ConfigurationField) -> NSButton {
        let button = NSButton(title: value, target: self, action: #selector(chooseDirectory(_:)))
        button.tag = field.rawValue
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.toolTip = value
        button.lineBreakMode = .byTruncatingMiddle
        button.widthAnchor.constraint(equalToConstant: 320).isActive = true
        return button
    }

    @objc private func chooseDirectory(_ sender: NSButton) {
        guard let field = ConfigurationField(rawValue: sender.tag) else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: displayedValue(for: field), isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try persistTextValue(url.path, for: field)
            sender.title = url.path
            sender.toolTip = url.path
        } catch {
            didFail(error)
        }
    }

    @objc private func addHotkey() {
        endActiveHotkeyRecording()
        let used = Set(configuration.hotkeys.map(\.trigger))
        let key = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").first { candidate in
            !used.contains(.keyboard(HotkeyShortcut(modifiers: ["ctrl", "alt", "cmd", "shift"], key: String(candidate))))
        }.map(String.init) ?? "."
        let binding = HotkeyBinding(
            id: UUID().uuidString,
            modifiers: ["ctrl", "alt", "cmd", "shift"],
            key: key,
            action: HotkeyAction(kind: .focusApplication)
        )
        if case .success = persist({ $0.hotkeys.append(binding) }) {
            if hotkeyTableView == nil {
                pendingHotkeyFocusID = binding.id
                showPage(.hotkeys, rebuild: true, animated: false)
            } else {
                reloadHotkeyTable(focusID: binding.id)
            }
        }
    }

    private func makeScrollingPage() -> NSView {
        let stack = pageStack()
        var deps: [ConditionalRow] = []

        let scrollOn: (UserConfiguration) -> Bool = { $0.scroll.enabled }
        let customTuning: (UserConfiguration) -> Bool = { $0.scroll.enabled && $0.scroll.preset == .custom }

        let preset = NSPopUpButton()
        let selectablePresets = ScrollPreset.allCases
        preset.addItems(withTitles: selectablePresets.map(\.displayName))
        preset.selectItem(at: selectablePresets.firstIndex(of: configuration.scroll.preset) ?? 0)
        preset.target = self
        preset.action = #selector(presetChanged(_:))
        preset.controlSize = .small
        preset.widthAnchor.constraint(equalToConstant: 140).isActive = true
        presetPopup = preset

        stack.addArrangedSubview(section(header: "Smooth scrolling", rows: [
            (formRow(title: "Enable smooth mouse scrolling",
                     control: boolSwitch(tag: 10, on: configuration.scroll.enabled, action: #selector(scrollToggleChanged(_:)))), nil),
            (formRow(title: "Curve",
                     hint: configuration.scroll.preset.summary,
                     control: preset,
                     hintLabel: { self.presetSummary = $0 }), scrollOn),
            (formRow(title: "Smooth vertical wheel",
                     control: boolSwitch(tag: 11, on: configuration.scroll.smoothVertical, action: #selector(scrollToggleChanged(_:)))), scrollOn),
            (formRow(title: "Smooth horizontal wheel",
                     control: boolSwitch(tag: 12, on: configuration.scroll.smoothHorizontal, action: #selector(scrollToggleChanged(_:)))), scrollOn),
            (formRow(title: "Reverse vertical direction",
                     control: boolSwitch(tag: 13, on: configuration.scroll.reverseVertical, action: #selector(scrollToggleChanged(_:)))), scrollOn),
            (formRow(title: "Reverse horizontal direction",
                     control: boolSwitch(tag: 14, on: configuration.scroll.reverseHorizontal, action: #selector(scrollToggleChanged(_:)))), scrollOn),
            (formRow(title: "Leave trackpad gestures untouched",
                     hint: "Native trackpad and Magic Mouse gestures bypass the mouse engine.",
                     control: boolSwitch(tag: 15, on: configuration.scroll.excludeTrackpad, action: #selector(scrollToggleChanged(_:)))), scrollOn)
        ], into: &deps))

        let step = tuningSlider(value: configuration.scroll.tuning.step, range: 1 ... 120, tag: 20)
        let speed = tuningSlider(value: configuration.scroll.tuning.speed, range: 0.2 ... 6, tag: 21)
        let duration = tuningSlider(value: configuration.scroll.tuning.duration, range: 0.08 ... 1.5, tag: 22)
        let acceleration = tuningSlider(value: configuration.scroll.tuning.acceleration, range: 0 ... 1, tag: 23)
        let deadZone = tuningSlider(value: configuration.scroll.tuning.deadZone, range: 0.01 ... 2, tag: 24)
        stepSlider = step.slider; stepValue = step.value
        speedSlider = speed.slider; speedValue = speed.value
        durationSlider = duration.slider; durationValue = duration.value
        accelerationSlider = acceleration.slider; accelerationValue = acceleration.value
        deadZoneSlider = deadZone.slider; deadZoneValue = deadZone.value
        updateTuningLabels()

        let tuning = section(header: "Curve tuning", rows: [
            (formRow(title: "Step",
                     hint: "Minimum distance produced by one wheel notch.",
                     control: step.view), nil),
            (formRow(title: "Speed",
                     hint: "Overall distance multiplier.",
                     control: speed.view), nil),
            (formRow(title: "Duration",
                     hint: "Time for approximately 99% of the momentum tail.",
                     control: duration.view), nil),
            (formRow(title: "Acceleration",
                     hint: "Adds bounded speed during a rapid wheel burst.",
                     control: acceleration.view), nil),
            (formRow(title: "Stop threshold",
                     hint: "Ends a tail once remaining movement is visually negligible.",
                     control: deadZone.view), nil)
        ], into: &deps)
        deps.append(ConditionalRow(condition: customTuning, setHidden: { hidden in tuning.isHidden = hidden }))
        stack.addArrangedSubview(tuning)

        stack.addArrangedSubview(note("Select Custom to fine-tune individual curve values. Precise, Balanced, Fluid, and Glide are TSMacTools presets, not Mos or Smooze compatibility claims."))
        conditionalRows[.scrolling] = deps
        return scrollable(stack)
    }

    @objc private func generalControlChanged(_ sender: NSSwitch) {
        let value = sender.state == .on
        switch sender.tag {
        case 1:
            configuration.windowSwitcher.enabled = value
            persist { $0.windowSwitcher.enabled = value }
        case 2:
            configuration.translation.enabled = value
            persist { $0.translation.enabled = value }
        case 3:
            configuration.windowSwitcher.debug = value
            persist { $0.windowSwitcher.debug = value }
        case 4:
            configuration.windowSwitcher.followFocusedScreen = value
            persist { $0.windowSwitcher.followFocusedScreen = value }
        case 5:
            configuration.translation.normalizePDFLineBreaks = value
            persist { $0.translation.normalizePDFLineBreaks = value }
        case 6:
            configuration.windowSwitcher.restorePreviousApplicationWhenNoWindows = value
            persist { $0.windowSwitcher.restorePreviousApplicationWhenNoWindows = value }
        default: return
        }
        applyConditionalVisibility(for: selectedPage)
    }

    @objc private func providerChanged(_ sender: NSPopUpButton) {
        let provider = ["google_web", "google", "llm"][sender.indexOfSelectedItem.clamped(to: 0 ... 2)]
        configuration.translation.provider = provider
        persist { $0.translation.provider = provider }
        applyConditionalVisibility(for: selectedPage)
        if provider == "llm" {
            refreshLLMModels(userInitiated: false)
        }
    }

    private func makeModelPicker() -> NSPopUpButton {
        let popup = NSPopUpButton()
        popup.target = self
        popup.action = #selector(modelChanged(_:))
        // Match Base URL / API key width so long model IDs cannot stretch the card.
        popup.widthAnchor.constraint(equalToConstant: 320).isActive = true
        popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        popup.setContentHuggingPriority(.required, for: .horizontal)
        if let cell = popup.cell as? NSPopUpButtonCell {
            cell.lineBreakMode = .byTruncatingTail
            cell.usesItemFromMenu = true
        }
        modelPopup = popup
        rebuildModelPopup()
        refreshLLMModels(userInitiated: false)
        return popup
    }

    private func makeThinkingLevelPicker() -> NSPopUpButton {
        let popup = NSPopUpButton()
        popup.target = self
        popup.action = #selector(thinkingLevelChanged(_:))
        thinkingLevelPopup = popup
        rebuildThinkingLevelPopup()
        return popup
    }

    private func makeModelsRefreshControl() -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8

        let button = NSButton(title: "Refresh models", target: self, action: #selector(refreshModelsClicked(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small

        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        modelsStatusLabel = status

        stack.addArrangedSubview(button)
        stack.addArrangedSubview(status)
        return stack
    }

    private func makeModelLimitsLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
        modelLimitsLabel = label
        refreshModelLimitsLabel()
        return label
    }

    private func refreshModelLimitsLabel() {
        guard let label = modelLimitsLabel else { return }
        if let model = llmModels.first(where: { $0.id == configuration.translation.model }),
           let budget = TranslationTokenBudget.derived(from: model) {
            label.stringValue = budget.summary
            label.toolTip = "Synced from /v1/models for \(model.id)"
            return
        }
        if configuration.translation.contextWindowTokens > 0 {
            label.stringValue = TranslationTokenBudget.Values(
                contextWindowTokens: configuration.translation.contextWindowTokens,
                outputTokenLimit: configuration.translation.outputTokenLimit,
                requestTokenLimit: configuration.translation.requestTokenLimit
            ).summary + " (saved)"
            label.toolTip = "Waiting for /v1/models; showing the last saved values."
            return
        }
        label.stringValue = "Unavailable until /v1/models loads"
        label.toolTip = "Select a reachable Base URL and refresh the model catalog."
    }

    @objc private func refreshModelsClicked(_ sender: NSButton) {
        refreshLLMModels(userInitiated: true)
    }

    @objc private func modelChanged(_ sender: NSPopUpButton) {
        guard sender.indexOfSelectedItem >= 0,
              let modelID = sender.selectedItem?.representedObject as? String,
              !modelID.isEmpty else { return }
        applySelectedModel(modelID, updateBudgets: true)
    }

    @objc private func thinkingLevelChanged(_ sender: NSPopUpButton) {
        guard sender.indexOfSelectedItem >= 0,
              let level = sender.selectedItem?.representedObject as? String else { return }
        applyThinkingLevel(level)
    }

    private func applySelectedModel(_ modelID: String, updateBudgets: Bool) {
        configuration.translation.model = modelID
        if let model = llmModels.first(where: { $0.id == modelID }) {
            if model.supportsReasoningParameter {
                configuration.translation.thinkingParameter = "reasoning"
            }
            if updateBudgets, let budget = TranslationTokenBudget.derived(from: model) {
                configuration.translation.contextWindowTokens = budget.contextWindowTokens
                configuration.translation.outputTokenLimit = budget.outputTokenLimit
                configuration.translation.requestTokenLimit = budget.requestTokenLimit
            }
            let levels = model.reasoningLevels
            let current = TranslationThinking.normalizedLevel(
                thinkingLevel: configuration.translation.thinkingLevel,
                thinkingEnabled: configuration.translation.thinkingEnabled,
                availableLevels: levels
            )
            let resolved: String
            if levels.isEmpty {
                resolved = configuration.translation.thinkingEnabled ? "high" : "none"
            } else if levels.contains(current) {
                resolved = current
            } else {
                resolved = levels.contains("none") ? "none" : (levels.first ?? current)
            }
            configuration.translation.thinkingLevel = resolved
            configuration.translation.thinkingEnabled = TranslationThinking.isEnabled(level: resolved)
        }
        persist { latest in
            latest.translation.model = modelID
            latest.translation.thinkingParameter = self.configuration.translation.thinkingParameter
            latest.translation.thinkingLevel = self.configuration.translation.thinkingLevel
            latest.translation.thinkingEnabled = self.configuration.translation.thinkingEnabled
            if updateBudgets {
                latest.translation.contextWindowTokens = self.configuration.translation.contextWindowTokens
                latest.translation.outputTokenLimit = self.configuration.translation.outputTokenLimit
                latest.translation.requestTokenLimit = self.configuration.translation.requestTokenLimit
            }
        }
        rebuildThinkingLevelPopup()
        refreshModelLimitsLabel()
    }

    private func applyThinkingLevel(_ level: String) {
        let normalized = TranslationThinking.normalizedLevel(
            thinkingLevel: level,
            thinkingEnabled: TranslationThinking.isEnabled(level: level)
        )
        configuration.translation.thinkingLevel = normalized
        configuration.translation.thinkingEnabled = TranslationThinking.isEnabled(level: normalized)
        if configuration.translation.thinkingParameter == "include_reasoning"
            || configuration.translation.thinkingParameter.isEmpty {
            configuration.translation.thinkingParameter = "reasoning"
        }
        persist { latest in
            latest.translation.thinkingLevel = normalized
            latest.translation.thinkingEnabled = TranslationThinking.isEnabled(level: normalized)
            latest.translation.thinkingParameter = self.configuration.translation.thinkingParameter
        }
    }

    private func rebuildModelPopup() {
        guard let popup = modelPopup else { return }
        let current = configuration.translation.model
        popup.removeAllItems()
        let models = LLMModelCatalog.chatCompletionModels(in: llmModels)
        if models.isEmpty {
            let title = current.isEmpty ? "No models loaded" : current
            popup.addItem(withTitle: title)
            popup.lastItem?.representedObject = current
            popup.lastItem?.toolTip = title
            popup.selectItem(at: 0)
            popup.toolTip = title
            popup.isEnabled = !current.isEmpty
            return
        }
        for model in models {
            // Menu items keep the full title; only the closed button truncates via fixed width.
            popup.addItem(withTitle: model.menuTitle)
            popup.lastItem?.representedObject = model.id
            popup.lastItem?.toolTip = model.menuTitle
        }
        if !models.contains(where: { $0.id == current }), !current.isEmpty {
            let customTitle = "\(current) (custom)"
            popup.insertItem(withTitle: customTitle, at: 0)
            popup.item(at: 0)?.representedObject = current
            popup.item(at: 0)?.toolTip = customTitle
        }
        if let index = popup.itemArray.firstIndex(where: { ($0.representedObject as? String) == current }) {
            popup.selectItem(at: index)
        } else if popup.numberOfItems > 0 {
            popup.selectItem(at: 0)
        }
        popup.toolTip = popup.selectedItem?.title
        popup.isEnabled = true
    }

    private func rebuildThinkingLevelPopup() {
        guard let popup = thinkingLevelPopup else { return }
        let model = llmModels.first(where: { $0.id == configuration.translation.model })
        var levels = model?.reasoningLevels ?? []
        if levels.isEmpty {
            levels = configuration.translation.thinkingEnabled ? ["high"] : ["none"]
            if model?.supportsReasoningParameter == true, !levels.contains("none") {
                levels.insert("none", at: 0)
            }
        }
        let current = TranslationThinking.normalizedLevel(
            thinkingLevel: configuration.translation.thinkingLevel,
            thinkingEnabled: configuration.translation.thinkingEnabled,
            availableLevels: levels
        )
        popup.removeAllItems()
        for level in levels {
            let title: String
            switch level {
            case "none", "off": title = "Off (\(level))"
            default: title = level
            }
            popup.addItem(withTitle: title)
            popup.lastItem?.representedObject = level
        }
        if !levels.contains(current) {
            popup.insertItem(withTitle: "\(current) (saved)", at: 0)
            popup.item(at: 0)?.representedObject = current
        }
        if let index = popup.itemArray.firstIndex(where: { ($0.representedObject as? String) == current }) {
            popup.selectItem(at: index)
        } else if popup.numberOfItems > 0 {
            popup.selectItem(at: 0)
        }
        popup.isEnabled = model?.supportsReasoningParameter != false || !(model?.reasoningLevels.isEmpty ?? true)
    }

    private func refreshLLMModels(userInitiated: Bool) {
        guard configuration.translation.provider == "llm" else { return }
        guard let modelsURLString = TranslationEndpoint.modelsURL(from: configuration.translation.endpoint),
              let modelsURL = URL(string: modelsURLString) else {
            modelsStatusLabel?.stringValue = "Invalid Base URL"
            return
        }
        modelsFetchGeneration += 1
        let generation = modelsFetchGeneration
        if userInitiated {
            modelsStatusLabel?.stringValue = "Loading…"
        }
        let apiKey = configuration.translation.apiKey
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var request = URLRequest(url: modelsURL)
            request.httpMethod = "GET"
            request.timeoutInterval = 15
            if !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            let result: Result<[LLMModelDescriptor], Error>
            do {
                let (data, response) = try Self.fetchData(for: request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    throw MutationError.invalidValue("HTTP \(http.statusCode) from /v1/models\(body.isEmpty ? "" : ": \(body.prefix(180))")")
                }
                result = .success(try LLMModelCatalog.parse(data))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                guard let self, generation == self.modelsFetchGeneration else { return }
                switch result {
                case .success(let models):
                    self.llmModels = models
                    let chatModels = LLMModelCatalog.chatCompletionModels(in: models)
                    self.modelsStatusLabel?.stringValue = "\(chatModels.count) chat models"
                    self.rebuildModelPopup()
                    if chatModels.contains(where: { $0.id == self.configuration.translation.model }) {
                        // Always rewrite token budgets from /v1/models so Settings never keeps a stale manual value.
                        self.applySelectedModel(self.configuration.translation.model, updateBudgets: true)
                    } else {
                        self.rebuildThinkingLevelPopup()
                        self.refreshModelLimitsLabel()
                    }
                case .failure(let error):
                    self.modelsStatusLabel?.stringValue = userInitiated ? error.localizedDescription : "Models unavailable"
                    self.rebuildModelPopup()
                    self.rebuildThinkingLevelPopup()
                    self.refreshModelLimitsLabel()
                }
            }
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let sender = notification.object as? NSTextField,
              let field = ConfigurationField(rawValue: sender.tag) else { return }
        do {
            try persistTextValue(sender.stringValue, for: field)
        } catch {
            sender.stringValue = displayedValue(for: field)
            didFail(error)
        }
    }

    @objc private func openConfigFile() {
        NSWorkspace.shared.open(configURL)
    }

    private func persistTextValue(_ rawValue: String, for field: ConfigurationField) throws {
        switch field {
        case .switcherWidth:
            let value = try boundedInt(rawValue, name: "Switcher width", range: 320 ... 1600)
            configuration.windowSwitcher.width = value
            persist { $0.windowSwitcher.width = value }
        case .switcherHeight:
            let value = try boundedInt(rawValue, name: "Switcher height", range: 120 ... 1200)
            configuration.windowSwitcher.height = value
            persist { $0.windowSwitcher.height = value }
        case .switcherMaxRows:
            let value = try boundedInt(rawValue, name: "Maximum rows", range: 1 ... 50)
            configuration.windowSwitcher.maxVisibleRows = value
            persist { $0.windowSwitcher.maxVisibleRows = value }
        case .switcherDisplayDelay:
            guard let value = TimeInterval(rawValue), WindowSwitcherSettings.displayDelayRange.contains(value) else {
                throw MutationError.invalidValue("Display delay must be between 0 and 2 seconds.")
            }
            configuration.windowSwitcher.displayDelay = value
            persist { $0.windowSwitcher.displayDelay = value }
        case .pythonPath:
            let value = try requiredText(rawValue, name: "Python path")
            configuration.scripting.pythonPath = value
            persist { $0.scripting.pythonPath = value }
        case .finderBundleIdentifier:
            let value = try requiredText(rawValue, name: "Finder bundle identifier")
            configuration.application.finderBundleIdentifier = value
            persist { $0.application.finderBundleIdentifier = value }
        case .terminalBundleIdentifier:
            let value = try requiredText(rawValue, name: "Terminal bundle identifier")
            configuration.application.terminalBundleIdentifier = value
            persist { $0.application.terminalBundleIdentifier = value }
        case .ignoredApplicationNames:
            let value = rawValue
                .components(separatedBy: CharacterSet(charactersIn: ",\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            configuration.application.ignoredWindowApplicationNames = value
            persist { $0.application.ignoredWindowApplicationNames = value }
        case .googleSourceLanguage:
            let value = try requiredText(rawValue, name: "Source language")
            configuration.translation.googleSourceLanguage = value
            persist { $0.translation.googleSourceLanguage = value }
        case .googleTargetLanguage:
            let value = try requiredText(rawValue, name: "Target language")
            configuration.translation.googleTargetLanguage = value
            persist { $0.translation.googleTargetLanguage = value }
        case .googleTargetLanguageForChinese:
            let value = try requiredText(rawValue, name: "Chinese target language")
            configuration.translation.googleTargetLanguageForChinese = value
            persist { $0.translation.googleTargetLanguageForChinese = value }
        case .copyKeystrokeDelay:
            guard let value = Double(rawValue), value >= 0 else {
                throw MutationError.invalidValue("Copy delay must be a non-negative number.")
            }
            configuration.translation.copyKeystrokeDelay = value
            persist { $0.translation.copyKeystrokeDelay = value }
        case .endpoint:
            let value = try TranslationEndpoint.requestURL(rawValue)
            configuration.translation.endpoint = value
            persist { $0.translation.endpoint = value }
            refreshLLMModels(userInitiated: true)
        case .model:
            let value = try requiredText(rawValue, name: "LLM model")
            configuration.translation.model = value
            persist { $0.translation.model = value }
            rebuildModelPopup()
            rebuildThinkingLevelPopup()
        case .thinkingLevel:
            applyThinkingLevel(rawValue)
        case .contextWindowTokens:
            let value = try positiveInt(rawValue, name: "Context tokens")
            configuration.translation.contextWindowTokens = value
            persist { $0.translation.contextWindowTokens = value }
        case .outputTokenLimit:
            let value = try positiveInt(rawValue, name: "Output tokens")
            configuration.translation.outputTokenLimit = value
            persist { $0.translation.outputTokenLimit = value }
        case .requestTokenLimit:
            guard let value = Int(rawValue), value >= 0 else {
                throw MutationError.invalidValue("Request tokens must be zero or a positive integer.")
            }
            configuration.translation.requestTokenLimit = value
            persist { $0.translation.requestTokenLimit = value }
        case .apiKey:
            configuration.translation.apiKey = rawValue
            persist { $0.translation.apiKey = rawValue }
            refreshLLMModels(userInitiated: true)
        case .googleAPIKey:
            configuration.translation.googleApiKey = rawValue
            persist { $0.translation.googleApiKey = rawValue }
        case .screenshotSaveDirectory:
            let value = try requiredText(rawValue, name: "Screenshot save directory")
            configuration.capture.screenshotSaveDirectory = value
            persist { $0.capture.screenshotSaveDirectory = value }
        case .recordingSaveDirectory:
            let value = try requiredText(rawValue, name: "Recording save directory")
            configuration.capture.recordingSaveDirectory = value
            persist { $0.capture.recordingSaveDirectory = value }
        case .recordingFrameRate:
            let value = try boundedInt(
                rawValue,
                name: "Frame rate",
                range: CaptureMediaSettings.frameRateRange
            )
            configuration.capture.recordingFrameRate = value
            persist { $0.capture.recordingFrameRate = value }
        case .recordingBitrateKbps:
            let value = try boundedInt(
                rawValue,
                name: "Bitrate",
                range: CaptureMediaSettings.bitrateRange
            )
            configuration.capture.recordingBitrateKbps = value
            persist { $0.capture.recordingBitrateKbps = value }
        }
    }

    private func requiredText(_ rawValue: String, name: String) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw MutationError.invalidValue("\(name) cannot be empty.")
        }
        return value
    }

    private func positiveInt(_ rawValue: String, name: String) throws -> Int {
        guard let value = Int(rawValue), value > 0 else {
            throw MutationError.invalidValue("\(name) must be a positive integer.")
        }
        return value
    }

    private func boundedInt(_ rawValue: String, name: String, range: ClosedRange<Int>) throws -> Int {
        guard let value = Int(rawValue), range.contains(value) else {
            throw MutationError.invalidValue("\(name) must be between \(range.lowerBound) and \(range.upperBound).")
        }
        return value
    }

    private static func fetchData(for request: URLRequest) throws -> (Data, URLResponse) {
        let box = FetchBox()
        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            box.data = data
            box.response = response
            box.error = error
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + request.timeoutInterval + 1)
        if let error = box.error { throw error }
        guard let data = box.data, let response = box.response else {
            throw MutationError.invalidValue("No response from /v1/models.")
        }
        return (data, response)
    }

    private final class FetchBox: @unchecked Sendable {
        var data: Data?
        var response: URLResponse?
        var error: Error?
    }

    private func displayedValue(for field: ConfigurationField) -> String {
        switch field {
        case .switcherWidth: String(configuration.windowSwitcher.width)
        case .switcherHeight: String(configuration.windowSwitcher.height)
        case .switcherMaxRows: String(configuration.windowSwitcher.maxVisibleRows)
        case .switcherDisplayDelay: String(format: "%.2f", configuration.windowSwitcher.displayDelay)
        case .pythonPath: configuration.scripting.pythonPath
        case .finderBundleIdentifier: configuration.application.finderBundleIdentifier
        case .terminalBundleIdentifier: configuration.application.terminalBundleIdentifier
        case .ignoredApplicationNames: configuration.application.ignoredWindowApplicationNames.joined(separator: ", ")
        case .googleSourceLanguage: configuration.translation.googleSourceLanguage
        case .googleTargetLanguage: configuration.translation.googleTargetLanguage
        case .googleTargetLanguageForChinese: configuration.translation.googleTargetLanguageForChinese
        case .copyKeystrokeDelay: String(format: "%.2f", configuration.translation.copyKeystrokeDelay)
        case .endpoint: TranslationEndpoint.baseURL(configuration.translation.endpoint)
        case .model: configuration.translation.model
        case .thinkingLevel: TranslationThinking.normalizedLevel(
            thinkingLevel: configuration.translation.thinkingLevel,
            thinkingEnabled: configuration.translation.thinkingEnabled
        )
        case .contextWindowTokens: String(configuration.translation.contextWindowTokens)
        case .outputTokenLimit: String(configuration.translation.outputTokenLimit)
        case .requestTokenLimit: String(configuration.translation.requestTokenLimit)
        case .screenshotSaveDirectory: configuration.capture.screenshotSaveDirectory
        case .recordingSaveDirectory: configuration.capture.recordingSaveDirectory
        case .recordingFrameRate: String(configuration.capture.recordingFrameRate)
        case .recordingBitrateKbps: String(configuration.capture.recordingBitrateKbps)
        case .apiKey: configuration.translation.apiKey
        case .googleAPIKey: configuration.translation.googleApiKey
        }
    }

    @objc private func scrollToggleChanged(_ sender: NSSwitch) {
        let value = sender.state == .on
        switch sender.tag {
        case 10:
            configuration.scroll.enabled = value
            persist { $0.scroll.enabled = value }
        case 11:
            configuration.scroll.smoothVertical = value
            persist { $0.scroll.smoothVertical = value }
        case 12:
            configuration.scroll.smoothHorizontal = value
            persist { $0.scroll.smoothHorizontal = value }
        case 13:
            configuration.scroll.reverseVertical = value
            persist { $0.scroll.reverseVertical = value }
        case 14:
            configuration.scroll.reverseHorizontal = value
            persist { $0.scroll.reverseHorizontal = value }
        case 15:
            configuration.scroll.excludeTrackpad = value
            persist { $0.scroll.excludeTrackpad = value }
        default: return
        }
        applyConditionalVisibility(for: selectedPage)
    }

    @objc private func presetChanged(_ sender: NSPopUpButton) {
        let presets = ScrollPreset.allCases
        guard presets.indices.contains(sender.indexOfSelectedItem) else { return }
        let preset = presets[sender.indexOfSelectedItem]
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(persistPendingTuning),
            object: nil
        )
        pendingTuningChanges.removeAll(keepingCapacity: true)
        configuration.scroll.applyPreset(preset)
        syncTuningControls()
        persist { $0.scroll.applyPreset(preset) }
        syncTuningControls()
        applyConditionalVisibility(for: selectedPage)
    }

    @objc private func tuningChanged(_ sender: NSSlider) {
        guard (20 ... 24).contains(sender.tag) else { return }
        applyTuningChanges([sender.tag: sender.doubleValue], to: &configuration.scroll)
        configuration.scroll.preset = .custom
        pendingTuningChanges[sender.tag] = sender.doubleValue
        presetPopup?.selectItem(withTitle: ScrollPreset.custom.displayName)
        presetSummary?.stringValue = ScrollPreset.custom.summary
        updateTuningLabels()
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(persistPendingTuning),
            object: nil
        )
        perform(#selector(persistPendingTuning), with: nil, afterDelay: Self.tuningSaveDelay)
    }

    @objc private func persistPendingTuning() {
        guard !pendingTuningChanges.isEmpty else { return }
        let changes = pendingTuningChanges
        pendingTuningChanges.removeAll(keepingCapacity: true)
        persist { latest in
            latest.scroll.preset = .custom
            self.applyTuningChanges(changes, to: &latest.scroll)
        }
        syncTuningControls()
    }

    @discardableResult
    private func persist(
        reportFailure: Bool = true,
        completion: (@MainActor @Sendable (Result<UserConfiguration, Error>) -> Void)? = nil,
        _ mutation: (inout UserConfiguration) throws -> Void
    ) -> Result<UserConfiguration, Error> {
        do {
            let baseline = lastKnownGoodConfiguration
            var proposed = configuration
            try mutation(&proposed)
            let patch = try ConfigurationPatch(before: baseline, after: proposed)
            configuration = proposed
            (fanRuntime ?? fanLivePanel)?.apply(proposed.fans)
            lastKnownGoodConfiguration = proposed
            saveGeneration += 1
            let generation = saveGeneration
            let url = configURL
            savingQueue.async { [weak self] in
                let store = UserConfigurationStore()
                let result = Result { try store.update(at: url) { try patch.apply(to: &$0) } }
                let recovery = (try? result.get()) ?? (try? store.load(from: url))
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case let .success(saved):
                        self.didSave(saved)
                        if self.saveGeneration == generation {
                            self.configuration = saved
                            self.lastKnownGoodConfiguration = saved
                            (self.fanRuntime ?? self.fanLivePanel)?.apply(saved.fans)
                            self.cachedPageViews = self.cachedPageViews.filter { $0.key == self.selectedPage }
                            if self.selectedPage != .fans || saved.fans.rules.count != self.fanEditorCount { self.scheduleVisiblePageReconciliation() }
                        }
                    case let .failure(error):
                        if self.saveGeneration == generation {
                            if let latest = recovery {
                                self.configuration = latest
                                self.lastKnownGoodConfiguration = latest
                                (self.fanRuntime ?? self.fanLivePanel)?.apply(latest.fans)
                            }
                            self.cachedPageViews = self.cachedPageViews.filter { $0.key == self.selectedPage }
                        }
                        self.scheduleVisiblePageReconciliation()
                        if reportFailure { self.didFail(error) }
                    }
                    completion?(result)
                }
            }
            return .success(proposed)
        } catch {
            if reportFailure { didFail(error) }
            return .failure(error)
        }
    }

    private func reapplyUnsavedTuning(_ changes: [Int: Double]) {
        guard !changes.isEmpty else { return }
        configuration.scroll.preset = .custom
        applyTuningChanges(changes, to: &configuration.scroll)
    }

    private func scheduleVisiblePageReconciliation() {
        guard !reconciliationScheduled else { return }
        reconciliationScheduled = true
        perform(
            #selector(reconcileVisiblePageWhenIdle),
            with: nil,
            afterDelay: Self.reconciliationDelay
        )
    }

    @objc private func reconcileVisiblePageWhenIdle() {
        guard reconciliationScheduled else { return }
        let fieldEditor = window?.fieldEditor(false, for: nil)
        let isEditingText = fieldEditor != nil && window?.firstResponder === fieldEditor
        let isRecordingHotkey = window?.firstResponder is HotkeyRecorderButton
        let isDragging = NSEvent.pressedMouseButtons != 0
        guard pendingTuningChanges.isEmpty, !isEditingText, !isRecordingHotkey, !isDragging else {
            perform(
                #selector(reconcileVisiblePageWhenIdle),
                with: nil,
                afterDelay: Self.reconciliationDelay
            )
            return
        }
        reconciliationScheduled = false
        let scrollPosition = (contentContainer.subviews.first as? NSScrollView)?.contentView.bounds.origin
        showPage(selectedPage, rebuild: true, animated: false)
        contentContainer.layoutSubtreeIfNeeded()
        if let scrollPosition,
           let scrollView = contentContainer.subviews.first as? NSScrollView,
           let documentView = scrollView.documentView {
            let maximumY = max(0, documentView.bounds.height - scrollView.contentView.bounds.height)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: scrollPosition.y.clamped(to: 0 ... maximumY)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func resolveHotkeyIndex(
        for binding: HotkeyBinding,
        preferredIndex: Int,
        in latest: [HotkeyBinding]
    ) -> Int? {
        if let id = binding.id,
           let index = latest.firstIndex(where: { $0.id == id }) {
            return index
        }
        if let index = latest.firstIndex(of: binding) { return index }
        let actionMatches = latest.indices.filter { latest[$0].action == binding.action }
        if actionMatches.count == 1 { return actionMatches[0] }
        if actionMatches.contains(preferredIndex) { return preferredIndex }
        return nil
    }

    private func applyTuningChanges(_ changes: [Int: Double], to scroll: inout ScrollSettings) {
        for (tag, value) in changes {
            switch tag {
            case 20: scroll.tuning.step = value
            case 21: scroll.tuning.speed = value
            case 22: scroll.tuning.duration = value
            case 23: scroll.tuning.acceleration = value
            case 24: scroll.tuning.deadZone = value
            default: continue
            }
        }
        scroll.tuning = scroll.tuning.sanitized
    }

    private func syncTuningControls() {
        stepSlider?.doubleValue = configuration.scroll.tuning.step
        speedSlider?.doubleValue = configuration.scroll.tuning.speed
        durationSlider?.doubleValue = configuration.scroll.tuning.duration
        accelerationSlider?.doubleValue = configuration.scroll.tuning.acceleration
        deadZoneSlider?.doubleValue = configuration.scroll.tuning.deadZone
        presetSummary?.stringValue = configuration.scroll.preset.summary
        updateTuningLabels()
    }

    private func updateTuningLabels() {
        stepValue?.stringValue = String(format: "%.0f pt", configuration.scroll.tuning.step)
        speedValue?.stringValue = String(format: "%.2fx", configuration.scroll.tuning.speed)
        durationValue?.stringValue = String(format: "%.2f s", configuration.scroll.tuning.duration)
        accelerationValue?.stringValue = String(format: "%.0f%%", configuration.scroll.tuning.acceleration * 100)
        deadZoneValue?.stringValue = String(format: "%.2f pt", configuration.scroll.tuning.deadZone)
    }

    private func pageStack() -> NSStackView {
        let stack = SettingsPageStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 34, bottom: 30, right: 34)
        return stack
    }

    /// Builds a titled card section on the proven NSGridView layout used by the settings
    /// previews. Rows whose condition is registered collapse via NSGridRow.isHidden, giving
    /// dependent settings proper progressive disclosure instead of a permanently visible
    /// wall of controls.
    private func section(
        header: String,
        rows: [(view: RowSpec, condition: ((UserConfiguration) -> Bool)?)],
        into deps: inout [ConditionalRow]
    ) -> NSView {
        let grid = NSGridView()
        grid.rowSpacing = 11
        grid.columnSpacing = 14
        grid.xPlacement = .fill
        grid.yPlacement = .center

        let headerLabel = NSTextField(labelWithString: header)
        headerLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        headerLabel.textColor = .secondaryLabelColor
        grid.addRow(with: [headerLabel, NSView()])

        for (spec, condition) in rows {
            let titleLabel = NSTextField(labelWithString: spec.title)
            titleLabel.font = .systemFont(ofSize: 13)
            titleLabel.textColor = .labelColor
            titleLabel.lineBreakMode = .byTruncatingTail
            titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let textStack = NSStackView()
            textStack.orientation = .vertical
            textStack.alignment = .leading
            textStack.spacing = 2
            textStack.addArrangedSubview(titleLabel)
            if let hint = spec.hint {
                let hintField = NSTextField(wrappingLabelWithString: hint)
                hintField.font = .systemFont(ofSize: 11)
                hintField.textColor = .secondaryLabelColor
                hintField.maximumNumberOfLines = 2
                hintField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                hintField.widthAnchor.constraint(lessThanOrEqualToConstant: 244).isActive = true
                textStack.addArrangedSubview(hintField)
                titleLabel.toolTip = hint
                spec.hintLabel?(hintField)
            }

            if let control = spec.control {
                control.toolTip = control.toolTip ?? spec.hint
            }
            let gridRow = grid.addRow(with: [textStack, trailingCell(spec.control)])
            if let condition {
                deps.append(ConditionalRow(condition: condition, setHidden: { hidden in
                    gridRow.isHidden = hidden
                }))
            }
        }
        grid.column(at: 0).width = 260

        let card = SettingsCardView(cornerRadius: 10)
        grid.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: card.topAnchor, constant: 13),
            grid.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            grid.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            grid.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -13),
            card.widthAnchor.constraint(equalToConstant: 680)
        ])
        return card
    }

    /// Wraps a trailing-aligned control so the grid's fill placement never stretches switches,
    /// popups, or fields across the whole control column.
    private func trailingCell(_ control: NSView?) -> NSView {
        let container = NSView()
        guard let control else { return container }
        control.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(control)
        NSLayoutConstraint.activate([
            control.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            container.heightAnchor.constraint(equalTo: control.heightAnchor)
        ])
        return container
    }

    private func formRow(
        title: String,
        hint: String? = nil,
        control: NSView?,
        hintLabel: ((NSTextField) -> Void)? = nil
    ) -> RowSpec {
        RowSpec(title: title, hint: hint, control: control, hintLabel: hintLabel)
    }

    private func boolSwitch(
        tag: Int,
        on: Bool,
        action: Selector = #selector(generalControlChanged(_:))
    ) -> NSSwitch {
        let toggle = NSSwitch()
        toggle.controlSize = .mini
        toggle.state = on ? .on : .off
        toggle.tag = tag
        toggle.target = self
        toggle.action = action
        return toggle
    }

    private func editableField(
        _ value: String,
        field: ConfigurationField,
        width: CGFloat = 390,
        secure: Bool = false
    ) -> NSTextField {
        let textField: NSTextField = secure ? NSSecureTextField(frame: .zero) : NSTextField(frame: .zero)
        textField.stringValue = value
        textField.tag = field.rawValue
        textField.delegate = self
        textField.font = .systemFont(ofSize: 13)
        textField.isEditable = true
        textField.isSelectable = true
        textField.isBezeled = true
        textField.bezelStyle = .roundedBezel
        textField.lineBreakMode = .byTruncatingMiddle
        textField.placeholderString = secure ? "Not configured" : nil
        textField.widthAnchor.constraint(equalToConstant: width).isActive = true
        return textField
    }

    private func note(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.maximumNumberOfLines = 0
        field.widthAnchor.constraint(equalToConstant: 680).isActive = true
        return field
    }

    private func tuningSlider(value: Double, range: ClosedRange<Double>, tag: Int) -> (view: NSView, slider: NSSlider, value: NSTextField) {
        let slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: self, action: #selector(tuningChanged(_:)))
        slider.tag = tag
        slider.isContinuous = true
        slider.widthAnchor.constraint(equalToConstant: 280).isActive = true
        let valueLabel = NSTextField(labelWithString: "")
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        valueLabel.alignment = .right
        valueLabel.widthAnchor.constraint(equalToConstant: 62).isActive = true
        let row = NSStackView(views: [slider, valueLabel])
        row.orientation = .horizontal
        row.spacing = 12
        row.widthAnchor.constraint(equalToConstant: 280 + 12 + 62).isActive = true
        return (row, slider, valueLabel)
    }

    private func scrollable(_ stack: NSStackView) -> NSView {
        // The document view is pinned to at least the viewport height, so a short page must
        // not stretch cards or grid cells to absorb the difference. This trailing filler
        // offers zero vertical resistance and takes all leftover space instead.
        let filler = NSView()
        filler.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        filler.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .vertical)
        stack.addArrangedSubview(filler)

        let document = FlippedSettingsDocumentView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let contentBottom = stack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        contentBottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            document.heightAnchor.constraint(equalTo: stack.heightAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor),
            contentBottom
        ])

        let scrollView = SettingsPageScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        document.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document
        let viewportHeight = document.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor)
        viewportHeight.priority = .defaultLow
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),
            viewportHeight
        ])
        return scrollView
    }

    #if DEBUG
    /// Renders the real settings views without Screen Recording permission. This is used by the
    /// Debug command-line preview path for visual regression checks; it never runs in Release.
    func renderPreviews(to directoryURL: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        guard let window, let contentView = window.contentView else {
            throw CocoaError(.fileWriteUnknown)
        }

        let originalAppearance = window.appearance
        let originalContentSize = contentView.bounds.size
        let originalPage = selectedPage
        let originalConfiguration = configuration
        defer {
            window.appearance = originalAppearance
            window.setContentSize(originalContentSize)
            configuration = originalConfiguration
            cachedPageViews.removeAll()
            conditionalRows.removeAll()
            showPage(originalPage)
        }

        let appearances: [(suffix: String, name: NSAppearance.Name)] = [
            ("light", .aqua),
            ("dark", .darkAqua)
        ]
        var outputURLs: [URL] = []

        func render(page: Page, appearanceSuffix: String, compact: Bool) throws {
            window.setContentSize(compact ? NSSize(width: 760, height: 540) : NSSize(width: 760, height: 650))
            showPage(page)
            contentView.layoutSubtreeIfNeeded()
            try assertUnambiguousSettingsLayout(in: contentView)
            try assertInteractivePageButtons()
            if page == .hotkeys { try assertHotkeyTableIntegrity() }
            contentView.displayIfNeeded()
            guard let representation = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else {
                throw CocoaError(.fileWriteUnknown)
            }
            contentView.cacheDisplay(in: contentView.bounds, to: representation)
            guard let png = representation.representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let compactSuffix = compact ? "-compact" : ""
            let outputURL = directoryURL.appendingPathComponent(
                "settings-\(page.title.lowercased())-\(appearanceSuffix)\(compactSuffix).png"
            )
            try png.write(to: outputURL, options: [.atomic])
            outputURLs.append(outputURL)
        }

        for appearance in appearances {
            guard let resolvedAppearance = NSAppearance(named: appearance.name) else { continue }
            window.appearance = resolvedAppearance
            contentView.wantsLayer = true
            resolvedAppearance.performAsCurrentDrawingAppearance {
                contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
            for page in Page.allCases {
                try render(page: page, appearanceSuffix: appearance.suffix, compact: false)
            }
            for page in [Page.hotkeys, .scrolling] {
                try render(page: page, appearanceSuffix: appearance.suffix, compact: true)
            }
        }

        // Dependency-state variants prove progressive disclosure renders both directions:
        // provider-dependent translation rows, collapsed master switches, and the custom-only
        // tuning card. Light appearance only; the toggles are orthogonal to colors.
        let variants: [(name: String, page: Page, mutate: (inout UserConfiguration) -> Void)] = [
            ("llm-light", .general, { config in
                config.translation.enabled = true
                config.translation.provider = "llm"
            }),
            ("collapsed-light", .general, { config in
                config.windowSwitcher.enabled = false
                config.translation.enabled = false
            }),
            ("custom-light", .scrolling, { config in
                config.scroll.enabled = true
                config.scroll.preset = .custom
            }),
            ("disabled-light", .scrolling, { config in
                config.scroll.enabled = false
            })
        ]
        if let aqua = NSAppearance(named: .aqua) {
            window.appearance = aqua
            contentView.wantsLayer = true
            aqua.performAsCurrentDrawingAppearance {
                contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
            for variant in variants {
                var mutated = originalConfiguration
                variant.mutate(&mutated)
                configuration = mutated
                cachedPageViews.removeAll()
                conditionalRows.removeAll()
                try render(page: variant.page, appearanceSuffix: variant.name, compact: false)
            }
        }
        return outputURLs
    }

    private func assertUnambiguousSettingsLayout(in root: NSView) throws {
        func validate(_ view: NSView, path: String) throws {
            let isOwnedLayoutView = view is SettingsPageScrollView
                || view is FlippedSettingsDocumentView
                || view is SettingsCardView
                || view is SettingsPageStackView
                || view is SettingsCardStackView
            if isOwnedLayoutView, view.hasAmbiguousLayout {
                let horizontal = view.constraintsAffectingLayout(for: .horizontal)
                    .map(\.description)
                    .joined(separator: " | ")
                let vertical = view.constraintsAffectingLayout(for: .vertical)
                    .map(\.description)
                    .joined(separator: " | ")
                throw MutationError.ambiguousLayout("\(path); horizontal: \(horizontal); vertical: \(vertical)")
            }
            for (index, child) in view.subviews.enumerated() {
                try validate(
                    child,
                    path: "\(path)/\(String(describing: type(of: child)))[\(index)]"
                )
            }
        }
        try validate(root, path: String(describing: type(of: root)))
    }

    private func assertInteractivePageButtons() throws {
        for (page, button) in pageButtons {
            let centerInSuperview = NSPoint(x: button.frame.midX, y: button.frame.midY)
            guard button.hitTest(centerInSuperview) === button else {
                throw MutationError.ambiguousLayout("\(page.title) tab does not own its center hit target")
            }
        }
    }

    private func assertHotkeyTableIntegrity() throws {
        guard let table = hotkeyTableView,
              table.selectionHighlightStyle == .none,
              table.selectedRowIndexes.isEmpty else {
            throw MutationError.ambiguousLayout("Hotkeys table must remain non-selecting")
        }
        for (index, binding) in configuration.hotkeys.enumerated() {
            guard let cell = table.view(
                atColumn: 0,
                row: index,
                makeIfNecessary: true
            ) as? HotkeyTableCellView else {
                throw MutationError.ambiguousLayout("Hotkeys row \(index) has no table cell")
            }
            let recorders = cell.descendants(ofType: HotkeyRecorderButton.self)
            let expectedRecorderCount = binding.action.kind == .simulateKeystroke ? 2 : 1
            guard recorders.count == expectedRecorderCount else {
                throw MutationError.ambiguousLayout(
                    "Hotkeys row \(index) action \(binding.action.kind.rawValue) owns \(recorders.count) recorders"
                )
            }
        }
    }
    #endif

    private func hotkeyActionDescription(_ action: HotkeyAction) -> String {
        if action.isSelectedTextTranslation {
            return "Translate selected text"
        }
        return switch action.kind {
        case .focusApplication: "Focus · \(URL(fileURLWithPath: action.path ?? "Application").deletingPathExtension().lastPathComponent)"
        case .showFocusedWindowInfo: "Show focused window info"
        case .translateSelection: "Translate selected text"
        case .captureScreenshot: "Capture annotated screenshot"
        case .toggleScreenRecording: "Start or stop screen recording"
        case .toggleFinder: "Toggle Finder"
        case .toggleTerminal: "Toggle Terminal"
        case .reloadConfiguration: "Reload configuration"
        case .runScript: "Script · \(action.function ?? URL(fileURLWithPath: action.path ?? "Script").lastPathComponent)"
        case .callInterface: "Interface · \(action.interfaceName ?? "Unknown")"
        case .simulateKeystroke:
            "Simulate · \(shortcutTitle(modifiers: action.modifiers ?? [], key: action.key ?? ""))"
        }
    }

    private func shortcutTitle(modifiers: [String], key: String) -> String {
        let symbols = modifiers.map { modifier in
            switch modifier.lowercased() {
            case "ctrl", "control": "⌃"
            case "alt", "option": "⌥"
            case "shift": "⇧"
            case "cmd", "command": "⌘"
            default: modifier
            }
        }.joined()
        let displayed = ["UP": "↑", "DOWN": "↓", "LEFT": "←", "RIGHT": "→"][key.uppercased()]
            ?? key.uppercased()
        return symbols + displayed
    }
}

@MainActor
extension SettingsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        configuration.hotkeys.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard configuration.hotkeys.indices.contains(row) else { return nil }
        return makeHotkeyTableCell(binding: configuration.hotkeys[row], index: row)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        HotkeyTableRowView()
    }
}

@MainActor
private final class HotkeyRecorderButton: NSButton {
    enum CommitResult {
        case accepted
        case rejected(String)
    }

    var onRecordingBegan: (() -> Void)?
    var onRecordingEnded: (() -> Void)?
    var onRecord: (([String], String, Int?) -> CommitResult)?
    var onRecordAsync: (([String], String, Int?, @escaping @MainActor @Sendable (CommitResult) -> Void) -> Void)?
    private var commitPending = false
    private var commitToken = UUID()
    private func commit(modifiers: [String], key: String, mouse: Int?) {
        guard !commitPending else { return }
        let token = UUID(); commitToken = token; commitPending = true
        let finish: @MainActor @Sendable (CommitResult) -> Void = { [weak self] result in
            guard let self, self.recording, self.commitToken == token else { return }
            self.commitPending = false
            switch result {
            case .accepted:
                self.binding.modifiers = modifiers; self.binding.key = key; self.binding.mouseButton = mouse
                _ = self.window?.makeFirstResponder(nil)
            case let .rejected(message): self.title = message; self.toolTip = message; NSSound.beep()
            }
        }
        if let onRecordAsync { title = "Saving…"; onRecordAsync(modifiers, key, mouse, finish) }
        else { finish(onRecord?(modifiers, key, mouse) ?? .rejected("Unable to save this shortcut.")) }
    }
    private var binding: HotkeyBinding
    private let allowsMouseButton: Bool
    private var recording = false
    private var keyboardEventTap: HotkeyRecorderEventTap?
    private var localKeyMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?

    init(binding: HotkeyBinding, allowsMouseButton: Bool) {
        self.binding = binding
        self.allowsMouseButton = allowsMouseButton
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(beginRecording)
        updateTitle()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }

    func startRecording() {
        beginRecording()
    }

    @objc private func beginRecording() {
        guard !recording else { return }
        recording = true
        commitPending = false; commitToken = UUID()
        title = "Press shortcut…"
        toolTip = allowsMouseButton
            ? "Press a modifier plus a key, or a mouse side button with optional modifiers. Escape cancels."
            : "Press at least one modifier plus a key. Escape cancels."
        // Suspend the existing Carbon and mouse registrations before installing any recorder.
        // Otherwise the first candidate key can be dispatched to an old binding while capture
        // setup is still in progress.
        onRecordingBegan?()
        guard window?.makeFirstResponder(self) == true else {
            recording = false
            updateTitle()
            onRecordingEnded?()
            return
        }
        installEventMonitorsIfNeeded()
    }

    override func resignFirstResponder() -> Bool {
        endRecordingIfNeeded()
        return super.resignFirstResponder()
    }

    func cancelRecording() {
        guard recording else { return }
        if window?.firstResponder === self {
            _ = window?.makeFirstResponder(nil)
        }
        endRecordingIfNeeded()
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return super.keyDown(with: event) }
        recordKeyboardEvent(event)
    }

    private func recordKeyboardEvent(_ event: NSEvent) {
        guard recording else { return }
        recordKeyboard(keyCode: event.keyCode, modifiers: recordedModifiers(event.modifierFlags))
    }

    private func recordKeyboard(keyCode: UInt16, modifiers: [String]) {
        guard recording else { return }
        if keyCode == UInt16(kVK_Escape) {
            _ = window?.makeFirstResponder(nil)
            return
        }
        guard !modifiers.isEmpty,
              let key = supportedKey(for: keyCode) else {
            NSSound.beep()
            return
        }
        commit(modifiers: modifiers, key: key, mouse: nil)
    }

    private func updateTitle() {
        title = binding.mouseButton.map {
            shortcutTitle(modifiers: binding.modifiers, key: "") + "Mouse \($0 + 1)"
        }
            ?? shortcutTitle(modifiers: binding.modifiers, key: binding.key)
        toolTip = nil
    }

    private func endRecordingIfNeeded() {
        guard recording else { return }
        recording = false
        removeEventMonitors()
        updateTitle()
        onRecordingEnded?()
    }

    private func installEventMonitorsIfNeeded() {
        if keyboardEventTap == nil {
            let eventTap = HotkeyRecorderEventTap()
            eventTap.onKeyDown = { [weak self] keyCode, flags in
                DispatchQueue.main.async {
                    self?.recordKeyboard(
                        keyCode: keyCode,
                        modifiers: self?.recordedModifiers(flags) ?? []
                    )
                }
            }
            if eventTap.install() {
                keyboardEventTap = eventTap
            }
        }
        if localKeyMonitor == nil {
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.recording else { return event }
                self.recordKeyboardEvent(event)
                return nil
            }
        }
        guard allowsMouseButton, localMouseMonitor == nil, globalMouseMonitor == nil else { return }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            guard let self, self.recording else { return event }
            self.recordMouseButton(
                Int(event.buttonNumber),
                modifiers: self.recordedModifiers(event.modifierFlags)
            )
            return nil
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                self.recordMouseButton(
                    Int(event.buttonNumber),
                    modifiers: self.recordedModifiers(event.modifierFlags)
                )
            }
        }
    }

    private func removeEventMonitors() {
        keyboardEventTap?.invalidate()
        keyboardEventTap = nil
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        localKeyMonitor = nil
        localMouseMonitor = nil
        globalMouseMonitor = nil
    }

    private func recordMouseButton(_ button: Int, modifiers: [String]) {
        guard recording, allowsMouseButton, (2 ... 31).contains(button) else { return }
        commit(modifiers: modifiers, key: "", mouse: button)
    }

    private func recordedModifiers(_ flags: NSEvent.ModifierFlags) -> [String] {
        var result: [String] = []
        if flags.contains(.control) { result.append("ctrl") }
        if flags.contains(.option) { result.append("alt") }
        if flags.contains(.shift) { result.append("shift") }
        if flags.contains(.command) { result.append("cmd") }
        return result
    }

    private func recordedModifiers(_ flags: CGEventFlags) -> [String] {
        var result: [String] = []
        if flags.contains(.maskControl) { result.append("ctrl") }
        if flags.contains(.maskAlternate) { result.append("alt") }
        if flags.contains(.maskShift) { result.append("shift") }
        if flags.contains(.maskCommand) { result.append("cmd") }
        return result
    }

    private func supportedKey(for keyCode: UInt16) -> String? {
        let key = HotkeyKey(code: keyCode)
        return key.isModifierKey ? nil : key.configurationName
    }

    private func shortcutTitle(modifiers: [String], key: String) -> String {
        let symbols = modifiers.map { modifier in
            switch modifier.lowercased() {
            case "ctrl", "control": "⌃"
            case "alt", "option": "⌥"
            case "shift": "⇧"
            case "cmd", "command": "⌘"
            default: modifier
            }
        }.joined()
        let displayedKey = switch key.uppercased() {
        case "UP": "↑"
        case "DOWN": "↓"
        case "LEFT": "←"
        case "RIGHT": "→"
        case "SPACE": "Space"
        case "RETURN": "↩"
        case "TAB": "⇥"
        default: key.uppercased()
        }
        return symbols + displayedKey
    }
}

@MainActor
private final class SettingsPageButton: NSButton {
    private let pageIcon = NSImageView()
    private let pageTitle = NSTextField(labelWithString: "")
    private var pointerInside = false
    private var pointerTrackingArea: NSTrackingArea?

    var isPageSelected = false {
        didSet { needsDisplay = true }
    }

    init(title: String, symbol: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        self.title = ""
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 8

        pageIcon.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: title
        )?.withSymbolConfiguration(.init(pointSize: 20, weight: .medium))
        pageIcon.imageScaling = .scaleProportionallyDown
        pageIcon.translatesAutoresizingMaskIntoConstraints = false
        pageIcon.widthAnchor.constraint(equalToConstant: 26).isActive = true
        pageIcon.heightAnchor.constraint(equalToConstant: 23).isActive = true

        pageTitle.stringValue = title
        pageTitle.alignment = .center
        pageTitle.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: [pageIcon, pageTitle])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 3
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            content.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 6),
            content.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        let accent = NSColor.controlAccentColor
        let backgroundColor: NSColor = if isPageSelected {
            accent.withAlphaComponent(0.12)
        } else if pointerInside {
            NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.34)
        } else {
            .clear
        }
        layer?.backgroundColor = backgroundColor.cgColor
        layer?.borderWidth = 0
        let color = isPageSelected ? accent : NSColor.secondaryLabelColor
        pageIcon.contentTintColor = color
        pageTitle.font = .systemFont(ofSize: 12, weight: isPageSelected ? .semibold : .medium)
        pageTitle.textColor = color
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, isEnabled, super.hitTest(point) != nil else { return nil }
        return self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        pointerTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
private final class SettingsPageScrollView: NSScrollView {}

@MainActor
private final class SettingsPageStackView: NSStackView {}

@MainActor
private final class FlippedSettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private class SettingsCardView: NSView {
    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.borderWidth = 0.5
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
private final class SettingsCardStackView: NSStackView {
    var cornerRadius: CGFloat = 8 {
        didSet { layer?.cornerRadius = cornerRadius }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.borderWidth = 0.5
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
private final class HotkeyTableCellView: NSTableCellView {
    weak var recorder: HotkeyRecorderButton?
}

@MainActor
private final class HotkeyTableRowView: NSTableRowView {
    private let separator = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(separator)
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = NSColor.clear.cgColor
        separator.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
    }

    override func layout() {
        super.layout()
        separator.frame = CGRect(x: 12, y: 0, width: max(0, bounds.width - 24), height: 0.5)
    }

    override func drawSelection(in dirtyRect: NSRect) {}
}

@MainActor
private final class SettingsIconWell: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 0.5
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = NSColor.unemphasizedSelectedContentBackgroundColor
            .withAlphaComponent(0.28).cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private extension NSView {
    func descendants<T: NSView>(ofType type: T.Type) -> [T] {
        subviews.flatMap { child -> [T] in
            let current = (child as? T).map { [$0] } ?? []
            return current + child.descendants(ofType: type)
        }
    }
}

@MainActor private final class FanMonitoringCards: NSView {
    private final class Document: NSView { override var isFlipped: Bool { true } }
    private let scroll = NSScrollView()
    private let document = Document()
    private var orderedCards: [NSView] = []
    private var columns: Int { max(1, Int(max(bounds.width, 220) / 220)) }
    private var rows: Int { (orderedCards.count + columns - 1) / columns }
    private func height(_ rows: Int) -> CGFloat { rows == 0 ? 0 : CGFloat(rows) * 68 + CGFloat(rows - 1) * 8 }
    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.documentView = document
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay; scroll.drawsBackground = false
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height(min(2, rows)))
    }
    override func layout() {
        super.layout()
        let origin = scroll.contentView.bounds.origin
        scroll.frame = bounds
        let width = max(0, (bounds.width - CGFloat(columns - 1) * 8) / CGFloat(columns))
        document.setFrameSize(NSSize(width: bounds.width, height: height(rows)))
        for (index, card) in orderedCards.enumerated() {
            card.frame = NSRect(x: CGFloat(index % columns) * (width + 8), y: CGFloat(index / columns) * 76, width: width, height: 68)
        }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(origin.y, max(0, document.bounds.height - bounds.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    override func setFrameSize(_ newSize: NSSize) {
        let oldColumns = columns
        super.setFrameSize(newSize)
        if oldColumns != columns { invalidateIntrinsicContentSize() }
    }
    func setCards(_ views: [NSView]) {
        guard orderedCards != views else { return }
        for view in orderedCards where !views.contains(view) { view.removeFromSuperview() }
        for view in views where view.superview !== document { document.addSubview(view) }
        orderedCards = views; invalidateIntrinsicContentSize(); needsLayout = true
    }
}

@MainActor private var fanCreationActionKey: UInt8 = 0
@MainActor private final class FanRuleCreationAction: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke() { action() }
}

private final class FanCurveEditor: NSView {
    private var rule: FanRule
    var onChange: ((FanRule) -> Void)?
    var onDelete: (() -> Void)?
    private var snapshot: FanSnapshot?
    private let enabled = NSSwitch()
    @objc private func enableChanged() { rule.enabled = enabled.state == .on; onChange?(rule) }
    @objc private func deleteRule() { onDelete?() }
    private var choiceSignature: [String] = []
    func update(snapshot: FanSnapshot?) {
        let previousTemperature = self.snapshot?.ruleReadings[rule.sensor]
        let previousFan = self.snapshot?.fans.first { $0.id == rule.fan }
        self.snapshot = snapshot
        let keys = Array(Set(snapshot?.descriptors.keys.map { $0 } ?? []).union(snapshot?.ruleReadings.keys.map { $0 } ?? []).union(FanReadPlan.aggregates)).sorted()
        let signature = keys.map { key in
            "\(key)|\(snapshot?.descriptors[key]?.displayName ?? "")|\(snapshot?.ruleReadings[key] == nil)"
        } + (snapshot?.fans.map { "\($0.id)|\($0.name ?? "")" } ?? [])
        if choiceSignature != signature {
            choiceSignature = signature
            sensor.removeAllItems()
            for key in keys.sorted(by: { (snapshot?.descriptors[$0]?.area ?? "Aggregate", $0) < (snapshot?.descriptors[$1]?.area ?? "Aggregate", $1) }) {
                let descriptor = snapshot?.descriptors[key]
                sensor.addItem(withTitle: (descriptor.map { "\($0.area) · \($0.displayName) · \($0.id)" } ?? FanSensorMetadata.name(key)) + (snapshot?.ruleReadings[key] == nil ? " (unavailable)" : ""))
                sensor.lastItem?.representedObject = key
                let provenance = ["CPU", "Highest CPU"].contains(key) ? "Highest valid CPU; winner: \(snapshot?.highestCPU?.key ?? "unavailable")" : (key.hasPrefix("HID:") ? "IOHID Product + LocationID" : "AppleSMC firmware key / aggregate")
                sensor.lastItem?.toolTip = "ID: \(key) · \(provenance)"
            }
            if !keys.contains(rule.sensor) { sensor.addItem(withTitle: rule.sensor + " (unavailable)"); sensor.lastItem?.representedObject = rule.sensor }
            for item in sensor.itemArray where item.representedObject == nil { item.representedObject = item.title }
            sensor.select(sensor.itemArray.first { ($0.representedObject as? String) == rule.sensor })
            fan.removeAllItems()
            for reading in snapshot?.fans ?? [] {
                fan.addItem(withTitle: reading.name.map { "\($0) (\(reading.id))" } ?? "Fan \(reading.id)")
                fan.lastItem?.representedObject = reading.id
            }
            if !fan.itemArray.contains(where: { ($0.representedObject as? Int) == rule.fan }) { fan.addItem(withTitle: "Fan \(rule.fan) (unavailable)"); fan.lastItem?.representedObject = rule.fan }
            fan.select(fan.itemArray.first { ($0.representedObject as? Int) == rule.fan })
            fan.isEnabled = false
            fan.toolTip = "Fan assignment is fixed. Delete this rule to assign another fan."
        }
        let requested = snapshot?.ruleReadings[rule.sensor].flatMap { rule.demand(at: $0) }
        let effective = snapshot?.acceptedDemands[rule.fan]
        let status: String
        if !rule.enabled { status = "Disabled · 规则已禁用" }
        else if requested == nil { status = "Awaiting sensor · 等待读数" }
        else if snapshot?.controlEnabled != true { status = snapshot?.controlStatus ?? "Awaiting helper" }
        else if let effective, let requested { status = effective > requested ? "Shadowed · 更高规则优先" : "Active · 已接受批次" }
        else { status = snapshot?.controlStatus ?? "Awaiting batch" }
        let captionText = "\(status) · 请求 \(requested.map { String(format: "%.0f%%", $0) } ?? "—") · 有效 \(effective.map { String(format: "%.0f%%", $0) } ?? "—")"
        if caption.stringValue != captionText { caption.stringValue = captionText }
        caption.toolTip = "Effective demand is the maximum across enabled rules for this fan. Accepted batch does not prove exclusive firmware ownership."
        let currentFan = snapshot?.fans.first { $0.id == rule.fan }
        if previousTemperature != snapshot?.ruleReadings[rule.sensor] || previousFan?.minimum != currentFan?.minimum || previousFan?.maximum != currentFan?.maximum { needsDisplay = true }
    }
    private var selected: Int?
    private var selectedHandle: (Int, Bool)?
    private let sensor = NSPopUpButton()
    private let fan = NSPopUpButton()
    private let caption = NSTextField(labelWithString: "")
    private let easing = NSPopUpButton()
    init(rule: FanRule) {
        self.rule = rule
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(greaterThanOrEqualToConstant: 680).isActive = true
        heightAnchor.constraint(equalToConstant: 280).isActive = true
        update(snapshot: nil)
        for popup in [sensor, fan] { popup.target = self; popup.action = #selector(selectionChanged); addSubview(popup) }
        enabled.state = rule.enabled ? .on : .off; enabled.target = self; enabled.action = #selector(enableChanged)
        enabled.frame = NSRect(x: 450, y: 218, width: 42, height: 26); addSubview(enabled)
        let delete = NSButton(title: "Delete", target: self, action: #selector(deleteRule))
        delete.frame = NSRect(x: 585, y: 218, width: 80, height: 26); addSubview(delete)
        addSubview(caption)
        easing.addItems(withTitles: ["Linear", "Ease in", "Ease out", "Smooth"])
        easing.target = self; easing.action = #selector(easingChanged)
        addSubview(easing)
        easing.frame = NSRect(x: 320, y: 218, width: 120, height: 26)
        sensor.frame = NSRect(x: 45, y: 218, width: 140, height: 26)
        fan.frame = NSRect(x: 195, y: 218, width: 110, height: 26)
        caption.frame = NSRect(x: 45, y: 201, width: 400, height: 15)
        caption.font = .systemFont(ofSize: 11)
        caption.stringValue = "20–110 °C · 0–100% · cubic Bezier"
    }
    override func layout() {
        super.layout()
        for control in [sensor, fan, easing] { var frame = control.frame; frame.origin.y = bounds.height - 32; control.frame = frame }
        enabled.setFrameOrigin(NSPoint(x: 450, y: bounds.height - 32))
        for button in subviews.compactMap({ $0 as? NSButton }) where button.title == "Delete" { button.setFrameOrigin(NSPoint(x: bounds.width - 95, y: bounds.height - 32)) }
        caption.frame = NSRect(x: 48, y: bounds.height - 65, width: bounds.width - 65, height: 28)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func selectionChanged() {
        rule.sensor = sensor.selectedItem?.representedObject as? String ?? rule.sensor

        needsDisplay = true
        onChange?(rule)
    }
    @objc private func easingChanged() {
        let pair: (Double, Double)
        switch easing.indexOfSelectedItem {
        case 1: pair = (0, 0.33)
        case 2: pair = (0.67, 1)
        case 3: pair = (0, 1)
        default: pair = (1.0 / 3, 2.0 / 3)
        }
        for index in rule.points.indices {
            rule.points[index].outgoing = pair.0
            rule.points[index].incoming = pair.1
        }
        onChange?(rule); needsDisplay = true
    }
    private func location(_ point: FanCurvePoint) -> NSPoint {
        geometry.location(temperature: point.temperature, percent: point.percent)
    }
    private var geometry: FanPlotGeometry { FanPlotGeometry(bounds: bounds) }
    override func draw(_ dirtyRect: NSRect) {
        let plotRect = geometry.rect
        NSColor.controlBackgroundColor.setFill(); bounds.fill()
        NSColor.separatorColor.setStroke()
        let grid = NSBezierPath()
        for percent in stride(from: 0.0, through: 100, by: 25) {
            let y = geometry.location(temperature: 20, percent: percent).y
            grid.move(to: NSPoint(x: plotRect.minX, y: y)); grid.line(to: NSPoint(x: plotRect.maxX, y: y))
            ("\(Int(percent))%" as NSString).draw(at: NSPoint(x: 4, y: y - 5), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor])
        }
        for temperature in stride(from: 20.0, through: 110, by: 15) {
            let x = geometry.location(temperature: temperature, percent: 0).x
            grid.move(to: NSPoint(x: x, y: plotRect.minY)); grid.line(to: NSPoint(x: x, y: plotRect.maxY))
            ("\(Int(temperature)) °C" as NSString).draw(at: NSPoint(x: x - 14, y: 8), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor])
        }
        if let reading = snapshot?.fans.first(where: { $0.id == rule.fan }) {
            for percent in stride(from: 0.0, through: 100, by: 25) {
                let y = geometry.location(temperature: 20, percent: percent).y
                ("\(Int(reading.rpm(percent: percent))) RPM" as NSString).draw(at: NSPoint(x: plotRect.maxX + 7, y: y - 5), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor])
            }
        }
        grid.stroke()
        if let temperature = snapshot?.ruleReadings[rule.sensor], temperature.isFinite {
            let x = location(.init(temperature: temperature.clamped(to: 20...110), percent: 0)).x
            let marker = NSBezierPath(); marker.move(to: NSPoint(x: x, y: plotRect.minY)); marker.line(to: NSPoint(x: x, y: plotRect.maxY))
            marker.setLineDash([5, 4], count: 2, phase: 0); NSColor.systemOrange.setStroke(); marker.stroke()
            (String(format: "%.1f °C", temperature) as NSString).draw(at: NSPoint(x: min(x + 4, plotRect.maxX - 55), y: plotRect.maxY - 17), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.systemOrange])
        }
        let path = NSBezierPath(); path.lineWidth = 2
        for temperature in stride(from: 20.0, through: 110, by: 0.5) {
            guard let demand = rule.demand(at: temperature) else { continue }
            let p = location(.init(temperature: temperature, percent: demand))
            if path.isEmpty { path.move(to: p) } else { path.line(to: p) }
        }
        NSColor.controlAccentColor.setStroke(); path.stroke()
        NSColor.secondaryLabelColor.setStroke()
        for index in 0..<max(0, rule.points.count - 1) {
            let a = rule.points[index], b = rule.points[index + 1]
            for outgoing in [true, false] {
                let handle = handleLocation(index, outgoing)
                let line = NSBezierPath(); line.move(to: location(outgoing ? a : b)); line.line(to: handle); line.stroke()
                NSColor.secondaryLabelColor.setFill()
                NSBezierPath(rect: NSRect(x: handle.x - 3, y: handle.y - 3, width: 6, height: 6)).fill()
            }
        }
        NSColor.controlAccentColor.setFill()
        for point in rule.points { let p = location(point); NSBezierPath(ovalIn: NSRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)).fill() }

    }
    private func handleLocation(_ index: Int, _ outgoing: Bool) -> NSPoint {
        let a = rule.points[index], b = rule.points[index + 1]
        let fraction = outgoing ? 1.0 / 3 : 2.0 / 3
        let ordinate = outgoing ? a.outgoing : b.incoming
        return location(.init(temperature: a.temperature + (b.temperature - a.temperature) * fraction,
                              percent: a.percent + (b.percent - a.percent) * ordinate))
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard geometry.rect.insetBy(dx: -8, dy: -8).contains(p) else { return }
        for index in 0..<max(0, rule.points.count - 1) {
            for outgoing in [true, false] {
                let h = handleLocation(index, outgoing)
                if hypot(h.x - p.x, h.y - p.y) < 7 { selectedHandle = (index, outgoing); return }
            }
        }
        selected = rule.points.indices.min(by: { hypot(location(rule.points[$0]).x - p.x, location(rule.points[$0]).y - p.y) < hypot(location(rule.points[$1]).x - p.x, location(rule.points[$1]).y - p.y) })
        if event.modifierFlags.contains(.option), let selected, rule.points.count > 2 {
            rule.points.remove(at: selected); self.selected = nil; onChange?(rule); needsDisplay = true
        } else if event.clickCount == 2, rule.points.count < 20 {
            let temperature = geometry.reading(at: p).temperature.clamped(to: 20...110)
            guard !rule.points.contains(where: { abs($0.temperature - temperature) < 1 }) else { return }
            rule.points.append(.init(temperature: temperature, percent: rule.demand(at: temperature) ?? 50))
            rule.points.sort { $0.temperature < $1.temperature }; onChange?(rule); needsDisplay = true
        }
    }
    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let (index, outgoing) = selectedHandle {
            let a = rule.points[index], b = rule.points[index + 1]
            guard b.percent > a.percent else { return }
            let percent = geometry.reading(at: p).percent
            let ordinate = ((percent - a.percent) / (b.percent - a.percent)).clamped(to: 0...1)
            if outgoing { rule.points[index].outgoing = ordinate } else { rule.points[index + 1].incoming = ordinate }
            onChange?(rule); needsDisplay = true; return
        }
        guard let selected else { return }
        let lower = selected > 0 ? rule.points[selected - 1].temperature + 1 : 20
        let upper = selected + 1 < rule.points.count ? rule.points[selected + 1].temperature - 1 : 110
        guard lower <= upper else { return }
        rule.points[selected].temperature = geometry.reading(at: p).temperature.clamped(to: lower...upper)
        let minimum = selected > 0 ? rule.points[selected - 1].percent : 0
        let maximum = selected + 1 < rule.points.count ? rule.points[selected + 1].percent : 100
        rule.points[selected].percent = (geometry.reading(at: p).percent).clamped(to: minimum...maximum)
        onChange?(rule)
        caption.stringValue = String(format: "%.1f °C · %.0f%%", rule.points[selected].temperature, rule.points[selected].percent)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) { if selected != nil || selectedHandle != nil { onChange?(rule) }; selected = nil; selectedHandle = nil }
}

/// Serial I/O owner; UI gets immutable snapshots. No privileged writes occur without a verified XPC peer.
@MainActor
final class FanRuntime: NSObject {
    let monitoringView = NSView()
    var onEnabledChange: ((Bool) -> Void)?
    private let refreshIntervalPicker = NSPopUpButton()
    private var monitoringInterval: TimeInterval {
        let value = UserDefaults.standard.double(forKey: "fanMonitoringRefreshInterval")
        return [1.0, 2.0, 5.0, 10.0].contains(value) ? value : 2
    }
    private let controlIntervalPicker = NSPopUpButton()
    private var controlInterval: TimeInterval {
        let value = UserDefaults.standard.double(forKey: "fanControlSamplingInterval")
        return [1.0, 2.0].contains(value) ? value : 1
    }
    @objc private func changeControlInterval() {
        UserDefaults.standard.set(Double(controlIntervalPicker.selectedTag()), forKey: "fanControlSamplingInterval")
        poll()
    }
    private var lastMonitoringUpdate: TimeInterval?
    @objc private func changeRefreshInterval() {
        UserDefaults.standard.set(Double(refreshIntervalPicker.selectedTag()), forKey: "fanMonitoringRefreshInterval")
        lastMonitoringUpdate = nil
        poll()
    }
    private var settings = FanSettings()
    private var suspended = false
    private var powerObservers: [NSObjectProtocol] = []
    private var controlSampleVersion = FanControlSampleVersion()
    func apply(_ settings: FanSettings) {
        let changed = controlSampleVersion.update(settings)
        self.settings = settings; applying = settings.enabled; toggle.state = settings.enabled ? .on : .off
        if changed {
            latestSnapshot = nil; sampleDate = nil
            restore(); publishUnavailable()
        } else if applying { rulesChanged() }
        poll()
    }
    func start() {
        guard powerObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        powerObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.prepareForSystemSleep() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resumeAfterSystemSleep() }
            }
        ]
        verifyHelper()
        startSamplingTimer()
        poll()
    }
    private var powerGeneration = UUID()
    private func prepareForSystemSleep() {
        suspended = true
        powerGeneration = UUID()
        timer?.invalidate(); timer = nil
        latestSnapshot = nil; sampleDate = nil; latestSamplePlan = nil
        lastPollUptime = nil
        restore()
    }
    private func resumeAfterSystemSleep() {
        guard !powerObservers.isEmpty else { return }
        suspended = false
        queue.async { [weak self] in self?.reader.invalidateDiscovery() }
        startSamplingTimer()
        poll()
    }
    private func startSamplingTimer() {
        guard timer == nil, !suspended else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollIfDue() }
        }
        timer?.tolerance = 0.15
    }
    func shutdown(completion: @escaping @Sendable () -> Void = {}) {
        if let proxy = connection?.remoteObjectProxyWithErrorHandler({ _ in completion() }) as? FanHelperProtocol {
            proxy.restore { _ in completion() }
        } else { completion() }
        powerObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; powerObservers = []
        timer?.invalidate(); timer = nil; applying = false
        let oldConnection = connection
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { oldConnection?.invalidate() }
    }
    private let queue = DispatchQueue(label: "fan.monitor")
    private var timer: Timer?
    private var closeObserver: NSObjectProtocol?
    private let fanCards = FanMonitoringCards()
    private var monitoringVisible = false
    private var areaCards: [String: FanMonitoringCards] = [:]
    private var areaButtons: [String: NSButton] = [:]
    private var expandedAreas: Set<String> = []
    private let sensorSections = NSStackView()
    func setMonitoringVisible(_ visible: Bool) {
        guard monitoringVisible != visible else { return }
        monitoringVisible = visible
        if visible { lastMonitoringUpdate = nil; poll() }
    }
    @objc private func toggleArea(_ sender: NSButton) {
        let area = sender.identifier!.rawValue
        if sender.state == .on { expandedAreas.insert(area) } else { expandedAreas.remove(area) }
        areaCards[area]?.isHidden = sender.state != .on
        lastMonitoringUpdate = nil
        filterSensors(); poll()
    }
    private let showOther = NSButton(checkboxWithTitle: "Show Other sensors", target: nil, action: nil)
    private let sensorSearch = NSSearchField()
    @objc private func filterSensors() { if monitoringVisible, let snapshot = latestSnapshot { updateReadingCards(snapshot) }; poll() }

    private var readingCards: [String: NSTextField] = [:]
    private let readings = NSTextField(wrappingLabelWithString: "Reading AppleSMC…")
    private let state = NSTextField(wrappingLabelWithString: "Helper unavailable. macOS automatic control.")
    private let toggle = NSButton(checkboxWithTitle: "Enable Rules", target: nil, action: nil)
    private let serviceStatus = NSTextField(wrappingLabelWithString: "Installed: checking · Running: checking · Authenticated: no")
    private var helperUpdateRequired = false
    private let helperVersions = NSTextField(wrappingLabelWithString: "Bundled protocol v2 · Checking helper fingerprints…")
    private var updateButton: NSButton?
    private var managementBusy = false
    private var managementResult: String?
    private var managementButtons: [NSButton] = []
    private var connection: NSXPCConnection?
    private var verified = false
    private var connectionGeneration = UUID()
    private var applying = false
    var onSnapshot: ((FanSnapshot?) -> Void)?
    func refreshEditors() { if monitoringVisible { onSnapshot?(latestSnapshot) }; rulesChanged() }
    private var acceptedDemands: [Int: Double] = [:]
    private var batchStatus = "Awaiting authenticated batch"
    var detectedFanIDs: [Int] { latestSnapshot?.fans.map(\.id) ?? [] }
    private var latestSamplePlan: FanReadPlan?
    private var latestSnapshot: FanSnapshot?
    private var sampleDate: Date?
    func rulesChanged() {
        guard applying, verified, !suspended else { return }
        guard settings.duplicateFanIDs.isEmpty else {
            restore(); state.stringValue = "Duplicate fan assignments: \(settings.duplicateFanIDs). Delete duplicate rules (including disabled rules) to resume control."; return
        }
        guard let snapshot = latestSnapshot, let sampleDate,
              let demands = settings.activeDemands(readings: snapshot.ruleReadings, now: Date(), sampleDate: sampleDate),
              demands.keys.allSatisfy({ id in snapshot.fans.contains { $0.id == id } }) else { restore(); return }
        sendDemands(demands)
    }
    private let reader = FanSMCReader()
    override init() {
        super.init()
        monitoringView.translatesAutoresizingMaskIntoConstraints = false
        monitoringView.widthAnchor.constraint(equalToConstant: 680).isActive = true
        fanCards.translatesAutoresizingMaskIntoConstraints = false
        sensorSections.orientation = .vertical; sensorSections.alignment = .leading
        sensorSections.translatesAutoresizingMaskIntoConstraints = false
        readings.isSelectable = true
        let permissions = NSTextField(wrappingLabelWithString: "App updates include a new bundled helper. Update, reinstall, or uninstall below; only these buttons request administrator authorization. Accessibility permission does not grant fan access.")
        permissions.font = .systemFont(ofSize: 11)
        let setup = NSButton(title: "Install helper…", target: self, action: #selector(installHelper))
        let reinstall = NSButton(title: "Reinstall…", target: self, action: #selector(reinstallHelper))
        updateButton = reinstall
        let uninstall = NSButton(title: "Uninstall…", target: self, action: #selector(uninstallHelper))
        managementButtons = [setup, reinstall, uninstall]
        let retry = NSButton(title: "Check helper again", target: self, action: #selector(retryHelper))
        let actions = NSStackView(views: [setup, reinstall, uninstall, retry])
        actions.orientation = .horizontal
        showOther.target = self; showOther.action = #selector(filterSensors)
        sensorSearch.placeholderString = "Search sensors, raw IDs, or sources"
        sensorSearch.target = self; sensorSearch.action = #selector(filterSensors)
        sensorSearch.sendsSearchStringImmediately = true
        sensorSearch.widthAnchor.constraint(equalToConstant: 400).isActive = true
        for seconds in [1, 2, 5, 10] {
            refreshIntervalPicker.addItem(withTitle: "Every \(seconds) s")
            refreshIntervalPicker.lastItem?.tag = seconds
        }
        refreshIntervalPicker.selectItem(withTag: Int(monitoringInterval))
        refreshIntervalPicker.target = self
        refreshIntervalPicker.action = #selector(changeRefreshInterval)
        refreshIntervalPicker.setAccessibilityLabel("Monitoring refresh interval")
        let refreshRow = NSStackView(views: [NSTextField(labelWithString: "Monitoring refresh"), refreshIntervalPicker])
        for seconds in [1, 2] {
            controlIntervalPicker.addItem(withTitle: "Every \(seconds) s")
            controlIntervalPicker.lastItem?.tag = seconds
        }
        controlIntervalPicker.selectItem(withTag: Int(controlInterval))
        controlIntervalPicker.target = self
        controlIntervalPicker.action = #selector(changeControlInterval)
        controlIntervalPicker.setAccessibilityLabel("Background control sampling interval")
        controlIntervalPicker.toolTip = "Used while enabled rules run. Visible monitoring may require faster sampling."
        let controlRow = NSStackView(views: [NSTextField(labelWithString: "Background control sampling"), controlIntervalPicker])
        let filters = NSStackView(views: [showOther, sensorSearch])
        let stack = NSStackView(views: [refreshRow, controlRow, readings, fanCards, filters, sensorSections, serviceStatus, helperVersions, state, permissions, actions, toggle])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; monitoringView.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: monitoringView.leadingAnchor), stack.trailingAnchor.constraint(equalTo: monitoringView.trailingAnchor), stack.topAnchor.constraint(equalTo: monitoringView.topAnchor), stack.bottomAnchor.constraint(equalTo: monitoringView.bottomAnchor)])
        fanCards.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        sensorSections.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        toggle.target = self; toggle.action = #selector(change); toggle.isEnabled = true
    }
    @objc private func change() {
        onEnabledChange?(toggle.state == .on)
    }
    private func restore() {
        acceptedDemands = [:]; batchStatus = "Automatic restoration requested"
        (connection?.remoteObjectProxy as? FanHelperProtocol)?.restore { _ in }
    }
    private func stop() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver); self.closeObserver = nil }
        applying = false; toggle.state = .off; timer?.invalidate(); timer = nil
        restore(); connectionGeneration = UUID(); connection?.invalidate(); connection = nil; verified = false; toggle.isEnabled = false
    }
    @objc private func installHelper() { manage("install") }
    @objc private func reinstallHelper() { manage("reinstall") }
    @objc private func uninstallHelper() { manage("uninstall") }
    private func manage(_ operation: String) {
        guard !managementBusy else { return }
        managementBusy = true
        applying = false; toggle.isEnabled = false
        restore(); connectionGeneration = UUID(); connection?.invalidate(); connection = nil; verified = false
        managementButtons.forEach { $0.isEnabled = false }
        state.stringValue = "Waiting for administrator authorization to \(operation) helper…"
        queue.async { [weak self] in
            let result = FanHelperInstallation.manage(operation)
            DispatchQueue.main.async {
                guard let self else { return }
                self.managementBusy = false
                self.managementButtons.forEach { $0.isEnabled = true }
                self.managementResult = result
                self.verifyHelper()
            }
        }
    }
    @objc private func retryHelper() {
        guard !managementBusy else { return }
        restore(); connectionGeneration = UUID(); connection?.invalidate(); connection = nil; verified = false
        verifyHelper()
    }
    private func verifyHelper() {
        state.stringValue = "Checking helper installation and signature…"
        let generation = UUID(); connectionGeneration = generation
        queue.async { [weak self] in
            let status = FanHelperInstallation.check()
            let running = FanHelperInstallation.runningStatus()
            let installedHash = FanHelperInstallation.fingerprint(FanHelperInstallation.installedPath)
            let bundledHash = FanHelperInstallation.fingerprint(FanHelperInstallation.bundledPath)
            let update = FanHelperUpdatePolicy.needsUpdate(installedHash: installedHash, bundledHash: bundledHash)
            DispatchQueue.main.async {
                guard let self, self.connectionGeneration == generation else { return }
                self.helperUpdateRequired = update
                self.updateButton?.title = update ? "Update helper…" : "Reinstall…"
                self.helperVersions.stringValue = "Installed: \(installedHash.map { String($0.prefix(12)) } ?? "missing / unverified") · Bundled v2: \(bundledHash.map { String($0.prefix(12)) } ?? "unverified") (CDHash)"
                self.serviceStatus.stringValue = "Installed: \(status == nil ? "verified" : "unavailable or unsafe") · \(running) · Authenticated: no"
                self.toggle.isEnabled = true
                guard status == nil else { self.state.stringValue = [self.managementResult, status].compactMap { $0 }.joined(separator: "\n"); return }
                self.connectHelper()
            }
        }
    }
    private var handshakeGeneration: UUID?
    private func connectHelper() {
        state.stringValue = "Helper installed and signed. Connecting and authenticating…"
        let xpc = NSXPCConnection(machServiceName: FanHelperIdentity.service, options: .privileged)
        xpc.setCodeSigningRequirement(FanHelperIdentity.helperRequirement)
        xpc.remoteObjectInterface = NSXPCInterface(with: FanHelperProtocol.self)
        let generation = UUID(); connectionGeneration = generation
        let lost: @Sendable () -> Void = { [weak self] in DispatchQueue.main.async {
            guard let self, self.connectionGeneration == generation else { return }
            self.verified = false; self.connection?.invalidate(); self.connection = nil; self.toggle.isEnabled = !self.managementBusy
            self.serviceStatus.stringValue = "Installed: verified · Running: check again · Authenticated: no"
            self.state.stringValue = "Helper connection/authentication failed. Check service logs, matching app signature, and supported hardware; then Check helper again."
        } }
        xpc.invalidationHandler = lost; xpc.interruptionHandler = lost
        connection = xpc; xpc.resume()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak xpc] in
            guard let self, self.connectionGeneration == generation, self.handshakeGeneration != generation else { return }
            xpc?.invalidate(); lost()
        }
        let proxy = xpc.remoteObjectProxyWithErrorHandler { @Sendable _ in lost() } as? FanHelperProtocol
        proxy?.status { @Sendable [weak self] response in DispatchQueue.main.async {
            guard let self, self.connectionGeneration == generation else { return }
            self.handshakeGeneration = generation
            self.helperUpdateRequired = self.helperUpdateRequired || FanHelperUpdatePolicy.needsUpdate(installedHash: "matched", bundledHash: "matched", runningStatus: response)
            self.updateButton?.title = self.helperUpdateRequired ? "Update helper…" : "Reinstall…"
            self.verified = response == FanHelperUpdatePolicy.protocolStatus && !self.helperUpdateRequired
            self.toggle.isEnabled = true
            self.applying = self.settings.enabled
            self.toggle.state = self.settings.enabled ? .on : .off
            self.rulesChanged()
            self.state.stringValue = [self.managementResult, self.helperUpdateRequired ? "Helper update required. Click Update helper to authorize replacement; automatic fan control remains active. Running protocol: \(response)." : (self.verified ? "Signed helper verified. Enabled rules run automatically while TSMacTools is running." : "Authenticated helper: \(response)")].compactMap { $0 }.joined(separator: "\n")
            self.serviceStatus.stringValue += self.verified ? " → yes (ready-v2 handshake)" : " → yes (control unavailable)"
        } }
    }
    private func publishControl() {
        guard var snapshot = latestSnapshot else { return }
        snapshot.controlEnabled = applying && verified && !suspended
        snapshot.acceptedDemands = acceptedDemands
        snapshot.controlStatus = batchStatus
        latestSnapshot = snapshot
        // Control acknowledgements update state independently; live editors refresh
        // with the next monitoring tick at the user's selected interval.
    }
    private func sendDemands(_ demands: [Int: Double]) {
        let sampleVersion = controlSampleVersion.generation
        let generation = connectionGeneration
        batchStatus = "Awaiting authenticated batch acceptance"
        publishControl()
        let proxy = connection?.remoteObjectProxyWithErrorHandler { @Sendable [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.connectionGeneration == generation else { return }
                self.acceptedDemands = [:]; self.batchStatus = "Error: \(error.localizedDescription)"; self.publishControl()
            }
        } as? FanHelperProtocol
        proxy?.applyDemands(Dictionary(uniqueKeysWithValues: demands.map { (String($0.key), $0.value) })) { @Sendable [weak self] response in
            DispatchQueue.main.async {
                guard let self, self.connectionGeneration == generation, self.controlSampleVersion.accepts(sampleVersion) else { return }
                if response == "ok" {
                    self.acceptedDemands = demands
                    self.batchStatus = "Authenticated batch accepted at \(Date().formatted(date: .omitted, time: .standard))"
                } else {
                    self.restore(); self.batchStatus = response.hasPrefix("error: ") ? "Error: " + String(response.dropFirst(7)) : "Error: \(response)"
                }
                self.state.stringValue = self.batchStatus
                self.publishControl()
            }
        }
    }
    private func publishUnavailable() { if monitoringVisible { onSnapshot?(nil) } }
    private var polling = false
    private func updateReadingCards(_ snapshot: FanSnapshot) {
        let summary = snapshot.fans.isEmpty ? "No fans detected" : "Live monitoring"
        if readings.stringValue != summary { readings.stringValue = summary }
        var values: [(String, String)] = snapshot.fans.map { fan in
            ("fan:\(fan.id)", "\(fan.name ?? "Fan \(fan.id)") · Actual \(Int(fan.current)) RPM · Target \(fan.target.map { String(Int($0)) } ?? "—") RPM\nMin \(Int(fan.minimum)) · Max \(Int(fan.maximum)) RPM · Mode readback: \(fan.manual.map { $0 ? "Manual" : "Automatic" } ?? "Unavailable")")
        }
        for area in Set(snapshot.descriptors.values.map(\.area)).union(["Aggregates"]).sorted() where areaCards[area] == nil {
            let button = NSButton(checkboxWithTitle: area, target: self, action: #selector(toggleArea(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(area)
            let cards = FanMonitoringCards(); cards.translatesAutoresizingMaskIntoConstraints = false; cards.isHidden = true
            areaCards[area] = cards; areaButtons[area] = button
            sensorSections.addArrangedSubview(button); sensorSections.addArrangedSubview(cards)
            cards.widthAnchor.constraint(equalTo: sensorSections.widthAnchor).isActive = true
        }
        for (area, button) in areaButtons { button.isHidden = area == "Other" && showOther.state != .on }
        let query = sensorSearch.stringValue.lowercased()
        let ordered = snapshot.descriptors.values.sorted { ($0.area, $0.displayName, $0.id) < ($1.area, $1.displayName, $1.id) }
        var displayedLogical = Set<String>()
        for descriptor in ordered {
            guard expandedAreas.contains(descriptor.area), descriptor.curated || showOther.state == .on else { continue }
            let detail = "\(descriptor.area) · \(descriptor.displayName) · \(descriptor.id) · \(descriptor.source)"
            guard query.isEmpty || detail.lowercased().contains(query) else { continue }
            let identity = descriptor.source + ":" + descriptor.rawKey
            guard displayedLogical.insert(identity).inserted else { continue }
            let fresh = snapshot.temperatures.filter { snapshot.descriptors[$0.key]?.source == descriptor.source && snapshot.descriptors[$0.key]?.rawKey == descriptor.rawKey }.values.max()
            values.append(("sensor:" + descriptor.id, detail + " · " + (fresh.map { String(format: "%.1f °C", $0) } ?? "Unavailable")))
        }
        if expandedAreas.contains("Aggregates") {
            for key in ["Highest CPU", "Average CPU", "Highest GPU", "Average GPU", "Highest Computer", "Average Computer"] where query.isEmpty || key.lowercased().contains(query) {
                values.append(("aggregate:" + key, key + " · " + ((latestSamplePlan?.areas.contains("Aggregates") == true ? snapshot.ruleReadings[key] : nil).map { String(format: "%.1f °C", $0) } ?? "Unavailable")))
            }
        }
        let keys = Set(values.map { $0.0 })
        for key in Array(readingCards.keys) where !keys.contains(key) {
            readingCards.removeValue(forKey: key)?.removeFromSuperview()
        }
        for (key, value) in values {
            let card: NSTextField
            if let existing = readingCards[key] { card = existing }
            else {
                card = NSTextField(wrappingLabelWithString: "")
                card.isSelectable = true; card.wantsLayer = true
                card.layer?.cornerRadius = 8; card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
                card.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
                card.translatesAutoresizingMaskIntoConstraints = true
                readingCards[key] = card
            }
            if card.stringValue != value { card.stringValue = value; card.toolTip = value; card.setAccessibilityLabel(value) }
        }
        fanCards.setCards(values.filter { $0.0.hasPrefix("fan:") }.compactMap { readingCards[$0.0] })
        for (area, cards) in areaCards {
            cards.isHidden = !expandedAreas.contains(area) || (area == "Other" && showOther.state != .on)
            cards.setCards(values.filter { item in
                (area == "Aggregates" && item.0.hasPrefix("aggregate:")) || (item.0.hasPrefix("sensor:") && snapshot.descriptors[String(item.0.dropFirst(7))]?.area == area)
            }.compactMap { readingCards[$0.0] })
        }
    }

    private func currentReadPlan() -> FanReadPlan {
        let visibleAreas = expandedAreas.subtracting(showOther.state == .on ? [] : ["Other"])
        return FanReadPlan(settings: settings, monitoring: monitoringVisible, areas: visibleAreas)
    }
    private var lastPollUptime: TimeInterval?
    private func pollIfDue() {
        let plan = currentReadPlan()
        // Keep control samples comfortably inside the three-second freshness limit.
        // Read-only monitoring can refresh less often; user actions still poll immediately.
        let now = ProcessInfo.processInfo.systemUptime
        guard plan.needsSample else { return }
        let monitoringDemand = monitoringVisible ? monitoringInterval : TimeInterval.infinity
        let controlDemand = plan.sensors.isEmpty ? TimeInterval.infinity : controlInterval
        let interval = min(monitoringDemand, controlDemand)
        guard lastPollUptime.map({ now - $0 >= interval - 0.2 }) ?? true else { return }
        poll()
    }
    private func poll() {
        let plan = currentReadPlan()
        let version = controlSampleVersion.generation
        let powerVersion = powerGeneration
        let started = Date()
        guard !polling, !suspended, plan.needsSample else { return }; polling = true
        lastPollUptime = ProcessInfo.processInfo.systemUptime
        queue.async { [weak self] in
            guard let self else { return }
            // Storage is touched only by this queue; no main-thread IOKit calls.
            let result = Result { try self.reader.snapshot(plan: plan) }
            DispatchQueue.main.async {
                self.polling = false
                guard self.timer != nil, !self.suspended else { return }
                guard powerVersion == self.powerGeneration,
                      self.controlSampleVersion.accepts(version), plan == self.currentReadPlan() else {
                    self.poll(); return
                }
                switch result {
                case let .success(snapshot):
                    self.latestSamplePlan = plan
                    let now = ProcessInfo.processInfo.systemUptime
                    let refreshMonitoring = self.monitoringVisible && (self.lastMonitoringUpdate.map { now - $0 >= self.monitoringInterval - 0.2 } ?? true)
                    self.latestSnapshot = snapshot; self.sampleDate = started
                    if refreshMonitoring {
                        self.lastMonitoringUpdate = now
                        self.updateReadingCards(snapshot)
                        self.onSnapshot?(snapshot)
                    }
                    self.rulesChanged()
                case let .failure(error):
                    if self.monitoringVisible, var unavailable = self.latestSnapshot { unavailable.temperatures = [:]; self.updateReadingCards(unavailable) }
                    self.latestSnapshot = nil; self.sampleDate = nil; self.publishUnavailable(); self.readings.stringValue = error.localizedDescription; self.restore()
                }
            }
        }
    }
}

private final class FanSMCReader: @unchecked Sendable {
    private var smc: AppleSMC?
    private var keys: [String] = []
    private var registry = FanSensorRegistry()
    private var enumeratedAt: TimeInterval = 0
    private var keyCount: Double?
    func invalidateDiscovery() { enumeratedAt = 0 }
    func snapshot(plan: FanReadPlan) throws -> FanSnapshot {
        if smc == nil { smc = try AppleSMC() }
        let opened = smc!
        let now = ProcessInfo.processInfo.systemUptime
        let count = try? opened.read("#KEY").number
        if enumeratedAt == 0 || now - enumeratedAt >= 60 || count != keyCount {
            keys = try opened.keys().filter { key in
                guard FanSensorMetadata.eligible(key), let info = try? opened.metadata(key) else { return false }
                return (info.type == "flt " && info.size == 4) || (info.type == "sp78" && info.size == 2)
            }
            keyCount = count; enumeratedAt = now
        }
        registry.discover(keys: keys)
        let hid = FanHIDReader.read(plan: plan)
        registry.discover(keys: hid.keys)
        var result = try SMCMonitor.snapshot(io: opened, temperatureKeys: plan.keys(in: registry.descriptors).filter { !$0.hasPrefix("HID:") })
        result.temperatures.merge(hid.values) { smc, _ in smc }
        registry.update(&result)
        return result
    }
}

/// Optional read-only private API. Each sample owns its client and all returned CF objects.
private enum FanHIDReader {
    static func read(plan: FanReadPlan) -> (keys: [String], values: [String: Double]) {
        guard let library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else { return ([], [:]) }
        defer { dlclose(library) }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(library, name).map { unsafeBitCast($0, to: type) }
        }
        typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
        typealias Match = @convention(c) (CFTypeRef, CFDictionary) -> Void
        typealias Services = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
        typealias Property = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
        typealias Event = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
        typealias Value = @convention(c) (CFTypeRef, Int32) -> Double
        guard let create = symbol("IOHIDEventSystemClientCreate", as: Create.self),
              let match = symbol("IOHIDEventSystemClientSetMatching", as: Match.self),
              let services = symbol("IOHIDEventSystemClientCopyServices", as: Services.self),
              let property = symbol("IOHIDServiceClientCopyProperty", as: Property.self),
              let event = symbol("IOHIDServiceClientCopyEvent", as: Event.self),
              let value = symbol("IOHIDEventGetFloatValue", as: Value.self),
              let client = create(nil)?.takeRetainedValue() else { return ([], [:]) }
        match(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        guard let array = services(client)?.takeRetainedValue() else { return ([], [:]) }
        var discovered: [String] = []
        var samples: [(product: String, location: String?, value: Double)] = []
        for service in (array as [AnyObject]) {
            guard let product = property(service, "Product" as CFString)?.takeRetainedValue() as? String,
                  !product.isEmpty else { continue }
            let location = property(service, "LocationID" as CFString)?.takeRetainedValue() as? NSNumber
            let key = "HID:\(product):\(location?.stringValue ?? "unknown")"
            discovered.append(key)
            guard let descriptor = FanSensorMetadata.descriptors(keys: [key])[key], plan.includes(descriptor),
                  let sample = event(service, 15, 0, 0)?.takeRetainedValue() else { continue }
            let temperature = value(sample, 15 << 16)
            guard FanSensorMetadata.valid(temperature) else { continue }
            samples.append((product, location?.stringValue, temperature))
        }
        return (discovered, FanSensorMetadata.mergeHID(samples))
    }
}

private enum FanHelperInstallation {
    static let installedPath = "/Library/PrivilegedHelperTools/TSMacToolsFanHelper/TSMacToolsFanHelper"
    static var bundledPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/TSMacToolsFanHelper").path }
    /// Validate the exact pinned identity before trusting the signed executable's content hash.
    static func fingerprint(_ path: String) -> String? {
        var code: SecStaticCode?, requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(FanHelperIdentity.helperRequirement as CFString, [], &requirement) == errSecSuccess,
              let code, let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let hash = dictionary[kSecCodeInfoUnique as String] as? Data else { return nil }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    static func runningStatus() -> String {
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "system/" + FanHelperIdentity.service]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self)
            if let line = output.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("pid = ") }) {
                return "Running: yes (\(line.trimmingCharacters(in: .whitespaces)))"
            }
            let details = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("state =") || $0.hasPrefix("last exit code =") || $0.hasPrefix("runs =") }.joined(separator: "; ")
            return process.terminationStatus == 0 ? "Running: no (\(details))" : "Running: status unavailable (launchctl exit \(process.terminationStatus))"
        } catch { return "Running: status unavailable" }
    }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    static func manage(_ operation: String) -> String? {
        guard ["install", "reinstall", "uninstall"].contains(operation),
              let helper = Optional(Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/TSMacToolsFanHelper")) else { return "Bundled helper is missing." }
        // Inline fixed bootstrap code is part of the signed application. Never execute
        // a checkout script as root. Verify the copied bytes in root-private staging.
        let script = """
        set -eu
        umask 077
        stage=$(/usr/bin/mktemp -d /private/var/tmp/tsmactools-helper.XXXXXX)
        trap '/bin/rm -rf "$stage"' EXIT
        /usr/bin/install -o root -g wheel -m 700 \(quote(helper.path)) "$stage/helper"
        /usr/bin/codesign --verify --strict -R \(quote("=" + FanHelperIdentity.helperRequirement)) "$stage/helper"
        "$stage/helper" --manage \(quote(operation))
        """
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
        let source = "do shell script \"" + escaped + "\" with administrator privileges with prompt \"TSMacTools needs permission to " + operation + " its signed fan helper.\""
        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: source) else { return "Could not prepare administrator authorization." }
        appleScript.executeAndReturnError(&error)
        if let error {
            if (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue == -128 { return "Administrator authorization cancelled. No helper operation was started." }
            return "Helper \(operation) failed: \(error[NSAppleScript.errorMessage] as? String ?? error.description)"
        }
        return nil
    }
    static func check() -> String? {
        let directory = "/Library/PrivilegedHelperTools/TSMacToolsFanHelper"
        let executable = directory + "/TSMacToolsFanHelper"
        let plist = "/Library/LaunchDaemons/local.clearain.MacTools.FanHelper.plist"
        guard FileManager.default.fileExists(atPath: executable) else {
            return "Helper not installed. Click Install helper to authorize installation of the signed bundled helper."
        }
        for path in ["/Library", "/Library/PrivilegedHelperTools", "/Library/LaunchDaemons", directory, executable, plist] {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_uid == 0, info.st_mode & 0o022 == 0,
                  info.st_mode & S_IFMT != S_IFLNK else {
                return "Helper installation has unsafe ownership or permissions. Use Reinstall after repairing unsafe paths."
            }
        }
        for (path, rule) in [(executable, FanHelperIdentity.helperRequirement)] {
            var code: SecStaticCode?, requirement: SecRequirement?
            guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
                  SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
                  let code, let requirement,
                  SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
                return "Helper signature is missing or does not match the required SurTeamCode certificate and identifier. Reinstall the signed bundled helper."
            }
        }
        return nil
    }
}
