import Foundation

public struct UserConfiguration: Equatable, Codable, Sendable {
    public var application: ApplicationSettings
    public var scripting: ScriptingSettings
    public var hotkeys: [HotkeyBinding]
    public var windowSwitcher: WindowSwitcherSettings
    public var scroll: ScrollSettings
    public var fans: FanSettings = .init()
    public var translation: TranslationSettings
    public var capture: CaptureMediaSettings = .default

    public init(
        application: ApplicationSettings,
        scripting: ScriptingSettings,
        hotkeys: [HotkeyBinding],
        windowSwitcher: WindowSwitcherSettings,
        scroll: ScrollSettings = .default,
        translation: TranslationSettings,
        capture: CaptureMediaSettings = .default
    ) {
        self.application = application
        self.scripting = scripting
        self.hotkeys = hotkeys
        self.windowSwitcher = windowSwitcher
        self.scroll = scroll
        self.translation = translation
        self.capture = capture
    }

    private enum CodingKeys: String, CodingKey {
        case application
        case scripting
        case hotkeys
        case windowSwitcher
        case scroll
        case translation
        case fans
        case capture
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.application = try container.decode(ApplicationSettings.self, forKey: .application)
        self.scripting = try container.decodeIfPresent(ScriptingSettings.self, forKey: .scripting)
            ?? ScriptingSettings(pythonPath: "/usr/bin/python3")
        self.hotkeys = try container.decode([HotkeyBinding].self, forKey: .hotkeys)
        self.windowSwitcher = try container.decode(WindowSwitcherSettings.self, forKey: .windowSwitcher)
        self.scroll = try container.decodeIfPresent(ScrollSettings.self, forKey: .scroll) ?? .default
        self.translation = try container.decode(TranslationSettings.self, forKey: .translation)
        self.fans = try container.decodeIfPresent(FanSettings.self, forKey: .fans) ?? .init()
        self.capture = try container.decodeIfPresent(CaptureMediaSettings.self, forKey: .capture) ?? .default
    }
}

public struct ApplicationSettings: Equatable, Codable, Sendable {
    public var terminalBundleIdentifier: String
    public var finderBundleIdentifier: String
    public var ignoredWindowApplicationNames: [String]

    public init(
        terminalBundleIdentifier: String,
        finderBundleIdentifier: String,
        ignoredWindowApplicationNames: [String]
    ) {
        self.terminalBundleIdentifier = terminalBundleIdentifier
        self.finderBundleIdentifier = finderBundleIdentifier
        self.ignoredWindowApplicationNames = ignoredWindowApplicationNames
    }
}

public struct ScriptingSettings: Equatable, Codable, Sendable {
    public var pythonPath: String

    public init(pythonPath: String) {
        self.pythonPath = pythonPath
    }
}

public struct HotkeyBinding: Equatable, Codable, Sendable {
    public var id: String?
    public var modifiers: [String]
    public var key: String
    /// Zero-based CG mouse button number. Buttons 3 and 4 are commonly the two side buttons.
    /// When present, this replaces the keyboard key while retaining `modifiers` as part of the
    /// mouse trigger, allowing chords such as Command + Mouse 6.
    public var mouseButton: Int?
    public var action: HotkeyAction

    public init(
        id: String? = nil,
        modifiers: [String] = [],
        key: String = "",
        mouseButton: Int? = nil,
        action: HotkeyAction
    ) {
        self.id = id
        self.modifiers = modifiers
        self.key = key
        self.mouseButton = mouseButton
        self.action = action
    }

    public var shortcut: HotkeyShortcut {
        HotkeyShortcut(modifiers: modifiers, key: key)
    }

    public var trigger: HotkeyTrigger {
        if let mouseButton {
            return .mouseButton(mouseButton, modifiers: modifiers)
        }
        return .keyboard(shortcut)
    }
}

public enum HotkeyTrigger: Hashable, Sendable {
    case keyboard(HotkeyShortcut)
    case mouse(HotkeyMouseShortcut)

    public static func mouseButton(_ button: Int, modifiers: [String] = []) -> HotkeyTrigger {
        .mouse(HotkeyMouseShortcut(button: button, modifiers: modifiers))
    }
}

public struct HotkeyMouseShortcut: Hashable, Sendable {
    public let button: Int
    public let modifiers: [String]

    public init(button: Int, modifiers: [String] = []) {
        self.button = button
        self.modifiers = HotkeyShortcut(modifiers: modifiers, key: "").modifiers
    }
}

public struct HotkeyShortcut: Hashable, Sendable {
    public let modifiers: [String]
    public let key: String

    public init(modifiers: [String], key: String) {
        self.modifiers = Array(Set(modifiers.compactMap(Self.canonicalModifier))).sorted()
        self.key = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private static func canonicalModifier(_ modifier: String) -> String? {
        switch modifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "command", "cmd": "cmd"
        case "control", "ctrl": "ctrl"
        case "option", "alt": "alt"
        case "shift": "shift"
        default: nil
        }
    }
}

/// Stable configuration representation for macOS virtual key codes. Known keys use readable
/// names while any key-down code outside the table remains representable as `KeyCode:<number>`.
/// Recording and execution share this type so adding a key never requires two independent
/// allowlists.
public struct HotkeyKey: Hashable, Sendable {
    public let code: UInt16

    public init(code: UInt16) {
        self.code = code
    }

    public init?(configurationName: String) {
        let trimmed = configurationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.uppercased()
        if normalized.hasPrefix("KEYCODE:"),
           let separator = trimmed.firstIndex(of: ":"),
           let rawCode = UInt16(trimmed[trimmed.index(after: separator)...]) {
            self.code = rawCode
            return
        }
        guard let code = Self.codesByName[normalized] else { return nil }
        self.code = code
    }

