import AppKit
import ApplicationServices
import Carbon
import MacToolsCore
import MacToolsScripting

private func hotkeyEventHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else {
        return noErr
    }

    var hotkeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotkeyID
    )
    guard status == noErr else {
        return status
    }

    let signature = hotkeyID.signature
    DispatchQueue.main.async {
        GlobalHotkeyController.handleHotkey(signature: signature)
    }
    return noErr
}

@MainActor
final class GlobalHotkeyController {
    struct CaptureToken: Hashable, Sendable {
        fileprivate let identifier: UInt64
    }

    private struct HotkeyCombination: Hashable {
        var keyCode: UInt32
        var modifiers: UInt32
    }

    private struct RegistrationSet {
        var hotkeys: [EventHotKeyRef]
        var handlers: [UInt32: HotkeyBinding]
        var bindings: [HotkeyBinding]
    }

    private struct RegistrationFailure: Error {
        var message: String
    }

    private enum Lifecycle {
        case inactive
        case active
        case capturing(token: CaptureToken, fallback: [HotkeyBinding])
        case shutdown
    }

    private static var controllers: [UInt32: GlobalHotkeyController] = [:]
    private static var nextSignature: UInt32 = 0x54534D31
    private static var nextCaptureIdentifier: UInt64 = 1

    private let runtime: AutomationRuntime
    private let configurationStore: UserConfigurationStore
    private let reloadConfigurationHandler: (() -> Void)?
    private weak var windowSwitcherController: WindowSwitcherController?
    private var configuration: UserConfiguration
    private var eventHandler: EventHandlerRef?
    private var registeredHotkeys: [EventHotKeyRef] = []
    private var registeredBindings: [HotkeyBinding] = []
    private var handlers: [UInt32: HotkeyBinding] = [:]
    private var lifecycle = Lifecycle.inactive

    init(
        runtime: AutomationRuntime,
        configuration: UserConfiguration,
        configurationStore: UserConfigurationStore = UserConfigurationStore(),
        windowSwitcherController: WindowSwitcherController? = nil,
        reloadConfigurationHandler: (() -> Void)? = nil
    ) {
        self.runtime = runtime
        self.configuration = configuration
        self.configurationStore = configurationStore
        self.windowSwitcherController = windowSwitcherController
        self.reloadConfigurationHandler = reloadConfigurationHandler
    }

    func start() {
        precondition(Thread.isMainThread)
        switch lifecycle {
        case .capturing, .shutdown:
            return
        case .inactive, .active:
            break
        }
        installEventHandlerIfNeeded()
        guard eventHandler != nil else { return }
        _ = replaceRegistrations(with: configuration.hotkeys, fallingBackTo: registeredBindings)
    }

    func apply(
        configuration: UserConfiguration,
        windowSwitcherController: WindowSwitcherController?
    ) {
        precondition(Thread.isMainThread)
        let shouldReregisterHotkeys = self.configuration.hotkeys != configuration.hotkeys
        self.configuration = configuration
        self.windowSwitcherController = windowSwitcherController
        switch lifecycle {
        case .capturing, .shutdown:
            return
        case .inactive, .active:
            break
        }
        if shouldReregisterHotkeys || registeredBindings != configuration.hotkeys || eventHandler == nil {
            start()
        }
    }

    func stop() {
        precondition(Thread.isMainThread)
        unregisterActiveHotkeys()
        if case .shutdown = lifecycle { return }
        lifecycle = .inactive
    }

