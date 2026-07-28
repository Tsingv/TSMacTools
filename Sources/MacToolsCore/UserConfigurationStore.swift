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

private struct JSONCLayoutEditor {
    private static let hotkeyActionKeys: Set<String> = [
        "kind",
        "path",
        "bundleIdentifier",
        "function",
        "input",
        "nativeWindowID",
        "interfaceName",
        "modifiers",
        "key"
    ]

    private struct Node {
        enum Kind {
            case object([Property])
            case array([Node])
            case scalar
        }

        var range: Range<Int>
        var kind: Kind
    }

    private struct Property {
        var key: String
        var value: Node
    }

    private struct Replacement {
        var range: Range<Int>
        var bytes: [UInt8]
    }

    private enum LayoutError: Error {
        case malformedJSONC
        case unsupportedReplacement
    }

    private let source: [UInt8]

    init(source: Data) {
        self.source = Array(source)
    }

    func merging(_ replacementObject: Any) throws -> Data {
        var parser = Parser(bytes: source)
        let root = try parser.parseDocument()
        var replacements: [Replacement] = []
        try collectReplacements(node: root, replacement: replacementObject, into: &replacements)

        var result = source
        for replacement in replacements.sorted(by: { lhs, rhs in
            if lhs.range.lowerBound == rhs.range.lowerBound {
                return lhs.range.upperBound > rhs.range.upperBound
            }
            return lhs.range.lowerBound > rhs.range.lowerBound
        }) {
            result.replaceSubrange(replacement.range, with: replacement.bytes)
        }
        return Data(result)
    }

    private func collectReplacements(
        node: Node,
        replacement: Any,
        into replacements: inout [Replacement]
    ) throws {
        switch (node.kind, replacement) {
        case let (.object(properties), object as [String: Any]):
            var propertiesByKey: [String: Node] = [:]
            for property in properties { propertiesByKey[property.key] = property.value }
            for (key, value) in object {
                if let child = propertiesByKey[key] {
                    try collectReplacements(node: child, replacement: value, into: &replacements)
                }
            }

            // Codable omits nil HotkeyAction fields. When an action changes kind, known fields
            // owned by the previous kind must not remain semantically active in the JSONC text.
            // Replace only those existing values with null: decodeIfPresent restores nil while
            // comments, ordering, and unknown extension fields remain untouched.
            if let kind = object["kind"] as? String,
               HotkeyAction.Kind(rawValue: kind) != nil,
               propertiesByKey["kind"] != nil {
                for key in Self.hotkeyActionKeys where key != "kind" && object[key] == nil {
                    guard let staleValue = propertiesByKey[key] else { continue }
                    replacements.append(
                        Replacement(range: staleValue.range, bytes: Array("null".utf8))
                    )
                }
            }

            let missingKeys = object.keys.filter { propertiesByKey[$0] == nil }.sorted()
            if !missingKeys.isEmpty {
                let closingBrace = node.range.upperBound - 1
                let closeIndent = indentation(before: closingBrace)
                let childIndent = closeIndent + "  "
                let fields = try missingKeys.map { key -> String in
                    guard let value = object[key] else { throw LayoutError.unsupportedReplacement }
                    return "\(childIndent)\(try renderJSONString(key)): \(try render(value, continuationIndent: childIndent))"
                }.joined(separator: ",\n")
                let prefix = properties.isEmpty ? "" : ","
                let insertion = "\(prefix)\n\(fields)\n\(closeIndent)"
                replacements.append(
                    Replacement(range: closingBrace ..< closingBrace, bytes: Array(insertion.utf8))
                )
            }

        case let (.array(children), array as [Any]) where children.count == array.count:
            for (child, value) in zip(children, array) {
                try collectReplacements(node: child, replacement: value, into: &replacements)
            }

        case (.scalar, _):
            replacements.append(
                Replacement(
                    range: node.range,
                    bytes: Array(try render(replacement, continuationIndent: indentation(before: node.range.lowerBound)).utf8)
                )
            )

        default:
            replacements.append(
                Replacement(
                    range: node.range,
                    bytes: Array(try render(replacement, continuationIndent: indentation(before: node.range.lowerBound)).utf8)
                )
            )
        }
    }