    public var configurationName: String {
        Self.namesByCode[code] ?? "KeyCode:\(code)"
    }

    public var isModifierKey: Bool {
        Self.modifierKeyCodes.contains(code)
    }

    public static var allKnownKeys: [HotkeyKey] {
        definitions.map { HotkeyKey(code: $0.0) }
    }

    private static let modifierKeyCodes: Set<UInt16> = [
        0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F
    ]

    private static let definitions: [(UInt16, String)] = [
        // ANSI letters and punctuation.
        (0x00, "A"), (0x01, "S"), (0x02, "D"), (0x03, "F"),
        (0x04, "H"), (0x05, "G"), (0x06, "Z"), (0x07, "X"),
        (0x08, "C"), (0x09, "V"), (0x0B, "B"), (0x0C, "Q"),
        (0x0D, "W"), (0x0E, "E"), (0x0F, "R"), (0x10, "Y"),
        (0x11, "T"), (0x1F, "O"), (0x20, "U"), (0x22, "I"),
        (0x23, "P"), (0x25, "L"), (0x26, "J"), (0x28, "K"),
        (0x2D, "N"), (0x2E, "M"),
        (0x0A, "ISOSection"), (0x18, "="), (0x1B, "-"),
        (0x1E, "]"), (0x21, "["), (0x27, "'"), (0x29, ";"),
        (0x2A, "\\"), (0x2B, ","), (0x2C, "/"), (0x2F, "."),
        (0x32, "`"),

        // Number row.
        (0x12, "1"), (0x13, "2"), (0x14, "3"), (0x15, "4"),
        (0x16, "6"), (0x17, "5"), (0x19, "9"), (0x1A, "7"),
        (0x1C, "8"), (0x1D, "0"),

        // Editing, modifiers and system keyboard keys.
        (0x24, "Return"), (0x30, "Tab"), (0x31, "Space"),
        (0x33, "Delete"), (0x35, "Escape"), (0x36, "RightCommand"),
        (0x37, "Command"), (0x38, "Shift"), (0x39, "CapsLock"),
        (0x3A, "Option"), (0x3B, "Control"), (0x3C, "RightShift"),
        (0x3D, "RightOption"), (0x3E, "RightControl"), (0x3F, "Function"),
        (0x48, "VolumeUp"), (0x49, "VolumeDown"), (0x4A, "Mute"),

        // Keypad.
        (0x41, "KeypadDecimal"), (0x43, "KeypadMultiply"),
        (0x45, "KeypadPlus"), (0x47, "KeypadClear"),
        (0x4B, "KeypadDivide"), (0x4C, "KeypadEnter"),
        (0x4E, "KeypadMinus"), (0x51, "KeypadEquals"),
        (0x52, "Keypad0"), (0x53, "Keypad1"), (0x54, "Keypad2"),
        (0x55, "Keypad3"), (0x56, "Keypad4"), (0x57, "Keypad5"),
        (0x58, "Keypad6"), (0x59, "Keypad7"), (0x5B, "Keypad8"),
        (0x5C, "Keypad9"),

        // Function keys.
        (0x7A, "F1"), (0x78, "F2"), (0x63, "F3"), (0x76, "F4"),
        (0x60, "F5"), (0x61, "F6"), (0x62, "F7"), (0x64, "F8"),
        (0x65, "F9"), (0x6D, "F10"), (0x67, "F11"), (0x6F, "F12"),
        (0x69, "F13"), (0x6B, "F14"), (0x71, "F15"), (0x6A, "F16"),
        (0x40, "F17"), (0x4F, "F18"), (0x50, "F19"), (0x5A, "F20"),
        (0x6E, "ContextualMenu"),

        // Navigation.
        (0x72, "Help"), (0x73, "Home"), (0x74, "PageUp"),
        (0x75, "ForwardDelete"), (0x77, "End"), (0x79, "PageDown"),
        (0x7B, "Left"), (0x7C, "Right"), (0x7D, "Down"), (0x7E, "Up"),

        // JIS-specific keys.
        (0x5D, "JISYen"), (0x5E, "JISUnderscore"),
        (0x5F, "JISKeypadComma"), (0x66, "JISEisu"), (0x68, "JISKana")
    ]

    private static let namesByCode: [UInt16: String] = {
        var result: [UInt16: String] = [:]
        for (code, name) in definitions { result[code] = name }
        return result
    }()

    private static let codesByName: [String: UInt16] = {
        var result: [String: UInt16] = [:]
        for (code, name) in definitions { result[name.uppercased()] = code }
        let aliases: [String: String] = [
            "ENTER": "RETURN", "ESC": "ESCAPE", "BACKSPACE": "DELETE",
            "UPARROW": "UP", "DOWNARROW": "DOWN",
            "LEFTARROW": "LEFT", "RIGHTARROW": "RIGHT",
            "↑": "UP", "↓": "DOWN", "←": "LEFT", "→": "RIGHT",
            "LEFTBRACKET": "[", "RIGHTBRACKET": "]"
        ]
        for (alias, canonical) in aliases {
            result[alias] = result[canonical]
        }
        return result
    }()
}

public extension UserConfiguration {
    func conflictingHotkey(
        for shortcut: HotkeyShortcut,
        excluding excludedIndex: Int? = nil
    ) -> HotkeyBinding? {
        hotkeys.enumerated().first { index, binding in
            index != excludedIndex && binding.mouseButton == nil && binding.shortcut == shortcut
        }?.element
    }