    func shutdown() {
        // AppDelegate owns this main-actor controller for the process lifetime and
        // calls shutdown explicitly before termination. A Swift 6 deinitializer is
        // nonisolated, so Carbon teardown must not be deferred to deinit.
        precondition(Thread.isMainThread)
        unregisterActiveHotkeys()
        lifecycle = .shutdown
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    @discardableResult
    func beginHotkeyCapture() -> CaptureToken? {
        precondition(Thread.isMainThread)
        let fallback: [HotkeyBinding]
        switch lifecycle {
        case let .capturing(_, existingFallback):
            fallback = existingFallback
        case .shutdown:
            return nil
        case .inactive, .active:
            fallback = registeredBindings
        }

        unregisterActiveHotkeys()
        let token = CaptureToken(identifier: Self.nextCaptureIdentifier)
        Self.nextCaptureIdentifier &+= 1
        lifecycle = .capturing(token: token, fallback: fallback)
        return token
    }

    @discardableResult
    func endHotkeyCapture(_ token: CaptureToken) -> Bool {
        finishHotkeyCapture(token)
    }

    @discardableResult
    func cancelHotkeyCapture(_ token: CaptureToken) -> Bool {
        finishHotkeyCapture(token)
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else {
            return
        }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotkeyEventHandler,
            1,
            &eventType,
            nil,
            &eventHandler
        )

        if status != noErr {
            showStatusWindow(title: "Hotkey Error", body: "Unable to install global hotkey handler: \(status)")
        }
    }

    private func finishHotkeyCapture(_ token: CaptureToken) -> Bool {
        precondition(Thread.isMainThread)
        guard case let .capturing(currentToken, fallback) = lifecycle,
              currentToken == token else {
            return false
        }
        installEventHandlerIfNeeded()
        guard eventHandler != nil else {
            lifecycle = .inactive
            return false
        }
        return replaceRegistrations(with: configuration.hotkeys, fallingBackTo: fallback)
    }

    @discardableResult
    private func replaceRegistrations(
        with desiredBindings: [HotkeyBinding],
        fallingBackTo fallbackBindings: [HotkeyBinding]
    ) -> Bool {
        unregisterActiveHotkeys()
        switch makeRegistrationSet(for: desiredBindings) {
        case let .success(registrationSet):
            activate(registrationSet)
            return true
        case let .failure(desiredFailure):
            guard fallbackBindings != desiredBindings else {
                lifecycle = .inactive
                showStatusWindow(title: "Hotkey Error", body: desiredFailure.message)
                return false
            }
            switch makeRegistrationSet(for: fallbackBindings) {
            case let .success(registrationSet):
                activate(registrationSet)
                showStatusWindow(
                    title: "Hotkey Error",
                    body: "\(desiredFailure.message) The previous hotkeys remain active."
                )
            case let .failure(fallbackFailure):
                lifecycle = .inactive
                showStatusWindow(
                    title: "Hotkey Error",
                    body: "\(desiredFailure.message) Previous hotkeys could not be restored: \(fallbackFailure.message)"
                )
            }
            return false
        }
    }

