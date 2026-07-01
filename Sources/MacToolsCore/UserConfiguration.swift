import Foundation

public struct UserConfiguration: Equatable, Codable, Sendable {
    public var application: ApplicationSettings
    public var scripting: ScriptingSettings
    public var hotkeys: [HotkeyBinding]
    public var windowSwitcher: WindowSwitcherSettings
    public var translation: TranslationSettings

    public init(
        application: ApplicationSettings,
        scripting: ScriptingSettings,
        hotkeys: [HotkeyBinding],
        windowSwitcher: WindowSwitcherSettings,
        translation: TranslationSettings
    ) {
        self.application = application
        self.scripting = scripting
        self.hotkeys = hotkeys
        self.windowSwitcher = windowSwitcher
        self.translation = translation
    }

    private enum CodingKeys: String, CodingKey {
        case application
        case scripting
        case hotkeys
        case windowSwitcher
        case translation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.application = try container.decode(ApplicationSettings.self, forKey: .application)
        self.scripting = try container.decodeIfPresent(ScriptingSettings.self, forKey: .scripting)
            ?? ScriptingSettings(pythonPath: "/usr/bin/python3")
        self.hotkeys = try container.decode([HotkeyBinding].self, forKey: .hotkeys)
        self.windowSwitcher = try container.decode(WindowSwitcherSettings.self, forKey: .windowSwitcher)
        self.translation = try container.decode(TranslationSettings.self, forKey: .translation)
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
    public var action: HotkeyAction

    public init(id: String? = nil, modifiers: [String], key: String, action: HotkeyAction) {
        self.id = id
        self.modifiers = modifiers
        self.key = key
        self.action = action
    }
}

public struct HotkeyAction: Equatable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case focusApplication
        case showFocusedWindowInfo
        case translateSelection
        case toggleFinder
        case toggleTerminal
        case reloadConfiguration
        case runScript
        case callInterface
    }

    public var kind: Kind
    public var path: String?
    public var bundleIdentifier: String?
    public var nativeWindowID: String?
    public var interfaceName: String?
    public var function: String?
    public var input: String?

    public init(
        kind: Kind,
        path: String? = nil,
        bundleIdentifier: String? = nil,
        nativeWindowID: String? = nil,
        interfaceName: String? = nil,
        function: String? = nil,
        input: String? = nil
    ) {
        self.kind = kind
        self.path = path
        self.bundleIdentifier = bundleIdentifier
        self.nativeWindowID = nativeWindowID
        self.interfaceName = interfaceName
        self.function = function
        self.input = input
    }
}

public struct WindowSwitcherSettings: Equatable, Codable, Sendable {
    public var enabled: Bool
    public var commandTabBehavior: String
    public var sameApplicationBehavior: String
    public var followFocusedScreen: Bool
    public var width: Int
    public var height: Int
    public var maxVisibleRows: Int
    public var debug: Bool

    public init(
        enabled: Bool,
        commandTabBehavior: String,
        sameApplicationBehavior: String,
        followFocusedScreen: Bool,
        width: Int,
        height: Int,
        maxVisibleRows: Int,
        debug: Bool = false
    ) {
        self.enabled = enabled
        self.commandTabBehavior = commandTabBehavior
        self.sameApplicationBehavior = sameApplicationBehavior
        self.followFocusedScreen = followFocusedScreen
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
        self.width = try container.decode(Int.self, forKey: .width)
        self.height = try container.decode(Int.self, forKey: .height)
        self.maxVisibleRows = try container.decode(Int.self, forKey: .maxVisibleRows)
        self.debug = try container.decodeIfPresent(Bool.self, forKey: .debug) ?? false
    }
}

public struct TranslationSettings: Equatable, Codable, Sendable {
    public var enabled: Bool
    public var endpoint: String
    public var apiKey: String
    public var model: String
    public var thinkingEnabled: Bool
    public var thinkingParameter: String
    public var contextWindowTokens: Int
    public var outputTokenLimit: Int
    public var temperature: Double
    public var promptTemplate: String
    public var systemPrompt: String
    public var copyKeystrokeDelay: Double
    public var nativeWindow: TranslationWindowSettings

    public init(
        enabled: Bool,
        endpoint: String,
        apiKey: String,
        model: String,
        thinkingEnabled: Bool = false,
        thinkingParameter: String = "include_reasoning",
        contextWindowTokens: Int = 262144,
        outputTokenLimit: Int = 65536,
        temperature: Double,
        promptTemplate: String,
        systemPrompt: String,
        copyKeystrokeDelay: Double,
        nativeWindow: TranslationWindowSettings
    ) {
        self.enabled = enabled
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.thinkingEnabled = thinkingEnabled
        self.thinkingParameter = thinkingParameter
        self.contextWindowTokens = contextWindowTokens
        self.outputTokenLimit = outputTokenLimit
        self.temperature = temperature
        self.promptTemplate = promptTemplate
        self.systemPrompt = systemPrompt
        self.copyKeystrokeDelay = copyKeystrokeDelay
        self.nativeWindow = nativeWindow
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case endpoint
        case apiKey
        case model
        case thinkingEnabled
        case thinkingParameter
        case contextWindowTokens
        case outputTokenLimit
        case temperature
        case promptTemplate
        case systemPrompt
        case copyKeystrokeDelay
        case nativeWindow
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decode(Bool.self, forKey: .enabled)
        self.endpoint = try container.decode(String.self, forKey: .endpoint)
        self.apiKey = try container.decode(String.self, forKey: .apiKey)
        self.model = try container.decode(String.self, forKey: .model)
        self.thinkingEnabled = try container.decodeIfPresent(Bool.self, forKey: .thinkingEnabled) ?? false
        self.thinkingParameter = try container.decodeIfPresent(String.self, forKey: .thinkingParameter) ?? "include_reasoning"
        self.contextWindowTokens = try container.decodeIfPresent(Int.self, forKey: .contextWindowTokens) ?? 262144
        self.outputTokenLimit = try container.decodeIfPresent(Int.self, forKey: .outputTokenLimit) ?? 65536
        self.temperature = try container.decode(Double.self, forKey: .temperature)
        self.promptTemplate = try container.decode(String.self, forKey: .promptTemplate)
        self.systemPrompt = try container.decode(String.self, forKey: .systemPrompt)
        self.copyKeystrokeDelay = try container.decode(Double.self, forKey: .copyKeystrokeDelay)
        self.nativeWindow = try container.decode(TranslationWindowSettings.self, forKey: .nativeWindow)
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
                HotkeyBinding(modifiers: ["cmd", "alt", "ctrl"], key: "R", action: HotkeyAction(kind: .callInterface, interfaceName: "reloadConfiguration"))
            ],
            windowSwitcher: WindowSwitcherSettings(
                enabled: true,
                commandTabBehavior: "most-recent-window",
                sameApplicationBehavior: "cycle-same-application-windows",
                followFocusedScreen: true,
                width: 760,
                height: 420,
                maxVisibleRows: 9,
                debug: false
            ),
            translation: TranslationSettings(
                enabled: true,
                endpoint: "http://127.0.0.1:8787/v1/chat/completions",
                apiKey: apiKey,
                model: "qwen/qwen3.6-27b",
                thinkingEnabled: false,
                thinkingParameter: "include_reasoning",
                contextWindowTokens: 262144,
                outputTokenLimit: 65536,
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
                nativeWindow: TranslationWindowSettings(
                    id: "translate",
                    title: "LLM Translate",
                    format: "markdown",
                    width: 720,
                    height: 620,
                    pinByDefault: false
                )
            )
        )
    }
}