    func conflictingHotkey(
        for trigger: HotkeyTrigger,
        excluding excludedIndex: Int? = nil
    ) -> HotkeyBinding? {
        hotkeys.enumerated().first { index, binding in
            index != excludedIndex && binding.trigger == trigger
        }?.element
    }
}

public struct HotkeyAction: Equatable, Codable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case focusApplication
        case showFocusedWindowInfo
        case translateSelection
        case toggleFinder
        case toggleTerminal
        case reloadConfiguration
        case runScript
        case callInterface
        case simulateKeystroke
        case captureScreenshot
        case toggleScreenRecording
    }

    public var kind: Kind
    public var path: String?
    public var bundleIdentifier: String?
    public var nativeWindowID: String?
    public var interfaceName: String?
    public var function: String?
    public var input: String?
    public var modifiers: [String]?
    public var key: String?

    public init(
        kind: Kind,
        path: String? = nil,
        bundleIdentifier: String? = nil,
        nativeWindowID: String? = nil,
        interfaceName: String? = nil,
        function: String? = nil,
        input: String? = nil,
        modifiers: [String]? = nil,
        key: String? = nil
    ) {
        self.kind = kind
        self.path = path
        self.bundleIdentifier = bundleIdentifier
        self.nativeWindowID = nativeWindowID
        self.interfaceName = interfaceName
        self.function = function
        self.input = input
        self.modifiers = modifiers
        self.key = key
    }

    /// Covers both the typed interface and the shipped Python entrypoint so the Settings toggle
    /// has one meaning even while translation remains script-backed.
    public var isSelectedTextTranslation: Bool {
        switch kind {
        case .translateSelection:
            true
        case .callInterface:
            interfaceName == "translateSelection"
        case .runScript:
            input == "selectedText"
                && path.map { URL(fileURLWithPath: $0).lastPathComponent == "translate_selection.py" } == true
        default:
            false
        }
    }

    /// Most synthetic shortcuts release the primary key with no modifiers, matching a complete
    /// user gesture and allowing system shortcuts such as Control+Down to finish. Command+Tab is
    /// the exception: macOS requires Command on Tab's key-up to keep the app switcher active.
    public var preservesModifiersOnKeyUp: Bool {
        guard kind == .simulateKeystroke,
              key?.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Tab") == .orderedSame else {
            return false
        }
        return HotkeyShortcut(modifiers: modifiers ?? [], key: "Tab").modifiers.contains("cmd")
    }

    /// Returns non-user-facing flags that a physical event for this key would carry. Keep this as
    /// a key-semantics table rather than special-casing actions in the event executor: other keys
    /// can add their intrinsic flags here as support expands.
    public var implicitCGEventModifiers: [String] {
        guard kind == .simulateKeystroke,
              let normalizedKey = key?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() else {
            return []
        }
        // Real arrow events carry secondary Function even though users see only the arrow key.
        return ["UP", "DOWN", "LEFT", "RIGHT", "↑", "↓", "←", "→"].contains(normalizedKey)
            ? ["fn"]
            : []
    }
}

public struct WindowSwitcherSettings: Equatable, Codable, Sendable {
    public static let defaultDisplayDelay: TimeInterval = 0.15
    public static let displayDelayRange: ClosedRange<TimeInterval> = 0 ... 2

    public var enabled: Bool
    public var commandTabBehavior: String
    public var sameApplicationBehavior: String
    public var followFocusedScreen: Bool
    public var restorePreviousApplicationWhenNoWindows: Bool
    public var displayDelay: TimeInterval
    public var width: Int
    public var height: Int
    public var maxVisibleRows: Int
    public var debug: Bool

    public init(
        enabled: Bool,
        commandTabBehavior: String,
        sameApplicationBehavior: String,
        followFocusedScreen: Bool,
        restorePreviousApplicationWhenNoWindows: Bool = true,
        displayDelay: TimeInterval = WindowSwitcherSettings.defaultDisplayDelay,
        width: Int,
        height: Int,
        maxVisibleRows: Int,
        debug: Bool = false
    ) {
        self.enabled = enabled
        self.commandTabBehavior = commandTabBehavior
        self.sameApplicationBehavior = sameApplicationBehavior
        self.followFocusedScreen = followFocusedScreen
        self.restorePreviousApplicationWhenNoWindows = restorePreviousApplicationWhenNoWindows
        self.displayDelay = displayDelay
        self.width = width
        self.height = height
        self.maxVisibleRows = maxVisibleRows
        self.debug = debug
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case commandTabBehavior
        case sameApplicationBehavior
        case followFocusedScreen
        case restorePreviousApplicationWhenNoWindows
        case displayDelay
        case width
        case height
        case maxVisibleRows
        case debug
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decode(Bool.self, forKey: .enabled)
        self.commandTabBehavior = try container.decode(String.self, forKey: .commandTabBehavior)
        self.sameApplicationBehavior = try container.decode(String.self, forKey: .sameApplicationBehavior)
        self.followFocusedScreen = try container.decode(Bool.self, forKey: .followFocusedScreen)
        self.restorePreviousApplicationWhenNoWindows = try container.decodeIfPresent(
            Bool.self,
            forKey: .restorePreviousApplicationWhenNoWindows
        ) ?? true
        self.displayDelay = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .displayDelay
        ) ?? Self.defaultDisplayDelay
        self.width = try container.decode(Int.self, forKey: .width)
        self.height = try container.decode(Int.self, forKey: .height)
        self.maxVisibleRows = try container.decode(Int.self, forKey: .maxVisibleRows)
        self.debug = try container.decodeIfPresent(Bool.self, forKey: .debug) ?? false
    }

    public var effectiveDisplayDelay: TimeInterval {
        min(max(displayDelay, Self.displayDelayRange.lowerBound), Self.displayDelayRange.upperBound)
    }
}