    private func render(_ value: Any, continuationIndent: String) throws -> String {
        guard JSONSerialization.isValidJSONObject([value]) else {
            throw LayoutError.unsupportedReplacement
        }
        let wrapped = try JSONSerialization.data(
            withJSONObject: [value],
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        guard var text = String(data: wrapped, encoding: .utf8),
              let firstNewline = text.firstIndex(of: "\n"),
              let lastNewline = text.lastIndex(of: "\n"),
              firstNewline < lastNewline else {
            throw LayoutError.unsupportedReplacement
        }
        text = String(text[text.index(after: firstNewline) ..< lastNewline])
        if text.hasPrefix("  ") { text.removeFirst(2) }
        return text.replacingOccurrences(of: "\n  ", with: "\n\(continuationIndent)")
    }

    private func renderJSONString(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [value])
        guard let text = String(data: data, encoding: .utf8), text.count >= 2 else {
            throw LayoutError.unsupportedReplacement
        }
        return String(text.dropFirst().dropLast())
    }

    private func indentation(before offset: Int) -> String {
        guard offset > 0 else { return "" }
        var start = offset
        while start > 0, source[start - 1] != 10, source[start - 1] != 13 { start -= 1 }
        var end = start
        while end < offset, source[end] == 32 || source[end] == 9 { end += 1 }
        return String(decoding: source[start ..< end], as: UTF8.self)
    }

    private struct Parser {
        let bytes: [UInt8]
        var offset = 0

        mutating func parseDocument() throws -> Node {
            try skipTrivia()
            let node = try parseValue()
            try skipTrivia()
            guard offset == bytes.count else { throw LayoutError.malformedJSONC }
            return node
        }

        private mutating func parseValue() throws -> Node {
            try skipTrivia()
            guard offset < bytes.count else { throw LayoutError.malformedJSONC }
            switch bytes[offset] {
            case 123: return try parseObject() // {
            case 91: return try parseArray() // [
            case 34:
                let range = try parseStringRange()
                return Node(range: range, kind: .scalar)
            default:
                return try parseScalar()
            }
        }

        private mutating func parseObject() throws -> Node {
            let start = offset
            offset += 1
            try skipTrivia()
            var properties: [Property] = []
            if consume(125) { // }
                return Node(range: start ..< offset, kind: .object(properties))
            }

            while true {
                try skipTrivia()
                let keyRange = try parseStringRange()
                let keyData = Data(bytes[keyRange])
                let key = try JSONDecoder().decode(String.self, from: keyData)
                try skipTrivia()
                guard consume(58) else { throw LayoutError.malformedJSONC } // :
                let value = try parseValue()
                properties.append(Property(key: key, value: value))
                try skipTrivia()
                if consume(125) { break }
                guard consume(44) else { throw LayoutError.malformedJSONC } // ,
                try skipTrivia()
                if consume(125) { break }
            }
            return Node(range: start ..< offset, kind: .object(properties))
        }

        private mutating func parseArray() throws -> Node {
            let start = offset
            offset += 1
            try skipTrivia()
            var children: [Node] = []
            if consume(93) { // ]
                return Node(range: start ..< offset, kind: .array(children))
            }

            while true {
                children.append(try parseValue())
                try skipTrivia()
                if consume(93) { break }
                guard consume(44) else { throw LayoutError.malformedJSONC } // ,
                try skipTrivia()
                if consume(93) { break }
            }
            return Node(range: start ..< offset, kind: .array(children))
        }

        private mutating func parseScalar() throws -> Node {
            let start = offset
            while offset < bytes.count {
                let byte = bytes[offset]
                if byte == 44 || byte == 93 || byte == 125 || isWhitespace(byte) { break }
                if byte == 47, offset + 1 < bytes.count,
                   bytes[offset + 1] == 47 || bytes[offset + 1] == 42 {
                    break
                }
                offset += 1
            }
            guard offset > start else { throw LayoutError.malformedJSONC }
            return Node(range: start ..< offset, kind: .scalar)
        }

