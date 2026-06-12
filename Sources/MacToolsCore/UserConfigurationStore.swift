import Foundation

public struct UserConfigurationBootstrapResult: Equatable, Sendable {
    public var directoryURL: URL
    public var configURL: URL
    public var scriptsDirectoryURL: URL
    public var translationScriptURL: URL
    public var createdConfig: Bool
    public var createdTranslationScript: Bool
    public var configuration: UserConfiguration

    public init(
        directoryURL: URL,
        configURL: URL,
        scriptsDirectoryURL: URL,
        translationScriptURL: URL,
        createdConfig: Bool,
        createdTranslationScript: Bool,
        configuration: UserConfiguration
    ) {
        self.directoryURL = directoryURL
        self.configURL = configURL
        self.scriptsDirectoryURL = scriptsDirectoryURL
        self.translationScriptURL = translationScriptURL
        self.createdConfig = createdConfig
        self.createdTranslationScript = createdTranslationScript
        self.configuration = configuration
    }
}

public final class UserConfigurationStore {
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    }

    public func defaultDirectoryURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent(UserConfiguration.defaultDirectoryName, isDirectory: true)
    }

    public func bootstrap(
        at directoryURL: URL? = nil,
        defaultConfiguration: UserConfiguration = .migratedHammerspoonDefault()
    ) throws -> UserConfigurationBootstrapResult {
        let directoryURL = directoryURL ?? defaultDirectoryURL()
        let scriptsDirectoryURL = directoryURL.appendingPathComponent("scripts", isDirectory: true)
        let translationScriptURL = scriptsDirectoryURL.appendingPathComponent("translate_selection.py")
        let configURL = directoryURL.appendingPathComponent(UserConfiguration.defaultFileName)

        try fileManager.createDirectory(at: scriptsDirectoryURL, withIntermediateDirectories: true)

        let createdConfig: Bool
        let configuration: UserConfiguration
        if fileManager.fileExists(atPath: configURL.path) {
            let data = try Data(contentsOf: configURL)
            configuration = try decoder.decode(UserConfiguration.self, from: data)
            createdConfig = false
        } else {
            let data = try encoder.encode(defaultConfiguration)
            try data.write(to: configURL, options: [.atomic])
            configuration = defaultConfiguration
            createdConfig = true
        }

        let createdTranslationScript: Bool
        if fileManager.fileExists(atPath: translationScriptURL.path) {
            createdTranslationScript = false
        } else {
            try Self.defaultTranslationScript.write(
                to: translationScriptURL,
                atomically: true,
                encoding: .utf8
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: translationScriptURL.path
            )
            createdTranslationScript = true
        }

        return UserConfigurationBootstrapResult(
            directoryURL: directoryURL,
            configURL: configURL,
            scriptsDirectoryURL: scriptsDirectoryURL,
            translationScriptURL: translationScriptURL,
            createdConfig: createdConfig,
            createdTranslationScript: createdTranslationScript,
            configuration: configuration
        )
    }

    private static let defaultTranslationScript = """
    #!/usr/bin/env python3
    import json
    import sys
    import urllib.error
    import urllib.request
    from pathlib import Path


    CONFIG_PATH = Path.home() / ".config" / "tsmactool" / "config.json"


    def load_config():
        with CONFIG_PATH.open("r", encoding="utf-8") as file:
            return json.load(file)


    def extract_text(response):
        choices = response.get("choices") or []
        if not choices:
            return ""
        content = (choices[0].get("message") or {}).get("content")
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            return "\\n".join(
                item.get("text", "")
                for item in content
                if isinstance(item, dict) and item.get("type") == "text"
            ).strip()
        return ""


    def request_translation(config, source_text):
        translation = config["translation"]
        prompt = translation["promptTemplate"].replace("{{sourceText}}", source_text)
        messages = []
        if translation.get("systemPrompt"):
            messages.append({"role": "system", "content": translation["systemPrompt"]})
        messages.append({"role": "user", "content": prompt})

        body = json.dumps({
            "model": translation["model"],
            "temperature": translation["temperature"],
            "messages": messages,
        }).encode("utf-8")

        request = urllib.request.Request(
            translation["endpoint"],
            data=body,
            headers={
                "Authorization": f"Bearer {translation['apiKey']}",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=120) as response:
            return extract_text(json.loads(response.read().decode("utf-8")))


    def emit_window_command(config, source_text, translated_text, status_text="Ready"):
        window = config["translation"]["nativeWindow"]
        body = f\"\"\"# Translation

    **Status:** {status_text}

    ## Source

    {source_text}

    ## Result

    {translated_text}
    \"\"\"
        print(json.dumps({
            "command": "window.show",
            "id": window["id"],
            "title": window["title"],
            "format": window["format"],
            "body": body,
        }, ensure_ascii=False))


    def main():
        config = load_config()
        source_text = sys.stdin.read().strip()
        if not source_text:
            emit_window_command(config, "", "No selected text was provided.", "Missing source")
            return 1

        try:
            translated_text = request_translation(config, source_text)
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as error:
            emit_window_command(config, source_text, str(error), "Request failed")
            return 1

        emit_window_command(config, source_text, translated_text)
        return 0


    if __name__ == "__main__":
        raise SystemExit(main())
    """
}