public struct TranslationSettings: Equatable, Codable, Sendable {
    public var enabled: Bool
    public var provider: String
    public var endpoint: String
    public var apiKey: String
    public var googleEndpoint: String
    public var googleApiKey: String
    public var googleSourceLanguage: String
    public var googleTargetLanguage: String
    public var googleTargetLanguageForChinese: String
    public var googleWebEndpoint: String
    public var googleWebClient: String
    public var model: String
    public var thinkingEnabled: Bool
    /// Selected reasoning effort from `/v1/models` (`none`, `low`, `high`, …). Empty means derive from `thinkingEnabled`.
    public var thinkingLevel: String
    /// Request-shape adapter: `reasoning` (OpenAI-compatible effort object), `include_reasoning`, `enable_thinking`, `reasoning_format`, or `none`.
    public var thinkingParameter: String
    public var contextWindowTokens: Int
    public var outputTokenLimit: Int
    public var requestTokenLimit: Int
    public var temperature: Double
    public var promptTemplate: String
    public var systemPrompt: String
    public var copyKeystrokeDelay: Double
    public var normalizePDFLineBreaks: Bool
    public var nativeWindow: TranslationWindowSettings

    public init(
        enabled: Bool,
        provider: String = "llm",
        endpoint: String,
        apiKey: String,
        googleEndpoint: String = "https://translation.googleapis.com/language/translate/v2",
        googleApiKey: String = "",
        googleSourceLanguage: String = "auto",
        googleTargetLanguage: String = "zh-CN",
        googleTargetLanguageForChinese: String = "en",
        googleWebEndpoint: String = "https://translate.googleapis.com/translate_a/single",
        googleWebClient: String = "gtx",
        model: String,
        thinkingEnabled: Bool = false,
        thinkingLevel: String = "",
        thinkingParameter: String = "reasoning",
        contextWindowTokens: Int = 262144,
        outputTokenLimit: Int = 2048,
        requestTokenLimit: Int = 0,
        temperature: Double,
        promptTemplate: String,
        systemPrompt: String,
        copyKeystrokeDelay: Double,
        normalizePDFLineBreaks: Bool = true,
        nativeWindow: TranslationWindowSettings
    ) {
        self.enabled = enabled
        self.provider = provider
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.googleEndpoint = googleEndpoint
        self.googleApiKey = googleApiKey
        self.googleSourceLanguage = googleSourceLanguage
        self.googleTargetLanguage = googleTargetLanguage
        self.googleTargetLanguageForChinese = googleTargetLanguageForChinese
        self.googleWebEndpoint = googleWebEndpoint
        self.googleWebClient = googleWebClient
        self.model = model
        self.thinkingEnabled = thinkingEnabled
        self.thinkingLevel = thinkingLevel
        self.thinkingParameter = thinkingParameter
        self.contextWindowTokens = contextWindowTokens
        self.outputTokenLimit = outputTokenLimit
        self.requestTokenLimit = requestTokenLimit
        self.temperature = temperature
        self.promptTemplate = promptTemplate
        self.systemPrompt = systemPrompt
        self.copyKeystrokeDelay = copyKeystrokeDelay
        self.normalizePDFLineBreaks = normalizePDFLineBreaks
        self.nativeWindow = nativeWindow
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case provider
        case endpoint
        case apiKey
        case googleEndpoint
        case googleApiKey
        case googleSourceLanguage
        case googleTargetLanguage
        case googleTargetLanguageForChinese
        case googleWebEndpoint
        case googleWebClient
        case model
        case thinkingEnabled
        case thinkingLevel
        case thinkingParameter
        case contextWindowTokens
        case outputTokenLimit
        case requestTokenLimit
        case temperature
        case promptTemplate
        case systemPrompt
        case copyKeystrokeDelay
        case normalizePDFLineBreaks
        case nativeWindow
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decode(Bool.self, forKey: .enabled)
        self.provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? "llm"
        self.endpoint = try container.decode(String.self, forKey: .endpoint)
        self.apiKey = try container.decode(String.self, forKey: .apiKey)
        self.googleEndpoint = try container.decodeIfPresent(String.self, forKey: .googleEndpoint) ?? "https://translation.googleapis.com/language/translate/v2"
        self.googleApiKey = try container.decodeIfPresent(String.self, forKey: .googleApiKey) ?? ""
        self.googleSourceLanguage = try container.decodeIfPresent(String.self, forKey: .googleSourceLanguage) ?? "auto"
        self.googleTargetLanguage = try container.decodeIfPresent(String.self, forKey: .googleTargetLanguage) ?? "zh-CN"
        self.googleTargetLanguageForChinese = try container.decodeIfPresent(String.self, forKey: .googleTargetLanguageForChinese) ?? "en"
        self.googleWebEndpoint = try container.decodeIfPresent(String.self, forKey: .googleWebEndpoint) ?? "https://translate.googleapis.com/translate_a/single"
        self.googleWebClient = try container.decodeIfPresent(String.self, forKey: .googleWebClient) ?? "gtx"
        self.model = try container.decode(String.self, forKey: .model)
        self.thinkingEnabled = try container.decodeIfPresent(Bool.self, forKey: .thinkingEnabled) ?? false
        self.thinkingLevel = try container.decodeIfPresent(String.self, forKey: .thinkingLevel) ?? ""
        self.thinkingParameter = try container.decodeIfPresent(String.self, forKey: .thinkingParameter) ?? "reasoning"
        self.contextWindowTokens = try container.decodeIfPresent(Int.self, forKey: .contextWindowTokens) ?? 262144
        self.outputTokenLimit = try container.decodeIfPresent(Int.self, forKey: .outputTokenLimit) ?? 2048
        self.requestTokenLimit = try container.decodeIfPresent(Int.self, forKey: .requestTokenLimit) ?? 0
        self.temperature = try container.decode(Double.self, forKey: .temperature)
        self.promptTemplate = try container.decode(String.self, forKey: .promptTemplate)
        self.systemPrompt = try container.decode(String.self, forKey: .systemPrompt)
        self.copyKeystrokeDelay = try container.decode(Double.self, forKey: .copyKeystrokeDelay)
        self.normalizePDFLineBreaks = try container.decodeIfPresent(Bool.self, forKey: .normalizePDFLineBreaks) ?? true
        self.nativeWindow = try container.decode(TranslationWindowSettings.self, forKey: .nativeWindow)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(provider, forKey: .provider)
        try container.encode(endpoint, forKey: .endpoint)
        try container.encode(apiKey, forKey: .apiKey)
        if googleEndpoint != "https://translation.googleapis.com/language/translate/v2" {
            try container.encode(googleEndpoint, forKey: .googleEndpoint)
        }
        try container.encode(googleApiKey, forKey: .googleApiKey)
        try container.encode(googleSourceLanguage, forKey: .googleSourceLanguage)
        try container.encode(googleTargetLanguage, forKey: .googleTargetLanguage)
        try container.encode(googleTargetLanguageForChinese, forKey: .googleTargetLanguageForChinese)
        if googleWebEndpoint != "https://translate.googleapis.com/translate_a/single" {
            try container.encode(googleWebEndpoint, forKey: .googleWebEndpoint)
        }
        if googleWebClient != "gtx" {
            try container.encode(googleWebClient, forKey: .googleWebClient)
        }
        try container.encode(model, forKey: .model)
        try container.encode(thinkingEnabled, forKey: .thinkingEnabled)
        try container.encode(thinkingLevel, forKey: .thinkingLevel)
        try container.encode(thinkingParameter, forKey: .thinkingParameter)
        try container.encode(contextWindowTokens, forKey: .contextWindowTokens)
        try container.encode(outputTokenLimit, forKey: .outputTokenLimit)
        try container.encode(requestTokenLimit, forKey: .requestTokenLimit)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(promptTemplate, forKey: .promptTemplate)
        try container.encode(systemPrompt, forKey: .systemPrompt)
        try container.encode(copyKeystrokeDelay, forKey: .copyKeystrokeDelay)
        try container.encode(normalizePDFLineBreaks, forKey: .normalizePDFLineBreaks)
        try container.encode(nativeWindow, forKey: .nativeWindow)
    }
}

