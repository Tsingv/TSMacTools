import XCTest
import MacToolsCore

final class UserConfigurationStoreTests: XCTestCase {
    func testFanReadPlanSeparatesBackgroundAndExpandedMonitoring() {
        let descriptors = FanSensorMetadata.descriptors(keys: ["Tp01", "Tg01", "TB0T", "Tzzz"], model: "unknown", topology: ["Performance": 4])
        var settings = FanSettings()
        XCTAssertFalse(FanReadPlan(settings: settings, monitoring: false).needsSample)
        settings.enabled = true
        var disabled = FanRule(sensor: "Maximum"); disabled.enabled = false
        settings.rules = [FanRule(sensor: "CPU"), disabled]
        let background = FanReadPlan(settings: settings, monitoring: false, areas: ["Battery"])
        XCTAssertEqual(Set(background.keys(in: descriptors)), ["Tp01"])
        let visible = FanReadPlan(settings: settings, monitoring: true, areas: ["Battery"])
        XCTAssertEqual(Set(visible.keys(in: descriptors)), ["Tp01", "TB0T"])
        settings.enabled = false
        XCTAssertEqual(Set(FanReadPlan(settings: settings, monitoring: true, areas: ["GPU"]).keys(in: descriptors)), ["Tg01"])
    }

    func testFanReadPlanExpandsEveryAggregateAndPreservesRawSensors() {
        let descriptors = FanSensorMetadata.descriptors(keys: ["Tp01", "Tg01", "TB0T", "Tzzz"], model: "unknown", topology: ["Performance": 4])
        for alias in FanReadPlan.aggregates {
            var settings = FanSettings(); settings.enabled = true; settings.rules = [FanRule(sensor: alias)]
            let keys = Set(FanReadPlan(settings: settings, monitoring: false).keys(in: descriptors))
            if alias.contains("CPU") || alias == "CPU" { XCTAssertEqual(keys, ["Tp01"], alias) }
            else if alias.contains("GPU") || alias == "GPU" { XCTAssertEqual(keys, ["Tg01"], alias) }
            else { XCTAssertEqual(keys, ["Tp01", "Tg01", "TB0T"], alias) }
        }
        var settings = FanSettings(); settings.enabled = true; settings.rules = [FanRule(sensor: "Tzzz")]
        XCTAssertEqual(FanReadPlan(settings: settings, monitoring: false).keys(in: descriptors), ["Tzzz"])
        var registry = FanSensorRegistry(); registry.discover(keys: Array(descriptors.keys))
        var snapshot = FanSnapshot(); registry.update(&snapshot)
        XCTAssertEqual(Set(snapshot.descriptors.keys), Set(descriptors.keys))
        XCTAssertTrue(snapshot.temperatures.isEmpty)
    }

    func testFanControlVersionRejectsOldPartialSamplesAndRoundTrips() {
        var version = FanControlSampleVersion()
        var settings = FanSettings(); settings.enabled = true; settings.rules = [FanRule(sensor: "Tp01")]
        XCTAssertTrue(version.update(settings))
        let partial = version.generation
        XCTAssertFalse(version.update(settings))
        XCTAssertTrue(version.accepts(partial))
        let original = settings
        settings.rules[0].sensor = "Maximum"
        XCTAssertTrue(version.update(settings))
        XCTAssertFalse(version.accepts(partial))
        let full = version.generation
        XCTAssertTrue(version.update(original))
        XCTAssertFalse(version.accepts(partial))
        XCTAssertFalse(version.accepts(full))
        XCTAssertTrue(version.accepts(version.generation))
    }

    func testExpandedAggregatesReadAllCuratedDependenciesWithoutControlRules() {
        let descriptors = FanSensorMetadata.descriptors(keys: ["Tp01", "Tg01", "TB0T", "Tzzz"], model: "unknown", topology: ["Performance": 4])
        let expanded = FanReadPlan(settings: FanSettings(), monitoring: true, areas: ["Aggregates"])
        XCTAssertEqual(Set(expanded.keys(in: descriptors)), ["Tp01", "Tg01", "TB0T"])
        let hidden = FanReadPlan(settings: FanSettings(), monitoring: false, areas: ["Aggregates"])
        XCTAssertFalse(hidden.needsSample)
        XCTAssertTrue(hidden.keys(in: descriptors).isEmpty)
    }

    func testTranslationBaseURLNormalizationAndEndpointCompatibility() throws {
        for (input, expected) in [
            (" https://example.com/ ", "https://example.com/v1/chat/completions"),
            ("http://localhost:8787", "http://localhost:8787/v1/chat/completions"),
            ("https://example.com/v1/", "https://example.com/v1/chat/completions"),
            ("https://example.com/custom/api///?key=a%2Fb", "https://example.com/custom/api/chat/completions?key=a%2Fb"),
            ("https://example.com/v1/chat/completions?key=a%2Fb", "https://example.com/v1/chat/completions?key=a%2Fb"),
            ("https://example.com/chat/completions", "https://example.com/chat/completions"),
            ("https://example.com/custom/chat/completions/", "https://example.com/custom/chat/completions/")
        ] {
            XCTAssertEqual(try TranslationEndpoint.requestURL(input), expected)
            XCTAssertEqual(try TranslationEndpoint.requestURL(TranslationEndpoint.baseURL(expected)), expected)
        }
        XCTAssertEqual(TranslationEndpoint.baseURL("https://example.com/custom/chat/completions"), "https://example.com/custom")
        for invalid in ["", "example.com", "/v1", "ftp://example.com", "https://"] {
            XCTAssertThrowsError(try TranslationEndpoint.requestURL(invalid))
        }
    }

    func testHotkeyShortcutNormalizesModifierAliasesOrderAndKeyCase() {
        let configured = HotkeyShortcut(modifiers: ["shift", "command", "option", "control"], key: "r")
        let recorded = HotkeyShortcut(modifiers: ["ALT", "ctrl", "cmd", "shift"], key: "R")

        XCTAssertEqual(configured, recorded)
        XCTAssertEqual(configured.modifiers, ["alt", "cmd", "ctrl", "shift"])
        XCTAssertEqual(configured.key, "R")
    }

    func testHotkeyShortcutIgnoresDuplicateModifiersButDistinguishesDifferentKeys() {
        let duplicated = HotkeyShortcut(modifiers: ["cmd", "command", "shift", "unknown"], key: " d ")
        let canonical = HotkeyShortcut(modifiers: ["shift", "cmd"], key: "D")
        let different = HotkeyShortcut(modifiers: ["shift", "cmd"], key: "F")

        XCTAssertEqual(duplicated, canonical)
        XCTAssertNotEqual(canonical, different)
    }

    func testHotkeyKeyUsesOneMappingForPrintableFunctionNavigationAndKeypadKeys() throws {
        XCTAssertEqual(HotkeyKey.allKnownKeys.count, 120)
        XCTAssertEqual(Set(HotkeyKey.allKnownKeys).count, 120)
        for key in HotkeyKey.allKnownKeys {
            XCTAssertEqual(
                HotkeyKey(configurationName: key.configurationName),
                key,
                key.configurationName
            )
        }

        let representatives: [(String, UInt16)] = [
            ("[", 0x21), ("]", 0x1E), ("1", 0x12), ("/", 0x2C),
            ("F12", 0x6F), ("ContextualMenu", 0x6E), ("Home", 0x73), ("Left", 0x7B),
            ("Keypad7", 0x59), ("JISKana", 0x68)
        ]

        for (name, code) in representatives {
            let parsed = try XCTUnwrap(HotkeyKey(configurationName: name))
            XCTAssertEqual(parsed.code, code, name)
            XCTAssertEqual(HotkeyKey(code: code).configurationName, name)
        }
        XCTAssertEqual(HotkeyKey(configurationName: "LeftBracket")?.code, 0x21)
        XCTAssertEqual(HotkeyKey(configurationName: "←")?.code, 0x7B)
    }

