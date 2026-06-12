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
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.configURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.scriptsDirectoryURL.path))
        XCTAssertTrue(result.createdTranslationScript)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.translationScriptURL.path))
        XCTAssertEqual(result.configuration.scripting.pythonPath, "/usr/bin/python3")

        let configText = try String(contentsOf: result.configURL, encoding: .utf8)
        XCTAssertTrue(configText.contains("// TSMacTools user configuration."))
        XCTAssertTrue(configText.contains(#""hotkeys" : ["#))
        XCTAssertTrue(configText.contains(#""scripting" : {"#))
        XCTAssertFalse(configText.contains(#""version":"#))
        XCTAssertFalse(configText.contains(#""configDirectoryName":"#))
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