public struct TranslationWindowSettings: Equatable, Codable, Sendable {
    public var id: String
    public var title: String
    public var format: String
    public var width: Int
    public var height: Int
    public var pinByDefault: Bool

    public init(
        id: String,
        title: String,
        format: String,
        width: Int,
        height: Int,
        pinByDefault: Bool
    ) {
        self.id = id
        self.title = title
        self.format = format
        self.width = width
        self.height = height
        self.pinByDefault = pinByDefault
    }
}

public extension UserConfiguration {
    static let defaultDirectoryName = "tsmactool"
    static let defaultFileName = "config.jsonc"

    static func migratedHammerspoonDefault(apiKey: String = "") -> UserConfiguration {
        UserConfiguration(
            application: ApplicationSettings(
                terminalBundleIdentifier: "net.kovidgoyal.kitty",
                finderBundleIdentifier: "com.apple.finder",
                ignoredWindowApplicationNames: [
                    "Dock",
                    "SystemUIServer",
                    "Window Server"
                ]
            ),
            scripting: ScriptingSettings(pythonPath: "/usr/bin/python3"),
            hotkeys: [
                HotkeyBinding(modifiers: ["ctrl", "cmd"], key: ".", action: HotkeyAction(kind: .callInterface, interfaceName: "focusedWindowInfo")),
                HotkeyBinding(modifiers: ["alt"], key: "W", action: HotkeyAction(kind: .focusApplication, path: "/Applications/WeChat.app")),
                HotkeyBinding(modifiers: ["alt"], key: "O", action: HotkeyAction(kind: .focusApplication, path: "/Applications/Discord.app")),
                HotkeyBinding(modifiers: ["alt"], key: "F", action: HotkeyAction(kind: .focusApplication, path: "/Applications/Lark.app")),
                HotkeyBinding(modifiers: ["alt"], key: "C", action: HotkeyAction(kind: .focusApplication, path: "/Applications/Google Chrome.app")),
                HotkeyBinding(modifiers: ["alt"], key: "R", action: HotkeyAction(kind: .focusApplication, path: "/Applications/SiYuan.app")),
                HotkeyBinding(modifiers: ["alt"], key: "M", action: HotkeyAction(kind: .focusApplication, path: "/Applications/Microsoft Outlook.app")),
                HotkeyBinding(modifiers: ["alt"], key: "Q", action: HotkeyAction(kind: .focusApplication, path: "/Applications/QQ.app")),
                HotkeyBinding(modifiers: ["alt"], key: "V", action: HotkeyAction(kind: .focusApplication, path: "/Applications/Visual Studio Code.app")),
                HotkeyBinding(modifiers: ["alt"], key: "Z", action: HotkeyAction(kind: .focusApplication, path: "/Applications/Zotero.app")),
                HotkeyBinding(modifiers: ["alt"], key: "X", action: HotkeyAction(kind: .focusApplication, path: "/Applications/Cherry Studio.app")),
                HotkeyBinding(modifiers: ["alt"], key: "S", action: HotkeyAction(kind: .runScript, path: "scripts/translate_selection.py", nativeWindowID: "translate", function: "main", input: "selectedText")),
                HotkeyBinding(modifiers: ["alt"], key: "E", action: HotkeyAction(kind: .toggleFinder, bundleIdentifier: "com.apple.finder")),
                HotkeyBinding(modifiers: ["cmd"], key: "D", action: HotkeyAction(kind: .toggleTerminal, bundleIdentifier: "net.kovidgoyal.kitty")),
                HotkeyBinding(modifiers: ["cmd", "alt", "ctrl"], key: "R", action: HotkeyAction(kind: .callInterface, interfaceName: "reloadConfiguration")),
                HotkeyBinding(modifiers: ["alt"], key: "P", action: HotkeyAction(kind: .captureScreenshot)),
                HotkeyBinding(modifiers: ["alt"], key: "G", action: HotkeyAction(kind: .toggleScreenRecording))
            ],
            windowSwitcher: WindowSwitcherSettings(
                enabled: true,
                commandTabBehavior: "most-recent-window",
                sameApplicationBehavior: "cycle-same-application-windows",
                followFocusedScreen: true,
                restorePreviousApplicationWhenNoWindows: true,
                width: 760,
                height: 420,
                maxVisibleRows: 9,
                debug: false
            ),
            scroll: .default,
            translation: TranslationSettings(
                enabled: true,
                provider: "google_web",
                endpoint: "http://127.0.0.1:8787/v1/chat/completions",
                apiKey: apiKey,
                googleEndpoint: "https://translation.googleapis.com/language/translate/v2",
                googleApiKey: "",
                googleSourceLanguage: "auto",
                googleTargetLanguage: "zh-CN",
                googleTargetLanguageForChinese: "en",
                googleWebEndpoint: "https://translate.googleapis.com/translate_a/single",
                googleWebClient: "gtx",
                model: "qwen/qwen3.6-27b",
                thinkingEnabled: false,
                thinkingLevel: "none",
                thinkingParameter: "reasoning",
                contextWindowTokens: 262144,
                outputTokenLimit: 2048,
                requestTokenLimit: 0,
                temperature: 0.2,
                promptTemplate: """
                You are a professional English translator with strong knowledge of computing terms.
                If the source text is Chinese, translate it into natural English.
                If the source text is English or another language, translate it into Chinese.
                Briefly state the source and target languages, then leave two blank lines and provide only the translation.
                Do not add, remove, summarize, or omit any content.

                ---

                {{sourceText}}
                """,
                systemPrompt: "",
                copyKeystrokeDelay: 0.18,
                normalizePDFLineBreaks: true,
                nativeWindow: TranslationWindowSettings(
                    id: "translate",
                    title: "LLM Translate",
                    format: "markdown",
                    width: 720,
                    height: 620,
                    pinByDefault: false
                )
            ),
            capture: .default
        )
    }
}

