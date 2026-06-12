import AppKit
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
    private static var controllers: [UInt32: GlobalHotkeyController] = [:]
    private static var nextSignature: UInt32 = 0x54534D31

    private let runtime: AutomationRuntime
    private let configurationStore: UserConfigurationStore
    private weak var windowSwitcherController: WindowSwitcherController?
    private var configuration: UserConfiguration
    private var eventHandler: EventHandlerRef?
    private var registeredHotkeys: [EventHotKeyRef?] = []
    private var handlers: [UInt32: HotkeyBinding] = [:]

    init(
        runtime: AutomationRuntime,
        configuration: UserConfiguration,
        configurationStore: UserConfigurationStore = UserConfigurationStore(),
        windowSwitcherController: WindowSwitcherController? = nil
    ) {
        self.runtime = runtime
        self.configuration = configuration
        self.configurationStore = configurationStore
        self.windowSwitcherController = windowSwitcherController
    }

    func start() {
        stop()
        installEventHandlerIfNeeded()

        for binding in configuration.hotkeys {
            register(binding)
        }
    }

    func stop() {
        for hotkey in registeredHotkeys {
            if let hotkey {
                UnregisterEventHotKey(hotkey)
            }
        }
        registeredHotkeys.removeAll()
        handlers.removeAll()
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

    private func register(_ binding: HotkeyBinding) {
        guard let keyCode = keyCode(for: binding.key) else {
            showStatusWindow(title: "Hotkey Error", body: "Unsupported key in \(binding.id): \(binding.key)")
            return
        }

        let signature = Self.nextSignature
        Self.nextSignature += 1
        Self.controllers[signature] = self
        handlers[signature] = binding

        let hotkeyID = EventHotKeyID(signature: OSType(signature), id: UInt32(handlers.count))
        var hotkeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            carbonModifiers(for: binding.modifiers),
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )

        if status == noErr {
            registeredHotkeys.append(hotkeyRef)
        } else {
            handlers[signature] = nil
            Self.controllers[signature] = nil
            showStatusWindow(title: "Hotkey Error", body: "Unable to register \(binding.id): \(status)")
        }
    }

    static func handleHotkey(signature: OSType) {
        guard let controller = controllers[signature],
              let binding = controller.handlers[signature] else {
            return
        }

        controller.handle(binding)
    }

    private func handle(_ binding: HotkeyBinding) {
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
            sendCommandN()
            return
        }

        if windowSwitcherController?.focusMostRecentWindow(matching: bundleIdentifier) == true {
            return
        }
        focusApplication(path: nil, bundleIdentifier: bundleIdentifier)
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
        copySelectionToPasteboard { [weak self] selectedText in
            guard let self else {
                return
            }

            let sourceText = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sourceText.isEmpty else {
                self.showStatusWindow(title: "LLM Translate", body: "没有读取到选中文本")
                return
            }

            self.runTranslationScript(sourceText: sourceText)
        }
    }

    private func copySelectionToPasteboard(completion: @escaping @MainActor (String) -> Void) {
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
            completion(copied)
        }
    }

    private func runTranslationScript(sourceText: String) {
        let scriptURL = configurationStore.defaultDirectoryURL()
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("translate_selection.py")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [scriptURL.path]

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            input.fileHandleForWriting.write(Data(sourceText.utf8))
            try input.fileHandleForWriting.close()
        } catch {
            showStatusWindow(title: "LLM Translate", body: error.localizedDescription)
            return
        }

        process.terminationHandler = { [weak self] _ in
            let data = output.fileHandleForReading.readDataToEndOfFile()
            Task { @MainActor in
                guard let self else {
                    return
                }
                do {
                    let command = try PythonScriptBridge().decodeCommand(from: data)
                    self.runtime.handle(command)
                } catch {
                    self.showStatusWindow(title: "LLM Translate", body: error.localizedDescription)
                }
            }
        }
    }

    private func reloadConfiguration() {
        do {
            let result = try configurationStore.bootstrap()
            configuration = result.configuration
            start()
            showStatusWindow(title: "TSMacTools", body: "Configuration reloaded from \(result.configURL.path)")
        } catch {
            showStatusWindow(title: "Reload Error", body: error.localizedDescription)
        }
    }

    private func showStatusWindow(title: String, body: String) {
        runtime.handle(.showWindow(
            id: NativeWindowID("status"),
            content: NativeWindowContent(title: title, body: .plainText(body))
        ))
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