    private func makeRegistrationSet(for bindings: [HotkeyBinding]) -> Result<RegistrationSet, RegistrationFailure> {
        var hotkeys: [EventHotKeyRef] = []
        var stagedHandlers: [UInt32: HotkeyBinding] = [:]
        var combinations: [HotkeyCombination: HotkeyBinding] = [:]

        func fail(_ message: String) -> Result<RegistrationSet, RegistrationFailure> {
            for hotkey in hotkeys {
                UnregisterEventHotKey(hotkey)
            }
            return .failure(RegistrationFailure(message: message))
        }

        for (index, binding) in bindings.enumerated() {
            guard !binding.modifiers.isEmpty else {
                return fail("A global hotkey requires at least one modifier: \(binding.label).")
            }
            guard let keyCode = keyCode(for: binding.key) else {
                return fail("Unsupported key in \(binding.label): \(binding.key).")
            }
            let modifierMask = carbonModifiers(for: binding.modifiers)
            guard modifierMask != 0 else {
                return fail("A global hotkey requires at least one recognized modifier: \(binding.label).")
            }
            let combination = HotkeyCombination(keyCode: UInt32(keyCode), modifiers: modifierMask)
            if let existing = combinations[combination] {
                return fail("\(binding.label) duplicates the shortcut used by \(existing.label).")
            }
            combinations[combination] = binding

            let signature = Self.nextSignature
            Self.nextSignature &+= 1
            let hotkeyID = EventHotKeyID(signature: OSType(signature), id: UInt32(index + 1))
            var hotkeyRef: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(keyCode),
                modifierMask,
                hotkeyID,
                GetApplicationEventTarget(),
                0,
                &hotkeyRef
            )
            guard status == noErr, let hotkeyRef else {
                return fail("Unable to register \(binding.label): \(status).")
            }
            hotkeys.append(hotkeyRef)
            stagedHandlers[signature] = binding
        }
        return .success(RegistrationSet(hotkeys: hotkeys, handlers: stagedHandlers, bindings: bindings))
    }

    private func activate(_ registrationSet: RegistrationSet) {
        registeredHotkeys = registrationSet.hotkeys
        registeredBindings = registrationSet.bindings
        handlers = registrationSet.handlers
        for signature in handlers.keys {
            Self.controllers[signature] = self
        }
        lifecycle = .active
    }

    private func unregisterActiveHotkeys() {
        for signature in handlers.keys {
            Self.controllers[signature] = nil
        }
        handlers.removeAll(keepingCapacity: true)
        for hotkey in registeredHotkeys {
            UnregisterEventHotKey(hotkey)
        }
        registeredHotkeys.removeAll(keepingCapacity: true)
        registeredBindings.removeAll(keepingCapacity: true)
    }

    static func handleHotkey(signature: OSType) {
        guard let controller = controllers[signature],
              case .active = controller.lifecycle,
              let binding = controller.handlers[signature] else {
            return
        }

        controller.handle(binding)
    }

    private func handle(_ binding: HotkeyBinding) {
        guard configuration.translation.enabled || !binding.action.isSelectedTextTranslation else {
            showStatusWindow(
                title: "Translation Disabled",
                body: "Enable selected-text translation in Settings before using this shortcut."
            )
            return
        }
        let started = CFAbsoluteTimeGetCurrent()
        logHotkey("begin \(binding.label) action=\(binding.action.kind.rawValue)")
        defer {
            logHotkey("end \(binding.label) elapsed=\(elapsedMilliseconds(since: started))")
        }

        switch binding.action.kind {
        case .focusApplication:
            focusApplication(path: binding.action.path, bundleIdentifier: binding.action.bundleIdentifier)
        case .showFocusedWindowInfo:
            showFocusedApplicationInfo()
        case .translateSelection:
            translateSelection()
        case .toggleFinder:
            toggleFinder(bundleIdentifier: binding.action.bundleIdentifier ?? configuration.application.finderBundleIdentifier)
        case .toggleTerminal:
            toggleTerminal(bundleIdentifier: binding.action.bundleIdentifier ?? configuration.application.terminalBundleIdentifier)
        case .reloadConfiguration:
            reloadConfiguration()
        case .runScript:
            runScriptAction(binding.action)
        case .callInterface:
            callInterface(binding.action.interfaceName)
        }
    }

    private func focusApplication(path: String?, bundleIdentifier: String?) {
        if let bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            openApplication(at: url)
            return
        }

        if let path {
            openApplication(at: URL(fileURLWithPath: path))
        }
    }

    private func toggleApplication(bundleIdentifier: String) {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if frontmost == bundleIdentifier {
            NSWorkspace.shared.frontmostApplication?.hide()
            return
        }
        focusApplication(path: nil, bundleIdentifier: bundleIdentifier)
    }

    private func toggleTerminal(bundleIdentifier: String) {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier {
            if windowSwitcherController?.focusMostRecentWindow(excluding: bundleIdentifier) != true {
                showStatusWindow(title: "TSMacTools", body: "没有上一个活跃窗口")
            }
            return
        }

        if windowSwitcherController?.focusMostRecentWindow(matching: bundleIdentifier) == true {
            return
        }
        focusApplication(path: nil, bundleIdentifier: bundleIdentifier)
    }

    private func toggleFinder(bundleIdentifier: String) {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier {
            focusOrCreateFinderHomeWindow()
            return
        }

        if windowSwitcherController?.focusMostRecentWindow(matching: bundleIdentifier) == true {
            return
        }

        focusApplication(path: nil, bundleIdentifier: bundleIdentifier)
    }

    private func focusOrCreateFinderHomeWindow() {
        guard let finder = NSWorkspace.shared.frontmostApplication else {
            return
        }

        let homeURL = normalizedFileURL(FileManager.default.homeDirectoryForCurrentUser)
        let homePath = normalizedFilePath(homeURL)
        let appElement = AXUIElementCreateApplication(finder.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.2)

        if let focusedWindow = focusedWindow(in: appElement),
           finderWindowURL(focusedWindow).map(normalizedFilePath) == homePath {
            sendCommandN()
            return
        }

        if let homeWindow = finderWindows(in: appElement).first(where: { finderWindowURL($0).map(normalizedFilePath) == homePath }) {
            focusFinderWindow(homeWindow, appElement: appElement)
            return
        }

        _ = NSWorkspace.shared.open(homeURL)
    }

    private func focusedWindow(in appElement: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func finderWindows(in appElement: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else {
            return []
        }
        windows.forEach { AXUIElementSetMessagingTimeout($0, 0.2) }
        return windows
    }

    private func finderWindowURL(_ window: AXUIElement) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &value) == .success,
              let value else {
            return nil
        }

        if let url = value as? URL {
            return url
        }

        guard let string = value as? String, !string.isEmpty else {
            return nil
        }
        if let url = URL(string: string), url.isFileURL {
            return url
        }
        return URL(fileURLWithPath: string)
    }

    private func normalizedFileURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func normalizedFilePath(_ url: URL) -> String {
        normalizedFileURL(url).path
    }

    private func focusFinderWindow(_ window: AXUIElement, appElement: AXUIElement) {
        _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, window)
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    private func sendCommandN() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_N), keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_N), keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private func openApplication(at url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
            if let error {
                Task { @MainActor in
                    self?.showStatusWindow(title: "Launch Error", body: error.localizedDescription)
                }
            }
        }
    }

    private func showFocusedApplicationInfo() {
        let app = NSWorkspace.shared.frontmostApplication
        showStatusWindow(
            title: "Focused Application",
            body: """
            Bundle ID: \(app?.bundleIdentifier ?? "<unknown>")
            Name: \(app?.localizedName ?? "<unknown>")
            Path: \(app?.bundleURL?.path ?? "<unknown>")
            """
        )
    }

    private func translateSelection() {
        guard configuration.translation.enabled else {
            showStatusWindow(title: "Translation Disabled", body: "Enable selected-text translation in Settings before using this shortcut.")
            return
        }
        copySelectionToPasteboard { [weak self] selectedText in
            guard let self else {
                return
            }

            let sourceText = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sourceText.isEmpty else {
                self.showStatusWindow(title: "LLM Translate", body: "没有读取到选中文本")
                return
            }

            self.showTranslationLoadingWindow(id: self.configuration.translation.nativeWindow.id)
            self.runScript(path: "scripts/translate_selection.py", function: "main", inputText: sourceText, title: "LLM Translate")
        }
    }

    private func runScriptAction(_ action: HotkeyAction) {
        let run: (String) -> Void = { [weak self] inputText in
            guard let self else {
                return
            }
            if let nativeWindowID = action.nativeWindowID {
                self.showTranslationLoadingWindow(id: nativeWindowID)
            }
            self.runScript(path: action.path, function: action.function, inputText: inputText, title: "Script")
        }

        switch action.input {
        case "selectedText":
            copySelectionToPasteboard { [weak self] selectedText in
                let sourceText = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !sourceText.isEmpty else {
                    self?.showStatusWindow(title: "Script", body: "没有读取到选中文本")
                    return
                }
                run(sourceText)
            }
        default:
            run("")
        }
    }

    private func copySelectionToPasteboard(completion: @escaping @MainActor (String) -> Void) {
        let started = CFAbsoluteTimeGetCurrent()
        logHotkey("copySelection begin configuredDelay=\(configuration.translation.copyKeystrokeDelay)s")
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()

        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + configuration.translation.copyKeystrokeDelay) {
            let copied = pasteboard.string(forType: .string) ?? ""
            if let previous {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
            self.logHotkey("copySelection end elapsed=\(self.elapsedMilliseconds(since: started)) bytes=\(copied.utf8.count)")
            completion(copied)
        }
    }

    private func runScript(path: String?, function: String?, inputText: String, title: String) {
        guard let path, !path.isEmpty else {
            showStatusWindow(title: title, body: "Missing script path")
            return
        }

        let scriptURL = scriptURL(for: path)
        let functionName = function?.isEmpty == false ? function! : "main"
        let started = CFAbsoluteTimeGetCurrent()
        logHotkey("runScript begin path=\(scriptURL.path) function=\(functionName) inputBytes=\(inputText.utf8.count)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.scripting.pythonPath)
        process.arguments = ["-c", Self.scriptRunner, scriptURL.path, functionName]
        process.currentDirectoryURL = scriptURL.deletingLastPathComponent()

        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        let outputBuffer = ScriptOutputBuffer()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                outputBuffer.appendOutput(data)
            }
        }
        error.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                outputBuffer.appendError(data)
            }
        }

        do {
            try process.run()
            logHotkey("runScript process started elapsed=\(elapsedMilliseconds(since: started)) pid=\(process.processIdentifier)")
            let context = ScriptExecutionContext(configuration: configuration, inputText: inputText)
            let payload = try JSONEncoder().encode(context)
            input.fileHandleForWriting.write(payload)
            try input.fileHandleForWriting.close()
        } catch {
            showStatusWindow(title: title, body: error.localizedDescription)
            return
        }

        process.terminationHandler = { [weak self] _ in
            output.fileHandleForReading.readabilityHandler = nil
            error.fileHandleForReading.readabilityHandler = nil
            outputBuffer.appendOutput(output.fileHandleForReading.readDataToEndOfFile())
            outputBuffer.appendError(error.fileHandleForReading.readDataToEndOfFile())
            let data = outputBuffer.outputData()
            let errorText = outputBuffer.errorText()
            Task { @MainActor in
                guard let self else {
                    return
                }
                self.logHotkey(
                    "runScript terminated elapsed=\(self.elapsedMilliseconds(since: started)) status=\(process.terminationStatus) stdoutBytes=\(data.count) stderrBytes=\(errorText.utf8.count)"
                )
                if !errorText.isEmpty {
                    self.logHotkey("runScript stderr=\(errorText.prefix(1000))")
                }
                do {
                    let command = try PythonScriptBridge().decodeCommand(from: data)
                    self.runtime.handle(command)
                } catch {
                    self.showStatusWindow(title: title, body: error.localizedDescription)
                }
            }
        }
    }

    private func scriptURL(for path: String) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return configurationStore.defaultDirectoryURL().appendingPathComponent(path)
    }

    private func showTranslationLoadingWindow(id: String) {
        let window = configuration.translation.nativeWindow
        runtime.handle(.showWindow(
            id: NativeWindowID(id),
            content: NativeWindowContent(
                title: window.title,
                body: .plainText(NativeWindowManager.translationLoadingBody)
            )
        ))
    }

    private func reloadConfiguration() {
        if let reloadConfigurationHandler {
            reloadConfigurationHandler()
            return
        }

        do {
            let result = try configurationStore.bootstrap()
            configuration = result.configuration
            start()
            showStatusWindow(title: "TSMacTools", body: "Configuration reloaded from \(result.configURL.path)")
        } catch {
            showStatusWindow(title: "Reload Error", body: error.localizedDescription)
        }
    }

    private func callInterface(_ name: String?) {
        switch name {
        case "focusedWindowInfo":
            showFocusedApplicationInfo()
        case "reloadConfiguration":
            reloadConfiguration()
        case "translateSelection":
            translateSelection()
        default:
            showStatusWindow(title: "TSMacTools", body: "Unknown interface: \(name ?? "<missing>")")
        }
    }

    private func showStatusWindow(title: String, body: String) {
        TransientAlertPresenter.shared.show(title: title, body: body)
    }

    private func logHotkey(_ message: String) {
        guard configuration.windowSwitcher.debug else {
            return
        }
        NSLog("[hotkey] %@", message)
    }

    private func elapsedMilliseconds(since started: CFAbsoluteTime) -> String {
        String(format: "%.1fms", (CFAbsoluteTimeGetCurrent() - started) * 1000)
    }

    private func carbonModifiers(for modifiers: [String]) -> UInt32 {
        modifiers.reduce(UInt32(0)) { result, modifier in
            switch modifier.lowercased() {
            case "cmd", "command":
                return result | UInt32(cmdKey)
            case "ctrl", "control":
                return result | UInt32(controlKey)
            case "alt", "option":
                return result | UInt32(optionKey)
            case "shift":
                return result | UInt32(shiftKey)
            default:
                return result
            }
        }
    }

    private func keyCode(for key: String) -> Int? {
        switch key.uppercased() {
        case "A": return kVK_ANSI_A
        case "B": return kVK_ANSI_B
        case "C": return kVK_ANSI_C
        case "D": return kVK_ANSI_D
        case "E": return kVK_ANSI_E
        case "F": return kVK_ANSI_F
        case "G": return kVK_ANSI_G
        case "H": return kVK_ANSI_H
        case "I": return kVK_ANSI_I
        case "J": return kVK_ANSI_J
        case "K": return kVK_ANSI_K
        case "L": return kVK_ANSI_L
        case "M": return kVK_ANSI_M
        case "N": return kVK_ANSI_N
        case "O": return kVK_ANSI_O
        case "P": return kVK_ANSI_P
        case "Q": return kVK_ANSI_Q
        case "R": return kVK_ANSI_R
        case "S": return kVK_ANSI_S
        case "T": return kVK_ANSI_T
        case "U": return kVK_ANSI_U
        case "V": return kVK_ANSI_V
        case "W": return kVK_ANSI_W
        case "X": return kVK_ANSI_X
        case "Y": return kVK_ANSI_Y
        case "Z": return kVK_ANSI_Z
        case ".": return kVK_ANSI_Period
        default: return nil
        }
    }
}