public struct FanCurvePoint: Codable, Equatable, Sendable {
    public var temperature: Double
    public var percent: Double
    /// Cubic Bezier easing control ordinates; abscissae are 1/3 and 2/3.
    public var outgoing: Double = 0.33
    public var incoming: Double = 0.67
    public init(temperature: Double, percent: Double) {
        self.temperature = temperature; self.percent = percent
    }
}

public struct FanRule: Codable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var enabled: Bool = true
    private enum CodingKeys: String, CodingKey { case id, enabled, sensor, fan, points }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llx", UInt64(decoder.codingPath.last?.intValue ?? 0)))!
        sensor = try values.decode(String.self, forKey: .sensor)
        fan = try values.decode(Int.self, forKey: .fan)
        points = try values.decode([FanCurvePoint].self, forKey: .points)
    }
    public var sensor: String
    public var fan: Int
    public var points: [FanCurvePoint]
    public init(sensor: String = "CPU", fan: Int = 0, points: [FanCurvePoint] = [
        .init(temperature: 40, percent: 25), .init(temperature: 65, percent: 55), .init(temperature: 85, percent: 100)
    ]) { self.sensor = sensor; self.fan = fan; self.points = points }

    public func demand(at temperature: Double) -> Double? {
        guard temperature.isFinite, points.count >= 2,
              points.allSatisfy({ $0.temperature.isFinite && $0.percent.isFinite && (0...100).contains($0.percent) && (0...1).contains($0.outgoing) && (0...1).contains($0.incoming) }),
              zip(points, points.dropFirst()).allSatisfy({ $0.temperature < $1.temperature && $0.percent <= $1.percent }) else { return nil }
        if temperature <= points[0].temperature { return points[0].percent }
        for (a, b) in zip(points, points.dropFirst()) where temperature <= b.temperature {
            let t = (temperature - a.temperature) / (b.temperature - a.temperature), u = 1 - t
            let easing = 3*u*u*t*a.outgoing + 3*u*t*t*b.incoming + t*t*t
            return a.percent + (b.percent - a.percent) * easing
        }
        return points.last?.percent
    }
}

