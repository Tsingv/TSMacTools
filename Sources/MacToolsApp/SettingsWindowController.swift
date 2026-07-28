import AppKit
import Carbon.HIToolbox
import MacToolsCore

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
        case pythonPath
        case finderBundleIdentifier
        case terminalBundleIdentifier
        case ignoredApplicationNames
        case googleSourceLanguage
        case googleTargetLanguage
        case googleTargetLanguageForChinese
        case copyKeystrokeDelay
        case model
        case contextWindowTokens
        case outputTokenLimit
        case requestTokenLimit
        case apiKey
        case googleAPIKey
    }

    private enum Page: Int, CaseIterable {
        case general
        case hotkeys
        case scrolling

        var title: String {
            switch self {
            case .general: "General"
            case .hotkeys: "Hotkeys"
            case .scrolling: "Scrolling"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .hotkeys: "keyboard"
            case .scrolling: "scroll"
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

    private var windowSwitcherToggle: NSButton?
    private var translationToggle: NSButton?
    private var debugToggle: NSButton?
    private var providerPopup: NSPopUpButton?

    private var scrollEnabledToggle: NSButton?
    private var presetPopup: NSPopUpButton?
    private var presetSummary: NSTextField?
    private var smoothVerticalToggle: NSButton?
    private var smoothHorizontalToggle: NSButton?
    private var reverseVerticalToggle: NSButton?
    private var reverseHorizontalToggle: NSButton?
    private var excludeTrackpadToggle: NSButton?
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
    private var reconciliationScheduled = false
    private weak var activeHotkeyRecorder: HotkeyRecorderButton?
    private var isHotkeyRecordingActive = false
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
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
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
        showPage(selectedPage)
    }

    private func buildWindow() {
        guard let root = window?.contentView else { return }

        let pageBar = NSStackView()
        pageBar.orientation = .horizontal
        pageBar.alignment = .centerY
        pageBar.distribution = .fillEqually
        pageBar.spacing = 10
        pageBar.edgeInsets = NSEdgeInsets(top: 10, left: 150, bottom: 8, right: 150)
        pageBar.translatesAutoresizingMaskIntoConstraints = false

        for page in Page.allCases {
            let button = SettingsPageButton(title: page.title, target: self, action: #selector(selectPage(_:)))
            button.tag = page.rawValue
            button.imagePosition = .imageAbove
            button.image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: page.title)
            button.font = .systemFont(ofSize: 12, weight: .medium)
            button.toolTip = page.title
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(equalToConstant: 62).isActive = true
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
            pageBar.heightAnchor.constraint(equalToConstant: 80),
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

    private func showPage(_ page: Page) {
        endActiveHotkeyRecording()
        selectedPage = page
        for (candidate, button) in pageButtons {
            let isSelected = candidate == page
            button.state = .off
            (button as? SettingsPageButton)?.isPageSelected = isSelected
        }
        contentContainer.subviews.forEach { $0.removeFromSuperview() }

        let pageView: NSView = switch page {
        case .general: makeGeneralPage()
        case .hotkeys: makeHotkeysPage()
        case .scrolling: makeScrollingPage()
        }
        pageView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(pageView)
        NSLayoutConstraint.activate([
            pageView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            pageView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            pageView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            pageView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
        ])
    }

    func windowWillClose(_ notification: Notification) {
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
        let stack = pageStack(title: "General", subtitle: "Common settings are applied immediately while JSONC comments, unknown fields, and unrelated edits are preserved.")
        let switcher = checkbox("Enable window switcher", action: #selector(generalControlChanged(_:)))
        switcher.state = configuration.windowSwitcher.enabled ? .on : .off
        switcher.tag = 1
        windowSwitcherToggle = switcher

        let translation = checkbox("Enable selected-text translation", action: #selector(generalControlChanged(_:)))
        translation.state = configuration.translation.enabled ? .on : .off
        translation.tag = 2
        translationToggle = translation

        let debug = checkbox("Enable timing and event diagnostics", action: #selector(generalControlChanged(_:)))
        debug.state = configuration.windowSwitcher.debug ? .on : .off
        debug.tag = 3
        debugToggle = debug

        let provider = NSPopUpButton()
        provider.addItems(withTitles: ["Google Web", "Google Cloud", "LLM"])
        provider.selectItem(at: ["google_web", "google", "llm"].firstIndex(of: configuration.translation.provider) ?? 0)
        provider.target = self
        provider.action = #selector(providerChanged(_:))
        providerPopup = provider

        stack.addArrangedSubview(formSection(rows: [
            ("Window switching", switcher, "Command-Tab window cycling and Accessibility focus."),
            ("Translation", translation, "Runs the configured native or Python translation action."),
            ("Provider", provider, "Selects the configured translation backend."),
            ("Diagnostics", debug, "Writes compact hotkey and window timing logs.")
        ]))

        let followScreen = checkbox("Follow the focused screen", action: #selector(generalControlChanged(_:)))
        followScreen.state = configuration.windowSwitcher.followFocusedScreen ? .on : .off
        followScreen.tag = 4
        stack.addArrangedSubview(formSection(rows: [
            ("Command-Tab", readOnlyValue(configuration.windowSwitcher.commandTabBehavior), "Current strategy identifier; alternative strategies are not implemented yet."),
            ("Same application", readOnlyValue(configuration.windowSwitcher.sameApplicationBehavior), "Current strategy identifier; alternative strategies are not implemented yet."),
            ("Screen", followScreen, "Places the switcher on the screen containing the focused window."),
            ("Width", editableField(String(configuration.windowSwitcher.width), field: .switcherWidth, width: 150), "Switcher overlay width in points."),
            ("Height", editableField(String(configuration.windowSwitcher.height), field: .switcherHeight, width: 150), "Switcher overlay height in points."),
            ("Maximum rows", editableField(String(configuration.windowSwitcher.maxVisibleRows), field: .switcherMaxRows, width: 150), "Maximum number of visible window rows.")
        ]))

        stack.addArrangedSubview(formSection(rows: [
            ("Python", editableField(configuration.scripting.pythonPath, field: .pythonPath), "Executable used for script-backed actions."),
            ("Finder bundle ID", editableField(configuration.application.finderBundleIdentifier, field: .finderBundleIdentifier), "Bundle identifier used by the Finder toggle."),
            ("Terminal bundle ID", editableField(configuration.application.terminalBundleIdentifier, field: .terminalBundleIdentifier), "Bundle identifier used by the terminal toggle."),
            ("Ignored apps", editableField(configuration.application.ignoredWindowApplicationNames.joined(separator: ", "), field: .ignoredApplicationNames), "Comma-separated application names omitted from the window switcher.")
        ]))

        let normalizePDF = checkbox("Join common PDF hard-wrapped lines", action: #selector(generalControlChanged(_:)))
        normalizePDF.state = configuration.translation.normalizePDFLineBreaks ? .on : .off
        normalizePDF.tag = 5
        stack.addArrangedSubview(formSection(rows: [
            ("Source language", editableField(configuration.translation.googleSourceLanguage, field: .googleSourceLanguage, width: 180), "Use auto for source-language detection."),
            ("Target language", editableField(configuration.translation.googleTargetLanguage, field: .googleTargetLanguage, width: 180), "Language used when the selected text is not Chinese."),
            ("Chinese target", editableField(configuration.translation.googleTargetLanguageForChinese, field: .googleTargetLanguageForChinese, width: 180), "Language used when the selected text is Chinese."),
            ("PDF text", normalizePDF, "Preserves paragraphs and structural lines while joining common hard wraps."),
            ("Copy delay", editableField(String(format: "%.2f", configuration.translation.copyKeystrokeDelay), field: .copyKeystrokeDelay, width: 150), "Seconds to wait after requesting the selected text."),
            ("LLM model", editableField(configuration.translation.model, field: .model), "Provider model identifier."),
            ("Context tokens", editableField(String(configuration.translation.contextWindowTokens), field: .contextWindowTokens, width: 150), "Total context-window budget."),
            ("Output tokens", editableField(String(configuration.translation.outputTokenLimit), field: .outputTokenLimit, width: 150), "Requested maximum completion budget."),
            ("Request tokens", editableField(String(configuration.translation.requestTokenLimit), field: .requestTokenLimit, width: 150), "On-demand request budget; zero disables this clamp."),
            ("LLM API key", editableField(configuration.translation.apiKey, field: .apiKey, secure: true), "Stored in your local JSONC configuration and masked in this window."),
            ("Google API key", editableField(configuration.translation.googleApiKey, field: .googleAPIKey, secure: true), "Used only by the Google Cloud provider and masked in this window.")
        ]))

        let openConfig = NSButton(title: "Open config.jsonc…", target: self, action: #selector(openConfigFile))
        openConfig.bezelStyle = .rounded
        stack.addArrangedSubview(formSection(rows: [
            ("Advanced", openConfig, "Edit translation.endpoint, translation.googleEndpoint, translation.googleWebEndpoint, translation.googleWebClient, translation.thinkingEnabled, translation.thinkingParameter, translation.temperature, translation.promptTemplate, translation.systemPrompt, translation.nativeWindow, and hotkey action/path fields in JSONC.")
        ]))
        stack.addArrangedSubview(note("Accessibility permission is shared by window, hotkey, and mouse automation. TSMacTools never enables a disabled event tap after permission is revoked."))
        return scrollable(stack)
    }

    private func makeHotkeysPage() -> NSView {
        let stack = pageStack(title: "Hotkeys", subtitle: "Click a shortcut, then press a modifier combination and a letter or period.")
        for (index, binding) in configuration.hotkeys.enumerated() {
            let row = SettingsCardStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.distribution = .fill
            row.spacing = 14
            row.edgeInsets = NSEdgeInsets(top: 9, left: 12, bottom: 9, right: 12)
            row.cornerRadius = 8
            row.widthAnchor.constraint(equalToConstant: 680).isActive = true

            let action = NSTextField(labelWithString: hotkeyActionDescription(binding.action))
            action.font = .systemFont(ofSize: 13, weight: .medium)
            action.lineBreakMode = .byTruncatingMiddle
            action.toolTip = hotkeyActionDescription(binding.action)
            action.setContentHuggingPriority(.defaultLow, for: .horizontal)

            let recorder = HotkeyRecorderButton(binding: binding)
            recorder.onRecordingBegan = { [weak self, weak recorder] in
                guard let self, let recorder else { return }
                self.beginHotkeyRecording(recorder)
            }
            recorder.onRecordingEnded = { [weak self, weak recorder] in
                guard let self, let recorder else { return }
                self.endHotkeyRecording(recorder)
            }
            recorder.onRecord = { [weak self] modifiers, key in
                guard let self, self.configuration.hotkeys.indices.contains(index) else {
                    return .rejected(MutationError.hotkeyChangedExternally.localizedDescription)
                }
                let shortcut = HotkeyShortcut(modifiers: modifiers, key: key)
                let result = self.persist(reportFailure: false) { latest in
                    guard let latestIndex = self.resolveHotkeyIndex(
                        for: binding,
                        preferredIndex: index,
                        in: latest.hotkeys
                    ) else {
                        throw MutationError.hotkeyChangedExternally
                    }
                    if let conflict = latest.conflictingHotkey(for: shortcut, excluding: latestIndex) {
                        throw MutationError.hotkeyConflict(
                            self.hotkeyActionDescription(conflict.action)
                        )
                    }
                    latest.hotkeys[latestIndex].modifiers = modifiers
                    latest.hotkeys[latestIndex].key = key
                }
                switch result {
                case .success:
                    return .accepted
                case let .failure(error):
                    self.didFail(error)
                    return .rejected(error.localizedDescription)
                }
            }
            recorder.widthAnchor.constraint(equalToConstant: 260).isActive = true
            row.addArrangedSubview(action)
            row.addArrangedSubview(recorder)
            stack.addArrangedSubview(row)
        }
        stack.addArrangedSubview(note("Actions and application paths remain editable in the JSONC file. Recording here changes only the selected key combination."))
        return scrollable(stack)
    }

    private func makeScrollingPage() -> NSView {
        let stack = pageStack(title: "Smooth Scrolling", subtitle: "Mouse-wheel events use a display-synchronized curve; trackpad gestures pass through by default.")
        let enabled = checkbox("Enable smooth mouse scrolling", action: #selector(scrollToggleChanged(_:)))
        enabled.tag = 10
        enabled.state = configuration.scroll.enabled ? .on : .off
        scrollEnabledToggle = enabled

        let preset = NSPopUpButton()
        let selectablePresets = ScrollPreset.allCases
        preset.addItems(withTitles: selectablePresets.map(\.displayName))
        preset.selectItem(at: selectablePresets.firstIndex(of: configuration.scroll.preset) ?? 0)
        preset.target = self
        preset.action = #selector(presetChanged(_:))
        presetPopup = preset

        let summary = NSTextField(wrappingLabelWithString: configuration.scroll.preset.summary)
        summary.textColor = .secondaryLabelColor
        summary.font = .systemFont(ofSize: 12)
        presetSummary = summary

        let basic = formSection(rows: [
            ("Optimization", enabled, "The original event passes through if the display clock is unavailable."),
            ("Mode", preset, "Precise, Balanced, Fluid, and Glide are built-in TSMacTools curves."),
            ("", summary, "")
        ])
        stack.addArrangedSubview(basic)

        let smoothV = checkbox("Vertical", action: #selector(scrollToggleChanged(_:)))
        smoothV.tag = 11
        smoothV.state = configuration.scroll.smoothVertical ? .on : .off
        smoothVerticalToggle = smoothV
        let smoothH = checkbox("Horizontal", action: #selector(scrollToggleChanged(_:)))
        smoothH.tag = 12
        smoothH.state = configuration.scroll.smoothHorizontal ? .on : .off
        smoothHorizontalToggle = smoothH
        let reverseV = checkbox("Vertical", action: #selector(scrollToggleChanged(_:)))
        reverseV.tag = 13
        reverseV.state = configuration.scroll.reverseVertical ? .on : .off
        reverseVerticalToggle = reverseV
        let reverseH = checkbox("Horizontal", action: #selector(scrollToggleChanged(_:)))
        reverseH.tag = 14
        reverseH.state = configuration.scroll.reverseHorizontal ? .on : .off
        reverseHorizontalToggle = reverseH
        let trackpad = checkbox("Leave trackpad and Magic Mouse gestures untouched", action: #selector(scrollToggleChanged(_:)))
        trackpad.tag = 15
        trackpad.state = configuration.scroll.excludeTrackpad ? .on : .off
        excludeTrackpadToggle = trackpad
        stack.addArrangedSubview(formSection(rows: [
            ("Smooth axes", horizontalControls([smoothV, smoothH]), "An unsmoothed axis continues through the original event."),
            ("Reverse axes", horizontalControls([reverseV, reverseH]), "Direction reversal works with or without smoothing."),
            ("Gesture devices", trackpad, "Phase-bearing native gestures bypass the mouse engine.")
        ]))

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
        stack.addArrangedSubview(formSection(rows: [
            ("Step", step.view, "Minimum distance produced by a mechanical wheel notch."),
            ("Speed", speed.view, "Overall distance multiplier."),
            ("Duration", duration.view, "Time for approximately 99% of the momentum tail."),
            ("Acceleration", acceleration.view, "Adds bounded speed during a rapid wheel burst."),
            ("Stop threshold", deadZone.view, "Ends a tail once its remaining movement is visually negligible.")
        ]))
        return scrollable(stack)
    }

    @objc private func generalControlChanged(_ sender: NSButton) {
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
        default: return
        }
    }

    @objc private func providerChanged(_ sender: NSPopUpButton) {
        let provider = ["google_web", "google", "llm"][sender.indexOfSelectedItem.clamped(to: 0 ... 2)]
        configuration.translation.provider = provider
        persist { $0.translation.provider = provider }
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
        case .model:
            let value = try requiredText(rawValue, name: "LLM model")
            configuration.translation.model = value
            persist { $0.translation.model = value }
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
        case .googleAPIKey:
            configuration.translation.googleApiKey = rawValue
            persist { $0.translation.googleApiKey = rawValue }
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

    private func displayedValue(for field: ConfigurationField) -> String {
        switch field {
        case .switcherWidth: String(configuration.windowSwitcher.width)
        case .switcherHeight: String(configuration.windowSwitcher.height)
        case .switcherMaxRows: String(configuration.windowSwitcher.maxVisibleRows)
        case .pythonPath: configuration.scripting.pythonPath
        case .finderBundleIdentifier: configuration.application.finderBundleIdentifier
        case .terminalBundleIdentifier: configuration.application.terminalBundleIdentifier
        case .ignoredApplicationNames: configuration.application.ignoredWindowApplicationNames.joined(separator: ", ")
        case .googleSourceLanguage: configuration.translation.googleSourceLanguage
        case .googleTargetLanguage: configuration.translation.googleTargetLanguage
        case .googleTargetLanguageForChinese: configuration.translation.googleTargetLanguageForChinese
        case .copyKeystrokeDelay: String(format: "%.2f", configuration.translation.copyKeystrokeDelay)
        case .model: configuration.translation.model
        case .contextWindowTokens: String(configuration.translation.contextWindowTokens)
        case .outputTokenLimit: String(configuration.translation.outputTokenLimit)
        case .requestTokenLimit: String(configuration.translation.requestTokenLimit)
        case .apiKey: configuration.translation.apiKey
        case .googleAPIKey: configuration.translation.googleApiKey
        }
    }

    @objc private func scrollToggleChanged(_ sender: NSButton) {
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
        _ mutation: (inout UserConfiguration) throws -> Void
    ) -> Result<UserConfiguration, Error> {
        let unsavedTuningChanges = pendingTuningChanges
        let rollbackConfiguration = lastKnownGoodConfiguration
        do {
            var expectedConfiguration = rollbackConfiguration
            try mutation(&expectedConfiguration)
            let savedConfiguration = try configurationStore.update(at: configURL, mutation: mutation)
            let mergedExternalChanges = savedConfiguration != expectedConfiguration
            configuration = savedConfiguration
            lastKnownGoodConfiguration = savedConfiguration
            didSave(savedConfiguration)
            reapplyUnsavedTuning(unsavedTuningChanges)
            if mergedExternalChanges {
                scheduleVisiblePageReconciliation()
            }
            return .success(savedConfiguration)
        } catch {
            if let latest = try? configurationStore.load(from: configURL) {
                configuration = latest
                lastKnownGoodConfiguration = latest
            } else {
                configuration = rollbackConfiguration
            }
            reapplyUnsavedTuning(unsavedTuningChanges)
            scheduleVisiblePageReconciliation()
            if reportFailure {
                didFail(error)
            }
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
        showPage(selectedPage)
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

    private func pageStack(title: String, subtitle: String) -> NSStackView {
        let stack = SettingsPageStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 34, bottom: 30, right: 34)

        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 21, weight: .semibold)
        let subheading = NSTextField(wrappingLabelWithString: subtitle)
        subheading.font = .systemFont(ofSize: 12)
        subheading.textColor = .secondaryLabelColor
        subheading.maximumNumberOfLines = 0
        subheading.widthAnchor.constraint(equalToConstant: 680).isActive = true
        stack.addArrangedSubview(heading)
        stack.addArrangedSubview(subheading)
        return stack
    }

    private func formSection(rows: [(String, NSView, String)]) -> NSView {
        let grid = NSGridView()
        grid.rowSpacing = 13
        grid.columnSpacing = 14
        grid.xPlacement = .fill
        grid.yPlacement = .center
        for (title, control, help) in rows {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.alignment = .right

            let valueStack = NSStackView()
            valueStack.orientation = .vertical
            valueStack.alignment = .leading
            valueStack.spacing = 3
            valueStack.addArrangedSubview(control)
            if !help.isEmpty {
                let helpLabel = NSTextField(wrappingLabelWithString: help)
                helpLabel.font = .systemFont(ofSize: 11)
                helpLabel.textColor = .tertiaryLabelColor
                valueStack.addArrangedSubview(helpLabel)
            }
            grid.addRow(with: [label, valueStack])
        }
        grid.column(at: 0).width = 122

        let card = SettingsCardView(cornerRadius: 10)
        grid.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            grid.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            grid.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            card.widthAnchor.constraint(equalToConstant: 680)
        ])
        return card
    }

    private func checkbox(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.font = .systemFont(ofSize: 13)
        return button
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

    private func readOnlyValue(_ value: String) -> NSTextField {
        let field = NSTextField(labelWithString: value)
        field.font = .systemFont(ofSize: 13, weight: .medium)
        field.textColor = .labelColor
        field.lineBreakMode = .byTruncatingMiddle
        return field
    }

    private func horizontalControls(_ controls: [NSView]) -> NSStackView {
        let stack = NSStackView(views: controls)
        stack.orientation = .horizontal
        stack.spacing = 18
        return stack
    }

    private func tuningSlider(value: Double, range: ClosedRange<Double>, tag: Int) -> (view: NSView, slider: NSSlider, value: NSTextField) {
        let slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: self, action: #selector(tuningChanged(_:)))
        slider.tag = tag
        slider.isContinuous = true
        slider.widthAnchor.constraint(equalToConstant: 330).isActive = true
        let valueLabel = NSTextField(labelWithString: "")
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        valueLabel.alignment = .right
        valueLabel.widthAnchor.constraint(equalToConstant: 62).isActive = true
        let row = NSStackView(views: [slider, valueLabel])
        row.orientation = .horizontal
        row.spacing = 12
        return (row, slider, valueLabel)
    }

    private func scrollable(_ stack: NSStackView) -> NSView {
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
        defer {
            window.appearance = originalAppearance
            window.setContentSize(originalContentSize)
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
    #endif

    private func hotkeyActionDescription(_ action: HotkeyAction) -> String {
        if action.isSelectedTextTranslation {
            return "Translate selected text"
        }
        return switch action.kind {
        case .focusApplication: "Focus · \(URL(fileURLWithPath: action.path ?? "Application").deletingPathExtension().lastPathComponent)"
        case .showFocusedWindowInfo: "Show focused window info"
        case .translateSelection: "Translate selected text"
        case .toggleFinder: "Toggle Finder"
        case .toggleTerminal: "Toggle Terminal"
        case .reloadConfiguration: "Reload configuration"
        case .runScript: "Script · \(action.function ?? URL(fileURLWithPath: action.path ?? "Script").lastPathComponent)"
        case .callInterface: "Interface · \(action.interfaceName ?? "Unknown")"
        }
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
    var onRecord: (([String], String) -> CommitResult)?
    private var binding: HotkeyBinding
    private var recording = false

    init(binding: HotkeyBinding) {
        self.binding = binding
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

    @objc private func beginRecording() {
        guard !recording else { return }
        recording = true
        title = "Press shortcut…"
        toolTip = "Press at least one modifier plus a letter or period. Press Escape to cancel."
        guard window?.makeFirstResponder(self) == true else {
            recording = false
            updateTitle()
            return
        }
        onRecordingBegan?()
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
        if event.keyCode == 53 {
            _ = window?.makeFirstResponder(nil)
            return
        }
        let modifiers = recordedModifiers(event.modifierFlags)
        guard !modifiers.isEmpty,
              let key = supportedKey(for: event.keyCode) else {
            NSSound.beep()
            return
        }
        switch onRecord?(modifiers, key) ?? .rejected("Unable to save this shortcut.") {
        case .accepted:
            binding.modifiers = modifiers
            binding.key = key
            _ = window?.makeFirstResponder(nil)
        case let .rejected(message):
            title = message
            toolTip = message
            NSSound.beep()
        }
    }

    private func updateTitle() {
        title = shortcutTitle(modifiers: binding.modifiers, key: binding.key)
        toolTip = nil
    }

    private func endRecordingIfNeeded() {
        guard recording else { return }
        recording = false
        updateTitle()
        onRecordingEnded?()
    }

    private func recordedModifiers(_ flags: NSEvent.ModifierFlags) -> [String] {
        var result: [String] = []
        if flags.contains(.control) { result.append("ctrl") }
        if flags.contains(.option) { result.append("alt") }
        if flags.contains(.shift) { result.append("shift") }
        if flags.contains(.command) { result.append("cmd") }
        return result
    }

    private func supportedKey(for keyCode: UInt16) -> String? {
        switch Int(keyCode) {
        case kVK_ANSI_A: "A"
        case kVK_ANSI_B: "B"
        case kVK_ANSI_C: "C"
        case kVK_ANSI_D: "D"
        case kVK_ANSI_E: "E"
        case kVK_ANSI_F: "F"
        case kVK_ANSI_G: "G"
        case kVK_ANSI_H: "H"
        case kVK_ANSI_I: "I"
        case kVK_ANSI_J: "J"
        case kVK_ANSI_K: "K"
        case kVK_ANSI_L: "L"
        case kVK_ANSI_M: "M"
        case kVK_ANSI_N: "N"
        case kVK_ANSI_O: "O"
        case kVK_ANSI_P: "P"
        case kVK_ANSI_Q: "Q"
        case kVK_ANSI_R: "R"
        case kVK_ANSI_S: "S"
        case kVK_ANSI_T: "T"
        case kVK_ANSI_U: "U"
        case kVK_ANSI_V: "V"
        case kVK_ANSI_W: "W"
        case kVK_ANSI_X: "X"
        case kVK_ANSI_Y: "Y"
        case kVK_ANSI_Z: "Z"
        case kVK_ANSI_Period: "."
        default: nil
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
        return symbols + key.uppercased()
    }
}

@MainActor
private final class SettingsPageButton: NSButton {
    var isPageSelected = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 9
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        let accent = NSColor.controlAccentColor
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = isPageSelected ? 1.25 : 0
        layer?.borderColor = accent.cgColor
        contentTintColor = isPageSelected ? accent : .secondaryLabelColor
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: isPageSelected ? .semibold : .medium),
                .foregroundColor: isPageSelected ? accent : NSColor.secondaryLabelColor
            ]
        )
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

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