    func testHotkeyKeyPreservesUnknownCapturedKeyCodes() throws {
        let captured = HotkeyKey(code: 0x00FF)
        XCTAssertEqual(captured.configurationName, "KeyCode:255")
        XCTAssertEqual(
            try XCTUnwrap(HotkeyKey(configurationName: captured.configurationName)),
            captured
        )
        XCTAssertNil(HotkeyKey(configurationName: "KeyCode:not-a-number"))
    }

    func testCommandLeftBracketHotkeyRoundTripsAndConflictsCanonically() throws {
        var configuration = UserConfiguration.migratedHammerspoonDefault()
        let binding = HotkeyBinding(
            id: "navigate-back",
            modifiers: ["Command"],
            key: "[",
            action: HotkeyAction(kind: .focusApplication)
        )
        configuration.hotkeys.append(binding)

        let data = try JSONEncoder().encode(binding)
        XCTAssertEqual(try JSONDecoder().decode(HotkeyBinding.self, from: data), binding)
        XCTAssertNotNil(
            configuration.conflictingHotkey(
                for: HotkeyShortcut(modifiers: ["cmd"], key: "[")
            )
        )
    }

    func testHotkeyBindingExposesCanonicalShortcut() {
        let binding = HotkeyBinding(
            modifiers: ["Option", "Command"],
            key: "s",
            action: HotkeyAction(kind: .translateSelection)
        )

        XCTAssertEqual(binding.shortcut, HotkeyShortcut(modifiers: ["alt", "cmd"], key: "S"))
    }

    func testHotkeyConflictExcludesCurrentRowButFindsAnotherBinding() {
        var configuration = UserConfiguration.migratedHammerspoonDefault()
        let shortcut = configuration.hotkeys[0].shortcut

        XCTAssertNil(configuration.conflictingHotkey(for: shortcut, excluding: 0))

        configuration.hotkeys[1].modifiers = ["control", "command"]
        configuration.hotkeys[1].key = "."
        XCTAssertEqual(
            configuration.conflictingHotkey(for: shortcut, excluding: 0),
            configuration.hotkeys[1]
        )
    }

    func testMouseButtonTriggerConflictsOnlyWithSameMouseButton() {
        var configuration = UserConfiguration.migratedHammerspoonDefault()
        configuration.hotkeys.append(HotkeyBinding(
            id: "mouse-back",
            mouseButton: 3,
            action: HotkeyAction(kind: .simulateKeystroke, modifiers: ["ctrl"], key: "Down")
        ))

        XCTAssertEqual(configuration.hotkeys.last?.trigger, .mouseButton(3))
        XCTAssertNotNil(configuration.conflictingHotkey(for: .mouseButton(3)))
        XCTAssertNil(configuration.conflictingHotkey(for: .mouseButton(4)))
    }

    func testMouseButtonTriggerIncludesCanonicalModifiers() {
        var configuration = UserConfiguration.migratedHammerspoonDefault()
        let commandMouseSix = HotkeyBinding(
            id: "command-mouse-six",
            modifiers: ["Command"],
            mouseButton: 5,
            action: HotkeyAction(kind: .focusApplication)
        )
        configuration.hotkeys.append(commandMouseSix)

        XCTAssertEqual(
            commandMouseSix.trigger,
            .mouseButton(5, modifiers: ["cmd"])
        )
        XCTAssertNotNil(
            configuration.conflictingHotkey(for: .mouseButton(5, modifiers: ["command"]))
        )
        XCTAssertNil(configuration.conflictingHotkey(for: .mouseButton(5)))
        XCTAssertNil(configuration.conflictingHotkey(for: .mouseButton(4, modifiers: ["cmd"])))
    }

    func testMouseButtonAndSimulatedKeystrokeRoundTrip() throws {
        let binding = HotkeyBinding(
            id: "mouse-forward",
            modifiers: ["cmd"],
            mouseButton: 4,
            action: HotkeyAction(
                kind: .simulateKeystroke,
                modifiers: ["ctrl"],
                key: "Down"
            )
        )

        let data = try JSONEncoder().encode(binding)
        let decoded = try JSONDecoder().decode(HotkeyBinding.self, from: data)
        XCTAssertEqual(decoded, binding)
        XCTAssertEqual(decoded.trigger, .mouseButton(4, modifiers: ["cmd"]))
    }

    func testSimulatedKeystrokeKeyUpModifierPolicy() {
        XCTAssertFalse(
            HotkeyAction(
                kind: .simulateKeystroke,
                modifiers: ["ctrl"],
                key: "Down"
            ).preservesModifiersOnKeyUp
        )
        XCTAssertFalse(
            HotkeyAction(
                kind: .simulateKeystroke,
                modifiers: ["cmd"],
                key: "D"
            ).preservesModifiersOnKeyUp
        )
        XCTAssertTrue(
            HotkeyAction(
                kind: .simulateKeystroke,
                modifiers: ["command"],
                key: "tab"
            ).preservesModifiersOnKeyUp
        )
    }

    func testSimulatedKeystrokeIntrinsicModifierTableRestoresSecondaryFunctionFlag() {
        XCTAssertEqual(
            HotkeyAction(
                kind: .simulateKeystroke,
                modifiers: ["ctrl"],
                key: "Down"
            ).implicitCGEventModifiers,
            ["fn"]
        )
        XCTAssertEqual(
            HotkeyAction(
                kind: .simulateKeystroke,
                modifiers: ["ctrl"],
                key: "↑"
            ).implicitCGEventModifiers,
            ["fn"]
        )
        XCTAssertEqual(
            HotkeyAction(
                kind: .simulateKeystroke,
                modifiers: ["cmd"],
                key: "D"
            ).implicitCGEventModifiers,
            []
        )
    }

    func testUpdateMutationConflictDoesNotWriteConfiguration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let store = UserConfigurationStore()
        let configuration = UserConfiguration.migratedHammerspoonDefault()
        let configURL = root.appendingPathComponent("config.jsonc")
        let original = try store.encodeConfigurationAsJSONC(configuration)
        try original.write(to: configURL)
        let conflictingShortcut = configuration.hotkeys[1].shortcut