private struct ScriptExecutionContext: Encodable {
    var configuration: UserConfiguration
    var inputText: String
}

private final class ScriptOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data()
    private var error = Data()

    func appendOutput(_ data: Data) {
        guard !data.isEmpty else {
            return
        }
        lock.lock()
        output.append(data)
        lock.unlock()
    }

    func appendError(_ data: Data) {
        guard !data.isEmpty else {
            return
        }
        lock.lock()
        error.append(data)
        lock.unlock()
    }

    func outputData() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return output
    }

    func errorText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: error, encoding: .utf8) ?? ""
    }
}

private extension GlobalHotkeyController {
    static let scriptRunner = #"""
import importlib.util
import json
import sys


class NativeWindow:
    def show(self, id, title, body, format="plainText"):
        print(json.dumps({
            "command": "window.show",
            "id": id,
            "title": title,
            "format": format,
            "body": body,
        }, ensure_ascii=False), flush=True)

    def close(self, id):
        print(json.dumps({
            "command": "window.close",
            "id": id,
        }, ensure_ascii=False), flush=True)


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: SCRIPT FUNCTION")

    script_path = sys.argv[1]
    function_name = sys.argv[2]
    context = json.loads(sys.stdin.read() or "{}")

    spec = importlib.util.spec_from_file_location("tsmactools_user_script", script_path)
    module = importlib.util.module_from_spec(spec)
    module.config = context.get("configuration", {})
    module.input_text = context.get("inputText", "")
    module.nativewindow = NativeWindow()
    module.window = module.nativewindow

    if spec.loader is None:
        raise SystemExit(f"unable to load script: {script_path}")
    spec.loader.exec_module(module)

    function = getattr(module, function_name)
    result = function()
    if isinstance(result, dict):
        print(json.dumps(result, ensure_ascii=False), flush=True)
    elif isinstance(result, str) and result.strip():
        print(result, flush=True)
    return 0 if result is None else int(result) if isinstance(result, int) else 0


if __name__ == "__main__":
    raise SystemExit(main())
"""#
}

private extension HotkeyBinding {
    var label: String {
        id ?? "\(modifiers.joined(separator: "+"))+\(key)"
    }
}