        private mutating func parseStringRange() throws -> Range<Int> {
            guard offset < bytes.count, bytes[offset] == 34 else {
                throw LayoutError.malformedJSONC
            }
            let start = offset
            offset += 1
            var escaping = false
            while offset < bytes.count {
                let byte = bytes[offset]
                offset += 1
                if escaping {
                    escaping = false
                } else if byte == 92 {
                    escaping = true
                } else if byte == 34 {
                    return start ..< offset
                }
            }
            throw LayoutError.malformedJSONC
        }

        private mutating func skipTrivia() throws {
            while offset < bytes.count {
                if isWhitespace(bytes[offset]) {
                    offset += 1
                    continue
                }
                guard bytes[offset] == 47, offset + 1 < bytes.count else { return }
                if bytes[offset + 1] == 47 {
                    offset += 2
                    while offset < bytes.count, bytes[offset] != 10, bytes[offset] != 13 { offset += 1 }
                } else if bytes[offset + 1] == 42 {
                    offset += 2
                    var closed = false
                    while offset + 1 < bytes.count {
                        if bytes[offset] == 42, bytes[offset + 1] == 47 {
                            offset += 2
                            closed = true
                            break
                        }
                        offset += 1
                    }
                    guard closed else { throw LayoutError.malformedJSONC }
                } else {
                    return
                }
            }
        }

        private mutating func consume(_ byte: UInt8) -> Bool {
            guard offset < bytes.count, bytes[offset] == byte else { return false }
            offset += 1
            return true
        }

        private func isWhitespace(_ byte: UInt8) -> Bool {
            byte == 32 || byte == 9 || byte == 10 || byte == 13
        }
    }
}

private enum UserConfigurationUpdateError: LocalizedError {
    case coordinationDidNotRun
    case concurrentModification

    var errorDescription: String? {
        switch self {
        case .coordinationDidNotRun:
            "The configuration file could not be coordinated for writing."
        case .concurrentModification:
            "The configuration changed repeatedly while Settings was saving. Reload it and try again."
        }
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
            configuration = try decodeConfiguration(from: data)
            createdConfig = false
        } else {
            let data = try encodeConfigurationAsJSONC(defaultConfiguration)
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

    public func decodeConfiguration(from data: Data) throws -> UserConfiguration {
        let jsoncData = Data(stripJSONComments(from: String(decoding: data, as: UTF8.self)).utf8)
        return try decoder.decode(UserConfiguration.self, from: jsoncData)
    }

    public func load(from configURL: URL) throws -> UserConfiguration {
        try decodeConfiguration(from: Data(contentsOf: configURL))
    }

    public func encodeConfigurationAsJSONC(_ configuration: UserConfiguration) throws -> Data {
        let data = try encoder.encode(configuration)
        let json = String(decoding: data, as: UTF8.self)
        let text = """
        // TSMacTools user configuration.
        // This file is JSONC: regular JSON with // and /* */ comments.
        // The default path is ~/.config/tsmactool/config.jsonc.
        \(json)
        """
        return Data(text.utf8)
    }

    public func save(_ configuration: UserConfiguration, to configURL: URL) throws {
        let data = try encodeConfigurationAsJSONC(configuration)
        try data.write(to: configURL, options: [.atomic])
    }

    /// Reloads the latest file, applies one settings mutation, and changes only matching JSON
    /// values in the existing JSONC text. Comments, property order, and unknown extension fields
    /// therefore survive settings-window edits. Reloading before the mutation also prevents a
    /// long-lived settings window from overwriting unrelated edits made in a text editor.
    /// The mutation can be replayed if a non-coordinating writer changes the file during the
    /// operation, so callers should keep it deterministic and free of external side effects.
    @discardableResult
    public func update(
        at configURL: URL,
        mutation: (inout UserConfiguration) throws -> Void
    ) throws -> UserConfiguration {
        var coordinationError: NSError?
        var coordinatedResult: Result<UserConfiguration, Error>?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            writingItemAt: configURL,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            coordinatedResult = Result {
                for _ in 0 ..< 3 {
                    let original = try Data(contentsOf: coordinatedURL)
                    var configuration = try decodeConfiguration(from: original)
                    try mutation(&configuration)

                    let encoded = try encoder.encode(configuration)
                    let replacementObject = try JSONSerialization.jsonObject(
                        with: encoded,
                        options: [.fragmentsAllowed]
                    )
                    let updated = try JSONCLayoutEditor(source: original).merging(replacementObject)

                    // Validate the exact bytes that will be committed. A parser/layout bug must
                    // never replace a working user configuration with an unreadable file.
                    let validated = try decodeConfiguration(from: updated)
                    guard validated == configuration else {
                        throw CocoaError(.fileWriteUnknown)
                    }

                    // NSFileCoordinator serializes cooperating editors. The byte comparison also
                    // catches command-line/non-coordinating writers before the atomic replace.
                    guard try Data(contentsOf: coordinatedURL) == original else { continue }
                    try updated.write(to: coordinatedURL, options: [.atomic])
                    return configuration
                }
                throw UserConfigurationUpdateError.concurrentModification
            }
        }
        if let coordinationError { throw coordinationError }
        guard let coordinatedResult else {
            throw UserConfigurationUpdateError.coordinationDidNotRun
        }
        return try coordinatedResult.get()
    }