        XCTAssertThrowsError(try store.update(at: configURL) { latest in
            if latest.conflictingHotkey(for: conflictingShortcut, excluding: 0) != nil {
                throw TestHotkeyConflict()
            }
            latest.hotkeys[0].modifiers = configuration.hotkeys[1].modifiers
            latest.hotkeys[0].key = configuration.hotkeys[1].key
        })
        XCTAssertEqual(try Data(contentsOf: configURL), original)
    }

    func testBootstrapCreatesDefaultConfiguration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = UserConfigurationStore()
        let result = try store.bootstrap(at: root)

        XCTAssertTrue(result.createdConfig)
        XCTAssertEqual(result.configuration.application.terminalBundleIdentifier, "net.kovidgoyal.kitty")
        XCTAssertEqual(result.configuration.translation.nativeWindow.id, "translate")
        XCTAssertEqual(result.configuration.translation.provider, "google_web")
        XCTAssertEqual(result.configuration.translation.googleEndpoint, "https://translation.googleapis.com/language/translate/v2")
        XCTAssertEqual(result.configuration.translation.googleApiKey, "")
        XCTAssertEqual(result.configuration.translation.googleSourceLanguage, "auto")
        XCTAssertEqual(result.configuration.translation.googleTargetLanguage, "zh-CN")
        XCTAssertEqual(result.configuration.translation.googleTargetLanguageForChinese, "en")
        XCTAssertEqual(result.configuration.translation.googleWebEndpoint, "https://translate.googleapis.com/translate_a/single")
        XCTAssertEqual(result.configuration.translation.googleWebClient, "gtx")
        XCTAssertEqual(result.configuration.translation.model, "qwen/qwen3.6-27b")
        XCTAssertFalse(result.configuration.translation.thinkingEnabled)
        XCTAssertEqual(result.configuration.translation.thinkingParameter, "include_reasoning")
        XCTAssertEqual(result.configuration.translation.contextWindowTokens, 262144)
        XCTAssertEqual(result.configuration.translation.outputTokenLimit, 2048)
        XCTAssertEqual(result.configuration.translation.requestTokenLimit, 8000)
        XCTAssertTrue(result.configuration.translation.normalizePDFLineBreaks)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.configURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.scriptsDirectoryURL.path))
        XCTAssertTrue(result.createdTranslationScript)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.translationScriptURL.path))
        XCTAssertEqual(result.configuration.scripting.pythonPath, "/usr/bin/python3")
        XCTAssertTrue(result.configuration.scroll.enabled)
        XCTAssertEqual(result.configuration.scroll.preset, .balanced)
        XCTAssertTrue(result.configuration.scroll.smoothVertical)
        XCTAssertTrue(result.configuration.scroll.smoothHorizontal)
        XCTAssertFalse(result.configuration.scroll.reverseVertical)
        XCTAssertFalse(result.configuration.scroll.reverseHorizontal)
        XCTAssertTrue(result.configuration.scroll.excludeTrackpad)
        XCTAssertEqual(result.configuration.scroll.tuning, ScrollPreset.balanced.tuning)

        let configText = try String(contentsOf: result.configURL, encoding: .utf8)
        XCTAssertTrue(configText.contains("// TSMacTools user configuration."))
        XCTAssertTrue(configText.contains(#""hotkeys" : ["#))
        XCTAssertTrue(configText.contains(#""scripting" : {"#))
        XCTAssertTrue(configText.contains(#""provider" : "google_web""#))
        XCTAssertTrue(configText.contains(#""googleApiKey" : """#))
        XCTAssertTrue(configText.contains(#""googleSourceLanguage" : "auto""#))
        XCTAssertTrue(configText.contains(#""googleTargetLanguage" : "zh-CN""#))
        XCTAssertTrue(configText.contains(#""googleTargetLanguageForChinese" : "en""#))
        XCTAssertFalse(configText.contains(#""googleEndpoint""#))
        XCTAssertFalse(configText.contains(#""googleWebEndpoint""#))
        XCTAssertFalse(configText.contains(#""googleWebClient""#))
        XCTAssertTrue(configText.contains(#""thinkingEnabled" : false"#))
        XCTAssertTrue(configText.contains(#""thinkingParameter" : "include_reasoning""#))
        XCTAssertTrue(configText.contains(#""contextWindowTokens" : 262144"#))
        XCTAssertTrue(configText.contains(#""outputTokenLimit" : 2048"#))
        XCTAssertTrue(configText.contains(#""requestTokenLimit" : 8000"#))
        XCTAssertTrue(configText.contains(#""normalizePDFLineBreaks" : true"#))
        XCTAssertTrue(configText.contains(#""preset" : "balanced""#))
        XCTAssertTrue(configText.contains(#""smoothVertical" : true"#))
        XCTAssertTrue(configText.contains(#""smoothHorizontal" : true"#))
        XCTAssertTrue(configText.contains(#""reverseVertical" : false"#))
        XCTAssertTrue(configText.contains(#""reverseHorizontal" : false"#))
        XCTAssertTrue(configText.contains(#""excludeTrackpad" : true"#))
        XCTAssertTrue(configText.contains(#""duration" : 0.36"#))
        XCTAssertFalse(configText.contains(#""version":"#))
        XCTAssertFalse(configText.contains(#""configDirectoryName":"#))

        let scriptText = try String(contentsOf: result.translationScriptURL, encoding: .utf8)
        XCTAssertTrue(scriptText.contains(#"def request_google_translation(source_text):"#))
        XCTAssertTrue(scriptText.contains(#"def request_google_web_translation(source_text):"#))
        XCTAssertTrue(scriptText.contains(#"translate.googleapis.com/translate_a/single"#))
        XCTAssertTrue(scriptText.contains(#"Google Cloud Translation API key"#))
        XCTAssertTrue(scriptText.contains(#"translation.googleapis.com/language/translate/v2"#))
        XCTAssertTrue(scriptText.contains(#"def request_llm_translation(source_text):"#))
        XCTAssertTrue(scriptText.contains(#"def normalize_source_text(source_text):"#))
        XCTAssertTrue(scriptText.contains(#"def join_wrapped_lines(lines):"#))
        XCTAssertTrue(scriptText.contains(#"normalizePDFLineBreaks"#))
        XCTAssertTrue(scriptText.contains(#"translation.get("thinkingParameter") == "enable_thinking""#))
        XCTAssertTrue(scriptText.contains(#"translation.get("thinkingParameter") == "include_reasoning""#))
        XCTAssertTrue(scriptText.contains(#"body["include_reasoning"]"#))
        XCTAssertTrue(scriptText.contains(#"def collect_text(value):"#))
        XCTAssertTrue(scriptText.contains(#"def resolve_output_token_limit(translation, messages, output_token_limit):"#))
        XCTAssertTrue(scriptText.contains(#"requestTokenLimit"#))
        XCTAssertTrue(scriptText.contains(#"def format_http_error(error):"#))
        XCTAssertTrue(scriptText.contains(#"max_completion_tokens"#))
        XCTAssertTrue(scriptText.contains(#"def log_response_summary(response):"#))
        XCTAssertTrue(scriptText.contains(#"response.get("output_text")"#))
        XCTAssertTrue(scriptText.contains(#"The provider returned reasoning data but no final translation text."#))
        XCTAssertFalse(scriptText.contains(#"/no_think"#))
        XCTAssertFalse(scriptText.contains(#"strip_thinking_blocks"#))
    }

    func testBootstrapReadsExistingConfigurationWithoutOverwriting() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = UserConfigurationStore()
        var configuration = UserConfiguration.migratedHammerspoonDefault()
        configuration.application.terminalBundleIdentifier = "com.example.Terminal"

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configURL = root.appendingPathComponent(UserConfiguration.defaultFileName)
        let encoder = JSONEncoder()
        try encoder.encode(configuration).write(to: configURL)

        let result = try store.bootstrap(at: root)

        XCTAssertFalse(result.createdConfig)
        XCTAssertEqual(result.configuration.application.terminalBundleIdentifier, "com.example.Terminal")
        XCTAssertEqual(result.configuration.scripting.pythonPath, "/usr/bin/python3")
    }

    func testBootstrapReadsJSONCConfiguration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = UserConfigurationStore()
        var configuration = UserConfiguration.migratedHammerspoonDefault()
        configuration.windowSwitcher.enabled = false

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configURL = root.appendingPathComponent(UserConfiguration.defaultFileName)
        let data = try store.encodeConfigurationAsJSONC(configuration)
        var text = String(decoding: data, as: UTF8.self)
        text = text.replacingOccurrences(of: #""enabled" : false,"#, with: #""enabled" : false, // keep disabled during tests"#)
        text += "\n/* trailing block comment */\n"
        try text.write(to: configURL, atomically: true, encoding: .utf8)

        let result = try store.bootstrap(at: root)

        XCTAssertFalse(result.createdConfig)
        XCTAssertFalse(result.configuration.windowSwitcher.enabled)
    }

    func testDecodeLegacyTranslationConfigurationDefaultsThinkingOff() throws {
        let store = UserConfigurationStore()
        let data = try store.encodeConfigurationAsJSONC(.migratedHammerspoonDefault())
        let legacyText = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: #"    "provider" : "google_web","# + "\n", with: "")
            .replacingOccurrences(of: #"    "googleEndpoint" : "https:\/\/translation.googleapis.com\/language\/translate\/v2","# + "\n", with: "")
            .replacingOccurrences(of: #"    "googleApiKey" : "","# + "\n", with: "")
            .replacingOccurrences(of: #"    "googleSourceLanguage" : "auto","# + "\n", with: "")
            .replacingOccurrences(of: #"    "googleTargetLanguage" : "zh-CN","# + "\n", with: "")
            .replacingOccurrences(of: #"    "googleTargetLanguageForChinese" : "en","# + "\n", with: "")
            .replacingOccurrences(of: #"    "googleWebEndpoint" : "https:\/\/translate.googleapis.com\/translate_a\/single","# + "\n", with: "")
            .replacingOccurrences(of: #"    "googleWebClient" : "gtx","# + "\n", with: "")
            .replacingOccurrences(of: #"    "normalizePDFLineBreaks" : true,"# + "\n", with: "")
            .replacingOccurrences(of: #"    "thinkingEnabled" : false,"# + "\n", with: "")

        let configuration = try store.decodeConfiguration(from: Data(legacyText.utf8))

        XCTAssertEqual(configuration.translation.provider, "llm")
        XCTAssertEqual(configuration.translation.googleEndpoint, "https://translation.googleapis.com/language/translate/v2")
        XCTAssertEqual(configuration.translation.googleApiKey, "")
        XCTAssertEqual(configuration.translation.googleSourceLanguage, "auto")
        XCTAssertEqual(configuration.translation.googleTargetLanguage, "zh-CN")
        XCTAssertEqual(configuration.translation.googleTargetLanguageForChinese, "en")
        XCTAssertEqual(configuration.translation.googleWebEndpoint, "https://translate.googleapis.com/translate_a/single")
        XCTAssertEqual(configuration.translation.googleWebClient, "gtx")
        XCTAssertFalse(configuration.translation.thinkingEnabled)
        XCTAssertEqual(configuration.translation.thinkingParameter, "include_reasoning")
        XCTAssertEqual(configuration.translation.contextWindowTokens, 262144)
        XCTAssertEqual(configuration.translation.outputTokenLimit, 2048)
        XCTAssertEqual(configuration.translation.requestTokenLimit, 8000)
        XCTAssertTrue(configuration.translation.normalizePDFLineBreaks)
        XCTAssertEqual(configuration.scroll, .default)
    }

    func testDecodeWindowSwitcherWithoutRestorePreviousApplicationSettingDefaultsOn() throws {
        let store = UserConfigurationStore()
        let encoded = try store.encodeConfigurationAsJSONC(.migratedHammerspoonDefault())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(String(decoding: encoded, as: UTF8.self)
                .split(separator: "\n")
                .dropFirst(3)
                .joined(separator: "\n").utf8)
        ) as? [String: Any])
        var windowSwitcher = try XCTUnwrap(object["windowSwitcher"] as? [String: Any])
        windowSwitcher.removeValue(forKey: "restorePreviousApplicationWhenNoWindows")
        object["windowSwitcher"] = windowSwitcher

        let configuration = try store.decodeConfiguration(
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertTrue(configuration.windowSwitcher.restorePreviousApplicationWhenNoWindows)
    }

    func testWindowSwitcherDisplayDelayDefaultsRoundTripsAndIsRuntimeBounded() throws {
        let store = UserConfigurationStore()
        let encoded = try store.encodeConfigurationAsJSONC(.migratedHammerspoonDefault())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(String(decoding: encoded, as: UTF8.self)
                .split(separator: "\n")
                .dropFirst(3)
                .joined(separator: "\n").utf8)
        ) as? [String: Any])
        var windowSwitcher = try XCTUnwrap(object["windowSwitcher"] as? [String: Any])
        windowSwitcher.removeValue(forKey: "displayDelay")
        object["windowSwitcher"] = windowSwitcher

        let legacy = try store.decodeConfiguration(
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(
            legacy.windowSwitcher.displayDelay,
            WindowSwitcherSettings.defaultDisplayDelay,
            accuracy: 0.0001
        )

        var expected = legacy
        expected.windowSwitcher.displayDelay = 0.42
        let roundTripped = try store.decodeConfiguration(
            from: store.encodeConfigurationAsJSONC(expected)
        )
        XCTAssertEqual(roundTripped.windowSwitcher.displayDelay, 0.42, accuracy: 0.0001)

        expected.windowSwitcher.displayDelay = -1
        XCTAssertEqual(expected.windowSwitcher.effectiveDisplayDelay, 0, accuracy: 0.0001)
        expected.windowSwitcher.displayDelay = 3
        XCTAssertEqual(expected.windowSwitcher.effectiveDisplayDelay, 2, accuracy: 0.0001)
    }

    func testWindowSwitcherRestorePreviousApplicationSettingRoundTripsOff() throws {
        let store = UserConfigurationStore()
        var expected = UserConfiguration.migratedHammerspoonDefault()
        expected.windowSwitcher.restorePreviousApplicationWhenNoWindows = false

        let data = try store.encodeConfigurationAsJSONC(expected)
        let actual = try store.decodeConfiguration(from: data)

        XCTAssertFalse(actual.windowSwitcher.restorePreviousApplicationWhenNoWindows)
    }

    func testDecodeConfigurationWithoutScrollSectionUsesBalancedDefaults() throws {
        let store = UserConfigurationStore()
        let encoded = try store.encodeConfigurationAsJSONC(.migratedHammerspoonDefault())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(String(decoding: encoded, as: UTF8.self)
                .split(separator: "\n")
                .dropFirst(3)
                .joined(separator: "\n").utf8)
        ) as? [String: Any])
        var legacy = object
        legacy.removeValue(forKey: "scroll")

        let configuration = try store.decodeConfiguration(from: JSONSerialization.data(withJSONObject: legacy))

        XCTAssertEqual(configuration.scroll, .default)
    }

    func testBootstrapDoesNotOverwriteExistingTranslationScript() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let scripts = root.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let scriptURL = scripts.appendingPathComponent("translate_selection.py")
        try "custom".write(to: scriptURL, atomically: true, encoding: .utf8)

        let result = try UserConfigurationStore().bootstrap(at: root)

        XCTAssertFalse(result.createdTranslationScript)
        XCTAssertEqual(try String(contentsOf: scriptURL, encoding: .utf8), "custom")
    }

    func testUpdatePreservesCommentsUnknownFieldsAndConcurrentKnownEdits() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let store = UserConfigurationStore()
        var configuration = UserConfiguration.migratedHammerspoonDefault()
        configuration.translation.googleApiKey = "edited-outside-settings"
        var text = String(decoding: try store.encodeConfigurationAsJSONC(configuration), as: UTF8.self)
        text = text.replacingOccurrences(
            of: #"    "provider" : "google_web","#,
            with: "    // Keep this provider explanation.\n" + #"    "provider" : "google_web","#
        )
        let rootClosingBrace = try XCTUnwrap(text.range(of: "\n}", options: .backwards))
        text.replaceSubrange(
            rootClosingBrace,
            with: ",\n  \"thirdPartyExtension\" : { \"keep\" : true }\n}"
        )
        let configURL = root.appendingPathComponent("config.jsonc")
        try text.write(to: configURL, atomically: true, encoding: .utf8)

        let updated = try store.update(at: configURL) {
            $0.scroll.reverseVertical = true
        }

        XCTAssertTrue(updated.scroll.reverseVertical)
        XCTAssertEqual(updated.translation.googleApiKey, "edited-outside-settings")
        let updatedText = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(updatedText.contains("// Keep this provider explanation."))
        XCTAssertTrue(updatedText.contains(#""thirdPartyExtension" : { "keep" : true }"#))
        XCTAssertTrue(updatedText.contains(#""googleApiKey" : "edited-outside-settings""#))
        XCTAssertTrue(try store.load(from: configURL).scroll.reverseVertical)
    }

    func testUpdatePreservesArrayCommentsWhileChangingOneHotkey() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let store = UserConfigurationStore()
        var text = String(
            decoding: try store.encodeConfigurationAsJSONC(.migratedHammerspoonDefault()),
            as: UTF8.self
        )
        text = text.replacingOccurrences(
            of: #"      "key" : "F","#,
            with: "      // Keep the user's hotkey note.\n" + #"      "key" : "F","#,
            maxReplacements: 1
        )
        let configURL = root.appendingPathComponent("config.jsonc")
        try text.write(to: configURL, atomically: true, encoding: .utf8)

        let updated = try store.update(at: configURL) {
            $0.hotkeys[0].key = "G"
            $0.hotkeys[0].modifiers = ["cmd", "shift"]
        }

        XCTAssertEqual(updated.hotkeys[0].key, "G")
        XCTAssertEqual(updated.hotkeys[0].modifiers, ["cmd", "shift"])
        let updatedText = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(updatedText.contains("// Keep the user's hotkey note."))
    }

    func testUpdateChangesSimulatedKeystrokeActionToFocusApplication() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let store = UserConfigurationStore()
        var configuration = UserConfiguration.migratedHammerspoonDefault()
        configuration.hotkeys.append(HotkeyBinding(
            id: "mouse-six",
            mouseButton: 5,
            action: HotkeyAction(kind: .simulateKeystroke, modifiers: ["ctrl"], key: "Down")
        ))
        var text = String(decoding: try store.encodeConfigurationAsJSONC(configuration), as: UTF8.self)
        let kindField = #""kind" : "simulateKeystroke""#
        XCTAssertTrue(text.contains(kindField))
        text = text.replacingOccurrences(
            of: kindField,
            with: #"""
        "futureActionField" : { "keep" : true },
        // Keep the user's action note.
        "kind" : "simulateKeystroke"
        """#,
            maxReplacements: 1
        )
        let configURL = root.appendingPathComponent("config.jsonc")
        try text.write(to: configURL, atomically: true, encoding: .utf8)

        let updated = try store.update(at: configURL) { latest in
            let index = try XCTUnwrap(latest.hotkeys.firstIndex(where: { $0.id == "mouse-six" }))
            latest.hotkeys[index].action = HotkeyAction(kind: .focusApplication)
        }

        let action = try XCTUnwrap(updated.hotkeys.first(where: { $0.id == "mouse-six" })?.action)
        XCTAssertEqual(action.kind, .focusApplication)
        XCTAssertNil(action.modifiers)
        XCTAssertNil(action.key)
        let updatedText = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(updatedText.contains("// Keep the user's action note."))
        XCTAssertTrue(updatedText.contains(#""futureActionField" : { "keep" : true }"#))
        XCTAssertTrue(updatedText.contains(#""modifiers" : null"#))
        XCTAssertTrue(updatedText.contains(#""key" : null"#))
        XCTAssertEqual(try store.load(from: configURL), updated)
    }

    func testUpdateInsertsScrollIntoLegacyConfiguration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(UserConfiguration.migratedHammerspoonDefault())
            ) as? [String: Any]
        )
        object.removeValue(forKey: "scroll")
        object["futureExtension"] = ["value": 42]
        let legacyData = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        let configURL = root.appendingPathComponent("config.jsonc")
        try legacyData.write(to: configURL)

        let updated = try UserConfigurationStore().update(at: configURL) {
            $0.scroll.enabled = false
            $0.scroll.applyPreset(.glide)
        }

        XCTAssertFalse(updated.scroll.enabled)
        XCTAssertEqual(updated.scroll.preset, .glide)
        let text = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(text.contains(#""futureExtension" : {"#))
        XCTAssertTrue(text.contains(#""scroll": {"#) || text.contains(#""scroll" : {"#))
        XCTAssertEqual(try UserConfigurationStore().load(from: configURL).scroll, updated.scroll)
    }

    func testTranslationActionClassificationIncludesShippedScriptPath() {
        XCTAssertTrue(HotkeyAction(kind: .translateSelection).isSelectedTextTranslation)
        XCTAssertTrue(
            HotkeyAction(
                kind: .callInterface,
                interfaceName: "translateSelection"
            ).isSelectedTextTranslation
        )
        XCTAssertTrue(
            HotkeyAction(
                kind: .runScript,
                path: "scripts/translate_selection.py",
                function: "main",
                input: "selectedText"
            ).isSelectedTextTranslation
        )
        XCTAssertFalse(
            HotkeyAction(
                kind: .runScript,
                path: "scripts/summarize_selection.py",
                function: "main",
                input: "selectedText"
            ).isSelectedTextTranslation
        )
    }
}

private struct TestHotkeyConflict: Error {}

private extension String {
    func replacingOccurrences(
        of target: String,
        with replacement: String,
        maxReplacements: Int
    ) -> String {
        guard maxReplacements > 0 else { return self }
        var result = self
        var searchStart = result.startIndex
        var replacements = 0
        while replacements < maxReplacements,
              let range = result.range(of: target, range: searchStart ..< result.endIndex) {
            let replacementOffset = result.distance(from: result.startIndex, to: range.lowerBound)
            result.replaceSubrange(range, with: replacement)
            searchStart = result.index(result.startIndex, offsetBy: replacementOffset + replacement.count)
            replacements += 1
        }
        return result
    }
}

final class FanSafetyTests: XCTestCase {
    func testBezierAndMissingReadings() throws {
        let rule = FanRule()
        XCTAssertEqual(rule.demand(at: 20), 25)
        XCTAssertEqual(rule.demand(at: 110), 100)
        XCTAssertNil(rule.demand(at: .nan))
        var configured = FanSettings(); configured.rules = [rule]
        XCTAssertNil(configured.demands(readings: [:]))
        XCTAssertEqual(configured.demands(readings: ["CPU": 85]), [0: 100])
        var malformed = rule
        malformed.points[1].temperature = malformed.points[0].temperature
        XCTAssertNil(malformed.demand(at: 60))
    }
    struct Hardware: FanHardwareBoundary {
        var supportsLeasedControl = true
        var restored = false
        var leases: [Date] = []
        mutating func setDemand(_ percent: Double, fan: Int, leaseUntil: Date) throws { leases.append(leaseUntil) }
        mutating func restoreAutomatic() throws { restored = true }
    }
    func testLeaseAndStaleSampleRestore() throws {
        let now = Date(timeIntervalSince1970: 100)
        var session = FanControlSession(hardware: Hardware())
        var configured = FanSettings(); configured.rules = [FanRule()]
        try session.update(settings: configured, readings: ["CPU": 70], now: now, sampleDate: now)
        XCTAssertEqual(session.hardware.leases, [now.addingTimeInterval(5)])
        try session.update(settings: configured, readings: ["CPU": 70], now: now, sampleDate: now.addingTimeInterval(-4))
        XCTAssertTrue(session.hardware.restored)
    }
    func testPatchPreservesConcurrentLeafEditsAndRejectsArrayConflict() throws {
        let original = UserConfiguration.migratedHammerspoonDefault()
        var proposed = original
        proposed.translation.model = "new-model"
        let patch = try ConfigurationPatch(before: original, after: proposed)
        var latest = original
        latest.application.terminalBundleIdentifier = "external"
        try patch.apply(to: &latest)
        XCTAssertEqual(latest.translation.model, "new-model")
        XCTAssertEqual(latest.application.terminalBundleIdentifier, "external")
        proposed = original
        proposed.hotkeys.removeLast()
        let arrayPatch = try ConfigurationPatch(before: original, after: proposed)
        latest.hotkeys.removeFirst()
        XCTAssertThrowsError(try arrayPatch.apply(to: &latest))
    }
}

final class SMCHardwareTests: XCTestCase {
    final class IO: SMCMetadataIO {
        var values: [String: SMCValue] = [:]
        var writes: [String] = []
        var failReadback = false
        var ignoreAutomaticTargets = false
        var ignoredTargets = 0
        var rejectManual = false
        var rejectAutomatic = false
        init() throws {
            for (key, number, type) in [("FNum", 1.0, "ui8 "), ("F0Ac", 2000, "fpe2"), ("F0Mn", 1200, "fpe2"), ("F0Mx", 6000, "fpe2"), ("F0Tg", 2000, "fpe2"), ("F0Md", 0, "ui8 "), ("Tp01", 65, "sp78")] {
                values[key] = try SMCValue.encode(number, type: type)
            }
        }
        var ignoredModes = 0
        var requiresUnlock = false
        var rejectUnlockClear = false
        var metadataOverrides: [String: SMCKeyMetadata] = [:]
        func metadata(_ key: String) throws -> SMCKeyMetadata {
            if let info = metadataOverrides[key] { return info }
            let value = try read(key)
            return SMCKeyMetadata(type: value.type, size: value.bytes.count, attributes: 0x40)
        }
        func keys() throws -> [String] { Array(values.keys) }
        func read(_ key: String) throws -> SMCValue {
            guard let value = values[key] else { throw SMCError.invalid(key) }
            return value
        }
        func write(_ key: String, value: SMCValue) throws {
            writes.append(key)
            if key == "Ftst", value.number == 0, rejectUnlockClear { throw SMCError.transport(-1) }
            if ["F0Md", "F0md"].contains(key), value.number == 1 {
                if ignoredModes > 0 { ignoredModes -= 1; return }
                if requiresUnlock && values["Ftst"]?.number != 1 { return }
            }
            if key == "F0Md", (value.number == 1 && rejectManual) || (value.number == 0 && rejectAutomatic) { throw SMCError.transport(-1) }
            if key == "F0Tg" {
                if ignoreAutomaticTargets && values["F0Md"]?.number != 1 { return }
                if ignoredTargets > 0 { ignoredTargets -= 1; return }
            }
            if !(failReadback && key == "F0Tg") { values[key] = value }
        }
    }
    func testCodecsAndSnapshot() throws {
        for (type, number) in [("ui8 ", 200.0), ("ui16", 6000), ("fpe2", 2345.25), ("sp78", -12.5), ("flt ", 2345.5)] {
            XCTAssertEqual(try XCTUnwrap(SMCValue.encode(number, type: type).number), number, accuracy: 0.001)
        }
        XCTAssertThrowsError(try SMCValue.encode(.nan, type: "flt "))
        XCTAssertThrowsError(try SMCValue.encode(20000, type: "fpe2"))
        let io = try IO(), snapshot = try SMCMonitor.snapshot(io: io, temperatureKeys: ["Tp01", "unknown"])
        XCTAssertEqual(snapshot.fans[0].maximum, 6000)
        XCTAssertEqual(snapshot.ruleReadings["CPU"], 65)
        XCTAssertTrue(io.writes.isEmpty)
    }
    func testLiveLimitsReadbackAndExpiry() throws {
        let io = try IO(), controller = LeasedFanController(io: io)
        try controller.restore()
        try controller.set(fan: 0, percent: 50, now: 100)
        XCTAssertEqual(try io.read("F0Tg").number, 3600)
        XCTAssertEqual(try io.read("F0Md").number, 1)
        try controller.expire(now: 104.9)
        XCTAssertEqual(try io.read("F0Md").number, 1)
        try controller.expire(now: 106)
        XCTAssertEqual(try io.read("F0Md").number, 0)
        XCTAssertThrowsError(try controller.set(fan: 7, percent: 50, now: 100))
        XCTAssertThrowsError(try controller.set(fan: 0, percent: 101, now: 100))
        io.failReadback = true
        XCTAssertThrowsError(try controller.set(fan: 0, percent: 75, now: 100))
        XCTAssertEqual(try io.read("F0Md").number, 0)
    }
    func testRestoreRejectsUnavailableFanEnumeration() throws {
        let io = try IO(), controller = LeasedFanController(io: io)
        io.values["FNum"] = nil
        XCTAssertThrowsError(try controller.restore())
        XCTAssertTrue(io.writes.isEmpty)
    }
    func testRestoreRetainsFailedFanForRetry() throws {
        let io = try IO(), controller = LeasedFanController(io: io)
        let mode = io.values.removeValue(forKey: "F0Md")
        XCTAssertThrowsError(try controller.restore())
        io.values["F0Md"] = mode
        try controller.restore()
        XCTAssertEqual(try io.read("F0Md").number, 0)
    }
    func testUnsupportedModeFailsClosedAndRestoresOtherFans() throws {
        let io = try IO(), controller = LeasedFanController(io: io)
        io.values["F0Md"] = nil
        XCTAssertThrowsError(try controller.set(fan: 0, percent: 50, now: 100))
        XCTAssertFalse(io.writes.contains("F0Tg"))
    }
}

extension SMCHardwareTests {
    func testSleepRestoresAndRejectsRequestsUntilWake() throws {
        let io = try IO(), controller = LeasedFanController(io: io)
        try controller.set(fan: 0, percent: 50, now: 100)
        try controller.prepareForSleep()
        XCTAssertEqual(try io.read("F0Md").number, 0)
        XCTAssertThrowsError(try controller.set(fan: 0, percent: 50, now: 101))
        try controller.resumeAfterSleep()
        try controller.set(fan: 0, percent: 50, now: 102)
        XCTAssertEqual(try io.read("F0Md").number, 1)
    }
}


extension SMCHardwareTests {
    func testBatchReleasesRemovedFansImmediately() throws {
        let io = try IO(), controller = LeasedFanController(io: io)
        try controller.apply(demands: [0: 60], now: 100)
        XCTAssertEqual(try io.read("F0Md").number, 1)
        try controller.apply(demands: [:], now: 100.01)
        XCTAssertEqual(try io.read("F0Md").number, 0)
    }
    func testCompleteTwoFanBatchUsesOneControllerRequest() throws {
        let io = try IO(), controller = LeasedFanController(io: io)
        io.values["FNum"] = try SMCValue.encode(2, type: "ui8 ")
        for suffix in ["Ac", "Mn", "Mx", "Tg", "Md"] { io.values["F1" + suffix] = io.values["F0" + suffix] }
        try controller.apply(demands: [0: 25, 1: 75], now: 100)
        XCTAssertEqual(try io.read("F0Md").number, 1)
        XCTAssertEqual(try io.read("F1Md").number, 1)
        XCTAssertEqual(try io.read("F0Tg").number, 2400)
        XCTAssertEqual(try io.read("F1Tg").number, 4800)
    }
    func testInvalidBatchRestoresActiveLease() throws {
        let io = try IO(), controller = LeasedFanController(io: io)
        try controller.apply(demands: [0: 60], now: 100)
        XCTAssertThrowsError(try controller.apply(demands: [7: 50], now: 101))
        XCTAssertEqual(try io.read("F0Md").number, 0)
    }
    func testLegacyRuleDefaultsEnabledAndDisabledMissingSensorIsIgnored() throws {
        let data = Data(#"{"sensor":"missing","fan":0,"points":[{"temperature":40,"percent":25,"outgoing":0.33,"incoming":0.67},{"temperature":85,"percent":100,"outgoing":0.33,"incoming":0.67}]}"#.utf8)
        var rule = try JSONDecoder().decode(FanRule.self, from: data)
        XCTAssertTrue(rule.enabled)
        var settings = FanSettings(); settings.rules = [rule]
        XCTAssertNil(settings.demands(readings: [:]))
        rule.enabled = false; settings.rules = [rule]
        XCTAssertEqual(settings.demands(readings: [:]), [:])
        XCTAssertFalse(try JSONDecoder().decode(FanRule.self, from: JSONEncoder().encode(rule)).enabled)
    }
}


extension SMCHardwareTests {
    func testHelperUpdateRequiresMatchingSignedContentAndRunningProtocol() {
        XCTAssertFalse(FanHelperUpdatePolicy.needsUpdate(installedHash: "a", bundledHash: "a", runningStatus: "ready-v2"))
        XCTAssertTrue(FanHelperUpdatePolicy.needsUpdate(installedHash: "old", bundledHash: "new", runningStatus: "ready-v2"))
        XCTAssertTrue(FanHelperUpdatePolicy.needsUpdate(installedHash: "a", bundledHash: "a", runningStatus: "ready-v1"))
        XCTAssertTrue(FanHelperUpdatePolicy.needsUpdate(installedHash: nil, bundledHash: "a"))
        XCTAssertTrue(FanHelperUpdatePolicy.needsUpdate(installedHash: "a", bundledHash: nil))
        XCTAssertFalse(FanHelperUpdatePolicy.needsUpdate(installedHash: "a", bundledHash: "a", runningStatus: "unavailable-v2: SMC unavailable"))
        XCTAssertTrue(FanHelperUpdatePolicy.needsUpdate(installedHash: "a", bundledHash: "a", runningStatus: "unavailable-v1: SMC unavailable"))
    }
}


extension SMCHardwareTests {
    func testPersistentFanEnableDefaultsOffAndEvaluatesFreshStartupConfiguration() throws {
        var settings = try JSONDecoder().decode(FanSettings.self, from: Data("{}".utf8))
        let now = Date()
        XCTAssertFalse(settings.enabled)
        XCTAssertNil(settings.activeDemands(readings: ["CPU": 70], now: now, sampleDate: now))
        settings.enabled = true
        let restarted = try JSONDecoder().decode(FanSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertNotNil(restarted.activeDemands(readings: ["CPU": 70], now: now, sampleDate: now))
        XCTAssertNil(restarted.activeDemands(readings: ["CPU": 70], now: now, sampleDate: now.addingTimeInterval(-4)))
        XCTAssertNil(restarted.activeDemands(readings: ["CPU": 70], now: now, sampleDate: now.addingTimeInterval(1)))
        settings.rules = []
        XCTAssertEqual(settings.activeDemands(readings: [:], now: now, sampleDate: now), [:])
    }
}

final class FanPlotAndSensorTests: XCTestCase {
    func testGeometryRoundTripsAcrossSizes() {
        for size in [CGSize(width: 680, height: 280), CGSize(width: 950, height: 360)] {
            let geometry = FanPlotGeometry(bounds: CGRect(origin: .zero, size: size))
            for temperature in [20.0, 46.5, 110] {
                for percent in [0.0, 37, 100] {
                    let reading = geometry.reading(at: geometry.location(temperature: temperature, percent: percent))
                    XCTAssertEqual(reading.temperature, temperature, accuracy: 0.00001)
                    XCTAssertEqual(reading.percent, percent, accuracy: 0.00001)
                }
            }
        }
    }
    func testCPUAggregateExcludesChargerDieAndInvalidValues() {
        var snapshot = FanSnapshot(temperatures: ["TCHP": 120, "Te01": 63, "Tp01": 71, "Tp02": .nan, "HID:PMU tdie3:1": 95])
        snapshot.descriptors = FanSensorMetadata.descriptors(keys: Array(snapshot.temperatures.keys), model: "unknown", topology: ["Efficiency": 2, "Performance": 4])
        XCTAssertEqual(snapshot.ruleReadings["CPU"], 71)
        XCTAssertEqual(snapshot.ruleReadings["Highest CPU"], 71)
        XCTAssertEqual(snapshot.highestCPU?.key, "Tp01")
        XCTAssertEqual(FanSensorMetadata.group("TCHP"), "Power")
        XCTAssertEqual(FanSensorMetadata.group("HID:PMU tdie3:1"), "SoC")
        XCTAssertNil(FanSnapshot(temperatures: ["TCHP": 80]).ruleReadings["CPU"])
    }
    func testTemperatureDiscoveryRejectsNumericConstantsAndBadWidths() {
        for key in ["Tz0A", "TTPD", "TVMD", "TVmS", "TfCB", "F0Ac"] { XCTAssertFalse(FanSensorMetadata.eligible(key), key) }
        for key in ["Tp01", "ftE0", "sd01", "Tg05"] { XCTAssertTrue(FanSensorMetadata.eligible(key), key) }
        XCTAssertNil(FanSensorMetadata.temperature(SMCValue(type: "ui8 ", bytes: [42])))
        XCTAssertNil(FanSensorMetadata.temperature(SMCValue(type: "flt ", bytes: [42, 0])))
        XCTAssertEqual(FanSensorMetadata.temperature(SMCValue(type: "sp78", bytes: [42, 128])), 42.5)
    }
    func testTopologyBoundsAndExactCatalogKeepUnknownKeysOther() {
        let keys = ["Te01", "Te02", "Te03", "Tp01", "Tm01", "Tg01"]
        let legacy = FanSensorMetadata.descriptors(keys: keys, model: "unknown", topology: ["Efficiency": 2, "Performance": 4])
        XCTAssertEqual(legacy["Te03"]?.area, "Other")
        XCTAssertEqual(legacy["Tm01"]?.area, "Memory")
        XCTAssertEqual(legacy["Tp01"]?.displayName, "CPU sensor · Tp01")
        let modern = FanSensorMetadata.descriptors(keys: keys, model: "unknown", topology: ["Efficiency": 2, "Performance": 4, "Super": 6])
        XCTAssertEqual(modern["Tm01"]?.area, "CPU")
        let exact = FanSensorMetadata.descriptors(keys: ["Tp09", "Tpzz", "Tg05"], model: "Mac13,1", topology: [:])
        XCTAssertEqual(exact["Tp09"]?.displayName, "Efficiency Core 1")
        XCTAssertEqual(exact["Tpzz"]?.area, "Other")
        XCTAssertEqual(exact["Tg05"]?.area, "GPU")
    }
    func testRegistryRetainsDescriptorButNeverMissingControlValue() {
        var registry = FanSensorRegistry()
        var first = FanSnapshot(temperatures: ["TB0T": 35, "Tg05": 72])
        registry.update(&first)
        var missing = FanSnapshot()
        registry.update(&missing)
        XCTAssertEqual(missing.descriptors, first.descriptors)
        XCTAssertTrue(missing.temperatures.isEmpty)
        XCTAssertNil(missing.ruleReadings["TB0T"])
        XCTAssertNil(missing.ruleReadings["Maximum"])
        var returned = FanSnapshot(temperatures: ["TB0T": 36])
        registry.update(&returned)
        XCTAssertEqual(returned.descriptors["TB0T"], first.descriptors["TB0T"])
        XCTAssertEqual(returned.ruleReadings["TB0T"], 36)
        XCTAssertNil(returned.ruleReadings["Tg05"])
    }
    func testHIDLogicalAggregateDedupAndNonTemperatureProducts() {
        let values = FanSensorMetadata.mergeHID([("PMU tdie0", "1", 60), ("PMU tdie0", "2", 80), ("PMU tdie1", "3", 40), ("PMU tcal", "4", 30), ("PMU tdev0", "5", 45)])
        XCTAssertEqual(values.count, 3)
        let snapshot = FanSnapshot(temperatures: values)
        XCTAssertEqual(snapshot.ruleReadings["Highest Computer"], 80)
        XCTAssertEqual(snapshot.ruleReadings["Average Computer"], 60)
        XCTAssertNil(snapshot.ruleReadings["CPU"])
        XCTAssertNil(snapshot.ruleReadings["Average CPU"])
        var gpu = FanSnapshot(temperatures: ["Tg01": 80, "TG0D": 60, "mystery": 125])
        gpu.descriptors = FanSensorMetadata.descriptors(keys: Array(gpu.temperatures.keys), model: "unknown", topology: [:])
        XCTAssertEqual(gpu.ruleReadings["GPU"], 80)
        XCTAssertEqual(gpu.ruleReadings["Average GPU"], 70)
        XCTAssertEqual(gpu.ruleReadings["Maximum"], 80)
    }
    func testHIDIdentityDedupPreservesDistinctLocations() {
        let result = FanSensorMetadata.mergeHID([("PMU tdie0", "1", 65), ("PMU tdie0", "1", 68), ("PMU tdie0", "2", 72), ("bad", nil, -9200)])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result["HID:PMU tdie0:1"], 68)
        XCTAssertEqual(result["HID:PMU tdie0:2"], 72)
    }
    func testRPMUsesHardwareMinimumRatherThanZero() throws {
        let fan = try JSONDecoder().decode(FanReading.self, from: Data("{\"id\":0,\"current\":2000,\"minimum\":1200,\"maximum\":6000}".utf8))
        XCTAssertEqual(fan.rpm(percent: 0), 1200)
        XCTAssertEqual(fan.rpm(percent: 50), 3600)
        XCTAssertEqual(fan.rpm(percent: 100), 6000)
    }
}


extension SMCHardwareTests {
    func testManualModePrecedesTargetAndRoundsRPM() throws {
        let io = try IO()
        io.ignoreAutomaticTargets = true
        let controller = LeasedFanController(io: io, sleep: { _ in XCTFail("Unexpected retry") })
        try controller.set(fan: 0, percent: 50.01, now: 100)
        XCTAssertEqual(Array(io.writes.prefix(2)), ["F0Md", "F0Tg"])
        XCTAssertEqual(io.values["F0Tg"]?.number, 3600)
    }
    func testDelayedTargetConvergesWithinBoundedRetries() throws {
        let io = try IO(); io.ignoredTargets = 2
        var delays: [TimeInterval] = []
        let controller = LeasedFanController(io: io, sleep: { delays.append($0) })
        try controller.set(fan: 0, percent: 50, now: 100)
        XCTAssertEqual(delays, [0.1, 0.1])
        XCTAssertEqual(io.writes.filter { $0 == "F0Tg" }.count, 3)
        XCTAssertEqual(io.values["F0Md"]?.number, 1)
    }
    func testPersistentMismatchReportsDetailsAndRestores() throws {
        let io = try IO(); io.failReadback = true
        let controller = LeasedFanController(io: io, sleep: { _ in })
        XCTAssertThrowsError(try controller.set(fan: 0, percent: 50, now: 100)) { error in
            for text in ["F0Tg", "expected=3600", "readback=", "encoding=fpe2", "mode=manual", "3 attempts"] {
                XCTAssertTrue(error.localizedDescription.contains(text), error.localizedDescription)
            }
        }
        XCTAssertEqual(io.writes.filter { $0 == "F0Tg" }.count, 3)
        XCTAssertEqual(io.values["F0Md"]?.number, 0)
    }
    func testManualFailureNeverWritesTarget() throws {
        let io = try IO(); io.rejectManual = true
        let controller = LeasedFanController(io: io, sleep: { _ in })
        XCTAssertThrowsError(try controller.set(fan: 0, percent: 50, now: 100))
        XCTAssertFalse(io.writes.contains("F0Tg"))
        XCTAssertEqual(io.values["F0Md"]?.number, 0)
    }
    func testFailedReleaseRemainsPendingWithoutDiscovery() throws {
        let io = try IO()
        let controller = LeasedFanController(io: io, sleep: { _ in })
        try controller.set(fan: 0, percent: 50, now: 100)
        io.rejectAutomatic = true
        XCTAssertThrowsError(try controller.apply(demands: [:], now: 101)) { error in
            XCTAssertTrue(error.localizedDescription.contains("restoration failed"))
        }
        io.values["FNum"] = nil
        io.rejectAutomatic = false
        XCTAssertThrowsError(try controller.restore()) // discovery still fails, but known fan is released
        XCTAssertEqual(io.values["F0Md"]?.number, 0)
        let count = io.writes.count
        try controller.expire(now: 106)
        XCTAssertEqual(io.writes.count, count)
    }
}


extension SMCHardwareTests {
    func testDelayedManualModeRetriesBeforeTarget() throws {
        let io = try IO(); io.ignoredModes = 7
        var delays: [TimeInterval] = []
        let controller = LeasedFanController(io: io, sleep: { delays.append($0) }, clock: { 0 })
        try controller.set(fan: 0, percent: 50, now: 100)
        XCTAssertEqual(delays, Array(repeating: 0.25, count: 7))
        XCTAssertEqual(io.writes.filter { $0 == "F0Md" }.count, 8)
        XCTAssertEqual(io.writes.last, "F0Tg")
    }
    func testWritableUnlockAndPendingReset() throws {
        let io = try IO(); io.requiresUnlock = true
        io.values["Ftst"] = SMCValue(type: "ui8 ", bytes: [0])
        let controller = LeasedFanController(io: io, sleep: { _ in }, clock: { 0 })
        try controller.set(fan: 0, percent: 50, now: 100)
        XCTAssertEqual(Array(io.writes.prefix(3)), ["Ftst", "F0Md", "F0Tg"])
        io.rejectAutomatic = true
        XCTAssertThrowsError(try controller.restore())
        XCTAssertEqual(io.values["Ftst"]?.number, 1)
        io.rejectAutomatic = false; io.rejectUnlockClear = true
        XCTAssertThrowsError(try controller.restore())
        io.rejectUnlockClear = false
        try controller.expire(now: 106)
        XCTAssertEqual(io.values["Ftst"]?.number, 0)
    }
    func testUnsupportedUnlockNeverWrittenAndManualRemainsStrict() throws {
        for present in [false, true] {
            let io = try IO(); io.requiresUnlock = true
            if present {
                io.values["Ftst"] = SMCValue(type: "ui8 ", bytes: [0])
                io.metadataOverrides["Ftst"] = SMCKeyMetadata(type: "ui8 ", size: 1, attributes: 0)
            }
            let controller = LeasedFanController(io: io, sleep: { _ in }, clock: { 0 })
            XCTAssertThrowsError(try controller.set(fan: 0, percent: 50, now: 100))
            XCTAssertFalse(io.writes.contains("Ftst"))
            XCTAssertFalse(io.writes.contains("F0Tg"))
        }
    }
    func testFloatPrefersLowercaseAndSnapshotUsesSameMode() throws {
        let io = try IO()
        io.values["F0Tg"] = try SMCValue.encode(2000, type: "flt ")
        io.values["F0md"] = SMCValue(type: "ui8 ", bytes: [0])
        let controller = LeasedFanController(io: io, sleep: { _ in }, clock: { 0 })
        try controller.set(fan: 0, percent: 50, now: 100)
        XCTAssertTrue(io.writes.contains("F0md"))
        XCTAssertFalse(io.writes.contains("F0Md"))
        XCTAssertEqual(try SMCMonitor.snapshot(io: io, temperatureKeys: []).fans.first?.manual, true)
        io.values["F0md"] = nil
        XCTAssertEqual(try FanModeDiscovery.key(io: io, fan: 0), "F0Md")
    }
    func testPreexistingUnlockIsNotCleared() throws {
        let io = try IO(); io.values["Ftst"] = SMCValue(type: "ui8 ", bytes: [1])
        let controller = LeasedFanController(io: io, sleep: { _ in }, clock: { 0 })
        try controller.set(fan: 0, percent: 50, now: 100)
        try controller.restore()
        XCTAssertEqual(io.values["Ftst"]?.number, 1)
    }
    func testLeaseBeginsAfterSuccessfulVerification() throws {
        let io = try IO(); io.ignoredModes = 3
        var uptime = 0.0
        let controller = LeasedFanController(io: io, sleep: { uptime += $0 }, clock: { uptime })
        try controller.set(fan: 0, percent: 50, now: 100)
        try controller.expire(now: 105)
        XCTAssertEqual(io.values["F0Md"]?.number, 1)
        try controller.expire(now: 105.75)
        XCTAssertEqual(io.values["F0Md"]?.number, 0)
    }
}

extension UserConfigurationStoreTests {
    func testFanAssignmentsRejectDisabledDuplicatesAndRetargetAtPersistence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.jsonc")
        let store = UserConfigurationStore()
        var config = UserConfiguration.migratedHammerspoonDefault()
        config.fans.rules = [FanRule(fan: 7)]
        try store.save(config, to: url)
        XCTAssertThrowsError(try store.update(at: url) { latest in
            var duplicate = FanRule(fan: 7); duplicate.enabled = false
            latest.fans.rules.append(duplicate)
        })
        XCTAssertThrowsError(try store.update(at: url) { $0.fans.rules[0].fan = 9 })
        XCTAssertEqual(try store.load(from: url).fans.rules, config.fans.rules)
    }

    func testLegacyDuplicateFansRemainVisibleButSuspendAllDemands() throws {
        var settings = FanSettings()
        var disabled = FanRule(fan: 7); disabled.enabled = false
        settings.rules = [FanRule(fan: 7), disabled]
        XCTAssertEqual(settings.duplicateFanIDs, [7])
        XCTAssertNil(settings.demands(readings: ["CPU": 70]))
        settings.rules.removeLast()
        XCTAssertNotNil(settings.demands(readings: ["CPU": 70]))
    }

    func testLegacyRuleIdentityIsStableAndNewRulesKeepIdentityAcrossRoundTrip() throws {
        let data = Data(#"{"rules":[{"sensor":"CPU","fan":7,"points":[]},{"sensor":"CPU","fan":7,"points":[]}]}"#.utf8)
        let first = try JSONDecoder().decode(FanSettings.self, from: data)
        let second = try JSONDecoder().decode(FanSettings.self, from: data)
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first.rules[0].id, first.rules[1].id)
        XCTAssertEqual(first, try JSONDecoder().decode(FanSettings.self, from: JSONEncoder().encode(first)))
    }
}