public struct FanSettings: Codable, Equatable, Sendable {
    public var enabled = false
    private enum CodingKeys: String, CodingKey { case enabled, rules }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        rules = try values.decodeIfPresent([FanRule].self, forKey: .rules) ?? []
    }

    public var rules: [FanRule] = []
    public init() {}
    public func activeDemands(readings: [String: Double], now: Date, sampleDate: Date) -> [Int: Double]? {
        let age = now.timeIntervalSince(sampleDate)
        guard enabled, age >= 0, age <= 3 else { return nil }
        return demands(readings: readings)
    }
    public var duplicateFanIDs: [Int] {
        Dictionary(grouping: rules, by: \.fan).filter { $0.value.count > 1 }.keys.sorted()
    }
    /// Ambiguous legacy assignments restore automatic control until explicitly resolved.

    public func demands(readings: [String: Double]) -> [Int: Double]? {
        guard duplicateFanIDs.isEmpty else { return nil }
        var output: [Int: Double] = [:]
        for rule in rules where rule.enabled {
            guard rule.fan >= 0, let reading = readings[rule.sensor], let value = rule.demand(at: reading) else { return nil }
            output[rule.fan] = max(output[rule.fan] ?? 0, value)
        }
        return output
    }
}

/// A privileged adapter must enforce lease expiry independently of the UI process.
/// The live XPC adapter uses helper-serialized complete batches; this boundary supports deterministic policy tests.
public protocol FanHardwareBoundary {
    var supportsLeasedControl: Bool { get }
    mutating func setDemand(_ percent: Double, fan: Int, leaseUntil: Date) throws
    mutating func restoreAutomatic() throws
}

public struct FanControlSession<Hardware: FanHardwareBoundary> {
    public private(set) var hardware: Hardware
    private var activeFans = Set<Int>()
    public init(hardware: Hardware) { self.hardware = hardware }
    public mutating func update(settings: FanSettings, readings: [String: Double], now: Date, sampleDate: Date) throws {
        guard hardware.supportsLeasedControl, now.timeIntervalSince(sampleDate) >= 0,
              now.timeIntervalSince(sampleDate) <= 3, let demands = settings.demands(readings: readings), !demands.isEmpty else {
            try hardware.restoreAutomatic(); activeFans = []; return
        }
        do {
            if !activeFans.subtracting(demands.keys).isEmpty { try hardware.restoreAutomatic() }
            for (fan, percent) in demands { try hardware.setDemand(percent, fan: fan, leaseUntil: now.addingTimeInterval(5)) }
            activeFans = Set(demands.keys)
        } catch { try? hardware.restoreAutomatic(); activeFans = []; throw error }
    }
    public mutating func stop() throws { try hardware.restoreAutomatic(); activeFans = [] }
}

/// Converts the General pane's base URL into the full request URL consumed by Python.
public enum TranslationEndpoint {
    public enum InvalidURL: LocalizedError {
        case invalid
        public var errorDescription: String? { "Base URL must be an absolute HTTP or HTTPS URL with a host." }
    }

    public static func requestURL(_ input: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: trimmed),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty,
              parts.url != nil else { throw InvalidURL.invalid }
        let path = parts.percentEncodedPath
        let clean = path.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        // Existing full endpoint values retain their exact path, trailing slash and query.
        if clean.hasSuffix("/chat/completions") { return trimmed }
        parts.percentEncodedPath = clean.isEmpty ? "/v1/chat/completions" : clean + "/chat/completions"
        guard let result = parts.url?.absoluteString else { throw InvalidURL.invalid }
        return result
    }

    public static func baseURL(_ endpoint: String) -> String {
        guard var parts = URLComponents(string: endpoint) else { return endpoint }
        // Query-bearing or trailing-slash endpoints stay verbatim to preserve custom semantics.
        guard parts.percentEncodedQuery == nil, parts.fragment == nil,
              parts.percentEncodedPath.hasSuffix("/chat/completions") else { return endpoint }
        parts.percentEncodedPath.removeLast("/chat/completions".count)
        // A root-level custom endpoint would otherwise acquire an unwanted /v1 on save.
        guard !parts.percentEncodedPath.isEmpty else { return endpoint }
        return parts.string ?? endpoint
    }

    /// Derives the OpenAI-compatible `/models` discovery URL from a chat-completions endpoint.
    public static func modelsURL(from endpoint: String) -> String? {
        guard var parts = URLComponents(string: endpoint),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty else { return nil }
        let path = parts.percentEncodedPath.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        if path.hasSuffix("/chat/completions") {
            parts.percentEncodedPath = String(path.dropLast("/chat/completions".count)) + "/models"
        } else if path.hasSuffix("/v1") || path.hasSuffix("/openai/v1") {
            parts.percentEncodedPath = path + "/models"
        } else if path.isEmpty {
            parts.percentEncodedPath = "/v1/models"
        } else if path.hasSuffix("/models") {
            parts.percentEncodedPath = path
        } else {
            parts.percentEncodedPath = path + "/models"
        }
        parts.percentEncodedQuery = nil
        parts.fragment = nil
        return parts.string
    }
}

