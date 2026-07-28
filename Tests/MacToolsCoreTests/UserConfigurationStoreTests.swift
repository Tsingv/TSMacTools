import XCTest
import MacToolsCore

final class UserConfigurationStoreTests: XCTestCase {
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