    private func stripJSONComments(from text: String) -> String {
        var result = ""
        var iterator = text.makeIterator()
        var inString = false
        var escaping = false

        while let character = iterator.next() {
            if inString {
                result.append(character)
                if escaping {
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }

            if character == "\"" {
                inString = true
                result.append(character)
                continue
            }

            if character == "/" {
                guard let next = iterator.next() else {
                    result.append(character)
                    break
                }
                if next == "/" {
                    while let skipped = iterator.next(), skipped != "\n" {}
                    result.append("\n")
                } else if next == "*" {
                    var previous: Character?
                    while let skipped = iterator.next() {
                        if previous == "*" && skipped == "/" {
                            break
                        }
                        if skipped == "\n" {
                            result.append("\n")
                        }
                        previous = skipped
                    }
                } else {
                    result.append(character)
                    result.append(next)
                }
                continue
            }

            result.append(character)
        }

        return result
    }

    private static let defaultTranslationScript = """
    #!/usr/bin/env python3
    import html
    import json
    import re
    import sys
    import urllib.error
    import urllib.parse
    import urllib.request


    class TranslationBudgetError(Exception):
        pass


    def collect_text(value):
        if isinstance(value, str):
            return value.strip()
        if isinstance(value, list):
            chunks = []
            for item in value:
                if isinstance(item, str):
                    chunks.append(item)
                elif isinstance(item, dict):
                    chunks.append(collect_text(item.get("text") or item.get("output_text") or item.get("content")))
            return "\\n".join(chunk for chunk in chunks if chunk).strip()
        return ""


    def extract_text(response):
        choices = response.get("choices") or []
        saw_reasoning = False
        for choice in choices:
            message = choice.get("message") or {}
            text = collect_text(message.get("content"))
            if text:
                return text
            text = collect_text(choice.get("text") or choice.get("output_text") or choice.get("content"))
            if text:
                return text
            saw_reasoning = saw_reasoning or bool(message.get("reasoning_content") or message.get("reasoning"))

        text = collect_text(response.get("output_text") or response.get("text") or response.get("content"))
        if text:
            return text
        if saw_reasoning:
            return (
                "The provider returned reasoning data but no final translation text. "
                "Try setting translation.thinkingParameter to \\"reasoning_format\\", \\"enable_thinking\\", or \\"none\\" "
                "for your endpoint."
            )
        return "The provider response did not contain translation text."


    def log_response_summary(response):
        choices = response.get("choices") or []
        choice = choices[0] if choices else {}
        message = choice.get("message") or {}
        usage = response.get("usage") or {}
        details = usage.get("completion_tokens_details") or {}
        print(
            "[translate] "
            f"finish_reason={choice.get('finish_reason')} "
            f"content_len={len(message.get('content') or '')} "
            f"completion_tokens={usage.get('completion_tokens')} "
            f"reasoning_tokens={details.get('reasoning_tokens')} "
            f"model={response.get('model')}",
            file=sys.stderr,
            flush=True,
        )


    def format_http_error(error):
        body = error.read().decode("utf-8", errors="replace").strip()
        if not body:
            return f"HTTP {error.code}: {error.reason}"

        try:
            payload = json.loads(body)
        except json.JSONDecodeError:
            return f"HTTP {error.code}: {error.reason}\\n\\n{body}"

        details = payload.get("error") if isinstance(payload, dict) else None
        if isinstance(details, dict):
            message = details.get("message") or body
            metadata = []
            if details.get("type"):
                metadata.append(f"Type: {details['type']}")
            if details.get("code"):
                metadata.append(f"Code: {details['code']}")
            if details.get("param"):
                metadata.append(f"Param: {details['param']}")
            suffix = "\\n".join(metadata)
            return f"HTTP {error.code}: {message}" + (f"\\n\\n{suffix}" if suffix else "")

        return f"HTTP {error.code}: {error.reason}\\n\\n{body}"


    def contains_cjk(text):
        return any("\\u4e00" <= character <= "\\u9fff" for character in text)


    def is_cjk_character(character):
        return "\\u4e00" <= character <= "\\u9fff"


    def is_structural_line(line):
        stripped = line.strip()
        return bool(
            re.match(r"^(```|~~~)", stripped)
            or re.match(r"^([-*+]|[0-9]+[.)]|[A-Za-z][.)])\\s+", stripped)
            or re.match(r"^\\|.*\\|$", stripped)
            or re.match(r"^\\s{2,}\\S", line)
        )


    def join_wrapped_lines(lines):
        if any(is_structural_line(line) for line in lines):
            return "\\n".join(line.strip() for line in lines).strip()

        output = lines[0].strip()
        for raw_line in lines[1:]:
            line = raw_line.strip()
            if not line:
                continue
            previous = output[-1] if output else ""
            next_character = line[0]
            if previous == "-" and len(output) >= 2 and output[-2].isalpha() and next_character.isalpha():
                output = output[:-1] + line
            elif is_cjk_character(previous) and is_cjk_character(next_character):
                output += line
            elif previous in "([{/" or next_character in ".,;:!?)]}%":
                output += line
            else:
                output += " " + line
        return output.strip()


    def normalize_source_text(source_text):
        text = source_text.replace("\\r\\n", "\\n").replace("\\r", "\\n").strip()
        if not config["translation"].get("normalizePDFLineBreaks", True):
            return text

        paragraphs = []
        current = []
        for line in text.split("\\n"):
            if line.strip():
                current.append(line)
            elif current:
                paragraphs.append(join_wrapped_lines(current))
                current = []
        if current:
            paragraphs.append(join_wrapped_lines(current))
        return "\\n\\n".join(paragraph for paragraph in paragraphs if paragraph).strip()


    def target_language_for_text(translation, source_text):
        if contains_cjk(source_text):
            return translation.get("googleTargetLanguageForChinese", "en")
        return translation.get("googleTargetLanguage", "zh-CN")


    def google_translate_url(endpoint, api_key):
        parts = urllib.parse.urlsplit(endpoint)
        query = dict(urllib.parse.parse_qsl(parts.query, keep_blank_values=True))
        query["key"] = api_key
        return urllib.parse.urlunsplit(
            (parts.scheme, parts.netloc, parts.path, urllib.parse.urlencode(query), parts.fragment)
        )


    def request_google_translation(source_text):
        translation = config["translation"]
        api_key = translation.get("googleApiKey", "").strip()
        if not api_key:
            raise TranslationBudgetError(
                "Google translation is enabled, but translation.googleApiKey is empty.\\n\\n"
                "Create a Google Cloud Translation API key and set it in config.jsonc."
            )

        target_language = target_language_for_text(translation, source_text)
        body = {
            "q": source_text,
            "target": target_language,
            "format": "text",
        }
        source_language = translation.get("googleSourceLanguage", "auto")
        if source_language and source_language != "auto":
            body["source"] = source_language

        request = urllib.request.Request(
            google_translate_url(
                translation.get("googleEndpoint", "https://translation.googleapis.com/language/translate/v2"),
                api_key,
            ),
            data=json.dumps(body).encode("utf-8"),
            headers={"Content-Type": "application/json; charset=utf-8"},
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=60) as response:
            response_json = json.loads(response.read().decode("utf-8"))

        translations = ((response_json.get("data") or {}).get("translations") or [])
        if not translations:
            return "The Google translation response did not contain translation text."

        translated_text = "\\n".join(
            html.unescape(item.get("translatedText", "")).strip()
            for item in translations
            if item.get("translatedText")
        ).strip()
        if not translated_text:
            return "The Google translation response did not contain translation text."

        detected_language = translations[0].get("detectedSourceLanguage") or source_language
        print(
            "[translate] "
            f"provider=google detected={detected_language} target={target_language} "
            f"content_len={len(translated_text)}",
            file=sys.stderr,
            flush=True,
        )
        return f"Google Translate ({detected_language} -> {target_language})\\n\\n{translated_text}"


    def google_web_translate_url(translation, source_text, target_language):
        params = {
            "client": translation.get("googleWebClient", "gtx"),
            "sl": translation.get("googleSourceLanguage", "auto"),
            "tl": target_language,
            "dt": "t",
            "ie": "UTF-8",
            "oe": "UTF-8",
            "q": source_text,
        }
        endpoint = translation.get("googleWebEndpoint", "https://translate.googleapis.com/translate_a/single")
        separator = "&" if urllib.parse.urlsplit(endpoint).query else "?"
        return endpoint + separator + urllib.parse.urlencode(params)


    def extract_google_web_text(response):
        segments = response[0] if isinstance(response, list) and response else []
        if not isinstance(segments, list):
            return ""
        translated_parts = []
        for segment in segments:
            if isinstance(segment, list) and segment and isinstance(segment[0], str):
                translated_parts.append(segment[0])
        return html.unescape("".join(translated_parts)).strip()


    def request_google_web_translation(source_text):
        translation = config["translation"]
        target_language = target_language_for_text(translation, source_text)
        request = urllib.request.Request(
            google_web_translate_url(translation, source_text, target_language),
            headers={"User-Agent": "Mozilla/5.0"},
            method="GET",
        )
        with urllib.request.urlopen(request, timeout=60) as response:
            response_json = json.loads(response.read().decode("utf-8"))

        translated_text = extract_google_web_text(response_json)
        if not translated_text:
            return "The Google web translation response did not contain translation text."

        detected_language = response_json[2] if len(response_json) > 2 and isinstance(response_json[2], str) else "auto"
        print(
            "[translate] "
            f"provider=google_web detected={detected_language} target={target_language} "
            f"content_len={len(translated_text)}",
            file=sys.stderr,
            flush=True,
        )
        return f"Google Web Translate ({detected_language} -> {target_language})\\n\\n{translated_text}"


    def estimate_token_count(text):
        cjk_count = sum(1 for character in text if "\\u4e00" <= character <= "\\u9fff")
        non_cjk_count = len(text) - cjk_count
        return cjk_count + max(1, (non_cjk_count + 3) // 4)


    def estimate_message_tokens(messages):
        total = 16
        for message in messages:
            total += 16
            total += estimate_token_count(message.get("content", ""))
        return total


    def resolve_output_token_limit(translation, messages, output_token_limit):
        context_window = int(translation.get("contextWindowTokens", 262144) or 0)
        request_token_limit = int(translation.get("requestTokenLimit", 8000) or 0)
        prompt_tokens = estimate_message_tokens(messages)

        if context_window > 0 and output_token_limit > 0 and prompt_tokens + output_token_limit > context_window:
            available_input = max(context_window - output_token_limit, 0)
            raise TranslationBudgetError(
                "Selected text is too long for the configured model budget.\\n\\n"
                f"Estimated prompt tokens: {prompt_tokens}\\n"
                f"Configured output tokens: {output_token_limit}\\n"
                f"Context window: {context_window}\\n"
                f"Estimated prompt budget available: {available_input}"
            )

        if request_token_limit > 0 and output_token_limit > 0 and prompt_tokens + output_token_limit > request_token_limit:
            adjusted_limit = max(request_token_limit - prompt_tokens, 0)
            if adjusted_limit <= 0:
                raise TranslationBudgetError(
                    "Selected text is too long for the configured request token budget.\\n\\n"
                    f"Estimated prompt tokens: {prompt_tokens}\\n"
                    f"Request token limit: {request_token_limit}\\n"
                    "Increase translation.requestTokenLimit for a higher service tier or select less text."
                )
            print(
                "[translate] "
                f"clamped max_completion_tokens={adjusted_limit} "
                f"from configured={output_token_limit} "
                f"requestTokenLimit={request_token_limit} "
                f"prompt_estimate={prompt_tokens}",
                file=sys.stderr,
                flush=True,
            )
            return adjusted_limit

        return output_token_limit


    def request_llm_translation(source_text):
        translation = config["translation"]
        prompt = translation["promptTemplate"].replace("{{sourceText}}", source_text)
        messages = []
        if translation.get("systemPrompt"):
            messages.append({"role": "system", "content": translation["systemPrompt"]})
        messages.append({"role": "user", "content": prompt})

        body = {
            "model": translation["model"],
            "temperature": translation["temperature"],
            "messages": messages,
        }
        output_token_limit = int(translation.get("outputTokenLimit", 2048) or 0)
        output_token_limit = resolve_output_token_limit(translation, messages, output_token_limit)
        if output_token_limit > 0:
            body["max_completion_tokens"] = output_token_limit
        if translation.get("thinkingParameter") == "enable_thinking":
            body["enable_thinking"] = bool(translation.get("thinkingEnabled", False))
        elif translation.get("thinkingParameter") == "include_reasoning":
            body["include_reasoning"] = bool(translation.get("thinkingEnabled", False))
        elif translation.get("thinkingParameter") == "reasoning_format":
            body["reasoning_format"] = "raw" if translation.get("thinkingEnabled", False) else "hidden"
        body = json.dumps(body).encode("utf-8")

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
            response_json = json.loads(response.read().decode("utf-8"))
            log_response_summary(response_json)
            return extract_text(response_json)


    def request_translation(source_text):
        provider = config["translation"].get("provider", "llm").lower()
        if provider == "google_web":
            return request_google_web_translation(source_text)
        if provider == "google":
            return request_google_translation(source_text)
        if provider == "llm":
            return request_llm_translation(source_text)
        raise TranslationBudgetError(f"Unsupported translation.provider: {provider}")


    def emit_window_command(source_text, translated_text, status_text="Ready"):
        window = config["translation"]["nativeWindow"]
        body = f\"\"\"# Translation

    **Status:** {status_text}

    ## Source

    {source_text}

    ## Result

    {translated_text}
    \"\"\"
        nativewindow.show(window["id"], window["title"], body, window["format"])


    def main():
        source_text = normalize_source_text(input_text)
        if not source_text:
            emit_window_command("", "No selected text was provided.", "Missing source")
            return 1

        try:
            translated_text = request_translation(source_text)
        except TranslationBudgetError as error:
            emit_window_command(source_text, str(error), "Budget exceeded")
            return 1
        except urllib.error.HTTPError as error:
            message = format_http_error(error)
            print(f"[translate] request failed {message}", file=sys.stderr, flush=True)
            emit_window_command(source_text, message, "Request failed")
            return 1
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as error:
            emit_window_command(source_text, str(error), "Request failed")
            return 1

        emit_window_command(source_text, translated_text)
        return 0
    """
}
