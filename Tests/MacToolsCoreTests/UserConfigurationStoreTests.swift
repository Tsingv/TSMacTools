import XCTest
import MacToolsCore

final class UserConfigurationStoreTests: XCTestCase {
    func testBootstrapCreatesDefaultConfiguration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = UserConfigurationStore()
        let result = try store.bootstrap(at: root)

        XCTAssertTrue(result.createdConfig)
        XCTAssertEqual(result.configuration.application.terminalBundleIdentifier, "net.kovidgoyal.kitty")
        XCTAssertEqual(result.configuration.translation.nativeWindow.id, "translate")
        XCTAssertEqual(result.configuration.translation.model, "qwen/qwen3.6-27b")
        XCTAssertFalse(result.configuration.translation.thinkingEnabled)
        XCTAssertEqual(result.configuration.translation.thinkingParameter, "include_reasoning")
        XCTAssertEqual(result.configuration.translation.contextWindowTokens, 262144)
        XCTAssertEqual(result.configuration.translation.outputTokenLimit, 65536)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.configURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.scriptsDirectoryURL.path))
        XCTAssertTrue(result.createdTranslationScript)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.translationScriptURL.path))
        XCTAssertEqual(result.configuration.scripting.pythonPath, "/usr/bin/python3")

        let configText = try String(contentsOf: result.configURL, encoding: .utf8)
        XCTAssertTrue(configText.contains("// TSMacTools user configuration."))
        XCTAssertTrue(configText.contains(#""hotkeys" : ["#))
        XCTAssertTrue(configText.contains(#""scripting" : {"#))
        XCTAssertTrue(configText.contains(#""thinkingEnabled" : false"#))
        XCTAssertTrue(configText.contains(#""thinkingParameter" : "include_reasoning""#))
        XCTAssertTrue(configText.contains(#""contextWindowTokens" : 262144"#))
        XCTAssertTrue(configText.contains(#""outputTokenLimit" : 65536"#))
        XCTAssertFalse(configText.contains(#""version":"#))
        XCTAssertFalse(configText.contains(#""configDirectoryName":"#))

        let scriptText = try String(contentsOf: result.translationScriptURL, encoding: .utf8)
        XCTAssertTrue(scriptText.contains(#"translation.get("thinkingParameter") == "enable_thinking""#))
        XCTAssertTrue(scriptText.contains(#"translation.get("thinkingParameter") == "include_reasoning""#))
        XCTAssertTrue(scriptText.contains(#"body["include_reasoning"]"#))
        XCTAssertTrue(scriptText.contains(#"def collect_text(value):"#))
        XCTAssertTrue(scriptText.contains(#"def validate_token_budget(translation, messages, output_token_limit):"#))
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
            .replacingOccurrences(of: #"    "thinkingEnabled" : false,"# + "\n", with: "")

        let configuration = try store.decodeConfiguration(from: Data(legacyText.utf8))

        XCTAssertFalse(configuration.translation.thinkingEnabled)
        XCTAssertEqual(configuration.translation.thinkingParameter, "include_reasoning")
        XCTAssertEqual(configuration.translation.contextWindowTokens, 262144)
        XCTAssertEqual(configuration.translation.outputTokenLimit, 65536)
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
}
