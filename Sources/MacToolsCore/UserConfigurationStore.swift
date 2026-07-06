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