public struct LLMModelDescriptor: Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var reasoning: Bool
    public var reasoningLevels: [String]
    public var supportedParameters: [String]
    public var nativeEndpoints: [String]
    public var contextWindowTokens: Int?
    public var maxOutputTokens: Int?

    public init(
        id: String,
        displayName: String,
        reasoning: Bool,
        reasoningLevels: [String],
        supportedParameters: [String] = [],
        nativeEndpoints: [String] = [],
        contextWindowTokens: Int? = nil,
        maxOutputTokens: Int? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.reasoning = reasoning
        self.reasoningLevels = reasoningLevels
        self.supportedParameters = supportedParameters
        self.nativeEndpoints = nativeEndpoints
        self.contextWindowTokens = contextWindowTokens
        self.maxOutputTokens = maxOutputTokens
    }

    public var supportsChatCompletions: Bool {
        guard !nativeEndpoints.isEmpty else { return true }
        return nativeEndpoints.contains { endpoint in
            endpoint == "/v1/chat/completions" || endpoint.hasSuffix("/chat/completions")
        }
    }

    public var supportsReasoningParameter: Bool {
        supportedParameters.contains("reasoning") || reasoning
    }

    public var menuTitle: String {
        if displayName.isEmpty || displayName == id { return id }
        return "\(displayName) · \(id)"
    }
}

public enum LLMModelCatalog {
    public enum ParseError: LocalizedError {
        case invalidPayload
        public var errorDescription: String? { "The /v1/models response was not a recognizable model list." }
    }

    public static func parse(_ data: Data) throws -> [LLMModelDescriptor] {
        let object = try JSONSerialization.jsonObject(with: data)
        let items: [[String: Any]]
        if let root = object as? [String: Any] {
            if let dataItems = root["data"] as? [[String: Any]] {
                items = dataItems
            } else if let models = root["models"] as? [[String: Any]] {
                items = models
            } else {
                throw ParseError.invalidPayload
            }
        } else if let array = object as? [[String: Any]] {
            items = array
        } else {
            throw ParseError.invalidPayload
        }

        return items.compactMap { item in
            guard let id = stringValue(item["id"])?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
                return nil
            }
            let displayName = stringValue(item["display_name"])
                ?? stringValue(item["name"])
                ?? stringValue(item["magpie_label"])
                ?? id
            let levels = reasoningLevels(from: item)
            let parameters = stringArray(item["supported_parameters"])
            let endpoints = stringArray(item["native_endpoints"])
            let reasoning = boolValue(item["reasoning"]) ?? (!levels.isEmpty || parameters.contains("reasoning"))
            return LLMModelDescriptor(
                id: id,
                displayName: displayName,
                reasoning: reasoning,
                reasoningLevels: levels,
                supportedParameters: parameters,
                nativeEndpoints: endpoints,
                contextWindowTokens: intValue(item["context_window"]) ?? intValue(item["context_length"]) ?? intValue(item["max_input_tokens"]),
                maxOutputTokens: intValue(item["max_output_tokens"])
            )
        }
    }

    public static func chatCompletionModels(in models: [LLMModelDescriptor]) -> [LLMModelDescriptor] {
        models.filter(\.supportsChatCompletions)
    }

    private static func reasoningLevels(from item: [String: Any]) -> [String] {
        var levels: [String] = []
        if let values = item["reasoning_levels"] as? [Any] {
            levels.append(contentsOf: values.compactMap(stringValue).map { $0.lowercased() })
        }
        if let values = item["supported_reasoning_levels"] as? [[String: Any]] {
            for value in values {
                if let effort = stringValue(value["effort"]) {
                    levels.append(effort.lowercased())
                }
            }
        }
        var seen = Set<String>()
        return levels.filter { seen.insert($0).inserted }
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private static func stringArray(_ value: Any?) -> [String] {
        guard let values = value as? [Any] else { return [] }
        return values.compactMap(stringValue)
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let flag as Bool:
            return flag
        case let number as NSNumber:
            return number.boolValue
        default:
            return nil
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as Int:
            return number
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }
}

public enum TranslationThinking {
    public static func normalizedLevel(
        thinkingLevel: String,
        thinkingEnabled: Bool,
        availableLevels: [String] = []
    ) -> String {
        let trimmed = thinkingLevel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !trimmed.isEmpty {
            return trimmed == "off" ? "none" : trimmed
        }
        if thinkingEnabled {
            let preferred = availableLevels.first { $0 != "none" && $0 != "off" } ?? "high"
            return preferred
        }
        if availableLevels.contains("none") { return "none" }
        return "none"
    }

    public static func isEnabled(level: String) -> Bool {
        let normalized = level.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !(normalized.isEmpty || normalized == "none" || normalized == "off")
    }
}

public enum TranslationTokenBudget {
    public struct Values: Equatable, Sendable {
        public var contextWindowTokens: Int
        public var outputTokenLimit: Int
        /// Service-tier request clamp. `0` disables the clamp once budgets come from `/v1/models`.
        public var requestTokenLimit: Int

        public init(contextWindowTokens: Int, outputTokenLimit: Int, requestTokenLimit: Int) {
            self.contextWindowTokens = contextWindowTokens
            self.outputTokenLimit = outputTokenLimit
            self.requestTokenLimit = requestTokenLimit
        }

        public var summary: String {
            let output = outputTokenLimit > 0 ? "\(outputTokenLimit)" : "unknown"
            let request = requestTokenLimit > 0 ? "\(requestTokenLimit)" : "off"
            return "context \(contextWindowTokens) · output \(output) · request \(request)"
        }
    }

    /// Derives translation budgets exclusively from `/v1/models` metadata.
    public static func derived(from model: LLMModelDescriptor) -> Values? {
        guard let context = model.contextWindowTokens, context > 0 else { return nil }
        let output: Int
        if let advertised = model.maxOutputTokens, advertised > 0 {
            output = advertised
        } else {
            output = min(8192, max(2048, context / 32))
        }
        return Values(
            contextWindowTokens: context,
            outputTokenLimit: output,
            requestTokenLimit: 0
        )
    }
}
