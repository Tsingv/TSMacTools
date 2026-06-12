import Foundation

public struct UserConfiguration: Equatable, Codable, Sendable {
    public var version: Int
    public var application: ApplicationSettings
    public var hotkeys: [HotkeyBinding]
    public var windowSwitcher: WindowSwitcherSettings
    public var translation: TranslationSettings

    public init(
        version: Int,
        application: ApplicationSettings,
        hotkeys: [HotkeyBinding],
        windowSwitcher: WindowSwitcherSettings,
        translation: TranslationSettings
    ) {
        self.version = version
        self.application = application
        self.hotkeys = hotkeys
        self.windowSwitcher = windowSwitcher
        self.translation = translation
    }
}

public struct ApplicationSettings: Equatable, Codable, Sendable {
    public var name: String
    public var configDirectoryName: String
    public var terminalBundleIdentifier: String
    public var finderBundleIdentifier: String
    public var ignoredWindowApplicationNames: [String]

    public init(
        name: String,
        configDirectoryName: String,
        terminalBundleIdentifier: String,
        finderBundleIdentifier: String,
        ignoredWindowApplicationNames: [String]
    ) {
        self.name = name
        self.configDirectoryName = configDirectoryName
        self.terminalBundleIdentifier = terminalBundleIdentifier
        self.finderBundleIdentifier = finderBundleIdentifier
        self.ignoredWindowApplicationNames = ignoredWindowApplicationNames
    }
}

public struct HotkeyBinding: Equatable, Codable, Sendable {
    public var id: String
    public var modifiers: [String]
    public var key: String
    public var action: HotkeyAction

    public init(id: String, modifiers: [String], key: String, action: HotkeyAction) {
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
    }

    public var kind: Kind
    public var path: String?
    public var bundleIdentifier: String?
    public var nativeWindowID: String?

    public init(
        kind: Kind,
        path: String? = nil,
        bundleIdentifier: String? = nil,
        nativeWindowID: String? = nil
    ) {
        self.kind = kind
        self.path = path
        self.bundleIdentifier = bundleIdentifier
        self.nativeWindowID = nativeWindowID
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
    public var triggerHotkeyID: String
    public var endpoint: String
    public var apiKey: String
    public var model: String
    public var temperature: Double
    public var promptTemplate: String
    public var systemPrompt: String
    public var copyKeystrokeDelay: Double
    public var nativeWindow: TranslationWindowSettings

    public init(
        enabled: Bool,
        triggerHotkeyID: String,
        endpoint: String,
        apiKey: String,
        model: String,
        temperature: Double,
        promptTemplate: String,
        systemPrompt: String,
        copyKeystrokeDelay: Double,
        nativeWindow: TranslationWindowSettings
    ) {
        self.enabled = enabled
        self.triggerHotkeyID = triggerHotkeyID
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.temperature = temperature
        self.promptTemplate = promptTemplate
        self.systemPrompt = systemPrompt
        self.copyKeystrokeDelay = copyKeystrokeDelay
        self.nativeWindow = nativeWindow
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
    static let defaultFileName = "config.json"

    static func migratedHammerspoonDefault(apiKey: String = "") -> UserConfiguration {
        UserConfiguration(
            version: 1,
            application: ApplicationSettings(
                name: "TSMacTools",
                configDirectoryName: defaultDirectoryName,
                terminalBundleIdentifier: "net.kovidgoyal.kitty",
                finderBundleIdentifier: "com.apple.finder",
                ignoredWindowApplicationNames: [
                    "Dock",
                    "SystemUIServer",
                    "Window Server"
                ]
            ),
            hotkeys: [
                HotkeyBinding(id: "focused-window-info", modifiers: ["ctrl", "cmd"], key: ".", action: HotkeyAction(kind: .showFocusedWindowInfo)),
                HotkeyBinding(id: "wechat", modifiers: ["alt"], key: "W", action: HotkeyAction(kind: .focusApplication, path: "/Applications/WeChat.app")),
                HotkeyBinding(id: "discord", modifiers: ["alt"], key: "O", action: HotkeyAction(kind: .focusApplication, path: "/Applications/Discord.app")),
                HotkeyBinding(id: "lark", modifiers: ["alt"], key: "F", action: HotkeyAction(kind: .focusApplication, path: "/Applications/Lark.app")),
                HotkeyBinding(id: "chrome", modifiers: ["alt"], key: "C", action: HotkeyAction(kind: .focusApplication, path: "/Applications/Google Chrome.app")),
                HotkeyBinding(id: "siyuan", modifiers: ["alt"], key: "R", action: HotkeyAction(kind: .focusApplication, path: "/Applications/SiYuan.app")),
                HotkeyBinding(id: "outlook", modifiers: ["alt"], key: "M", action: HotkeyAction(kind: .focusApplication, path: "/Applications/Microsoft Outlook.app")),
                HotkeyBinding(id: "qq", modifiers: ["alt"], key: "Q", action: HotkeyAction(kind: .focusApplication, path: "/Applications/QQ.app")),
                HotkeyBinding(id: "vscode", modifiers: ["alt"], key: "V", action: HotkeyAction(kind: .focusApplication, path: "/Applications/Visual Studio Code.app")),
                HotkeyBinding(id: "zotero", modifiers: ["alt"], key: "Z", action: HotkeyAction(kind: .focusApplication, path: "/Applications/Zotero.app")),
                HotkeyBinding(id: "cherry-studio", modifiers: ["alt"], key: "X", action: HotkeyAction(kind: .focusApplication, path: "/Applications/Cherry Studio.app")),
                HotkeyBinding(id: "translate-selection", modifiers: ["alt"], key: "S", action: HotkeyAction(kind: .translateSelection, nativeWindowID: "translate")),
                HotkeyBinding(id: "finder-toggle", modifiers: ["alt"], key: "E", action: HotkeyAction(kind: .toggleFinder, bundleIdentifier: "com.apple.finder")),
                HotkeyBinding(id: "terminal-toggle", modifiers: ["cmd"], key: "D", action: HotkeyAction(kind: .toggleTerminal, bundleIdentifier: "net.kovidgoyal.kitty")),
                HotkeyBinding(id: "reload", modifiers: ["cmd", "alt", "ctrl"], key: "R", action: HotkeyAction(kind: .reloadConfiguration))
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
                triggerHotkeyID: "translate-selection",
                endpoint: "http://127.0.0.1:8787/v1/chat/completions",
                apiKey: apiKey,
                model: "llama-3.3-70b-versatile",
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
