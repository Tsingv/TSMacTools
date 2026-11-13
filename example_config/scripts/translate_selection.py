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
        return "\n".join(chunk for chunk in chunks if chunk).strip()
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
            "Increase translation.outputTokenLimit so final content can follow reasoning, "
            "or set translation.thinkingLevel to \"none\" when the model allows it."
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
        return f"HTTP {error.code}: {error.reason}\n\n{body}"

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
        suffix = "\n".join(metadata)
        return f"HTTP {error.code}: {message}" + (f"\n\n{suffix}" if suffix else "")

    return f"HTTP {error.code}: {error.reason}\n\n{body}"


def contains_cjk(text):
    return any("\u4e00" <= character <= "\u9fff" for character in text)


def is_cjk_character(character):
    return "\u4e00" <= character <= "\u9fff"


def is_structural_line(line):
    stripped = line.strip()
    return bool(
        re.match(r"^(```|~~~)", stripped)
        or re.match(r"^([-*+]|[0-9]+[.)]|[A-Za-z][.)])\s+", stripped)
        or re.match(r"^\|.*\|$", stripped)
        or re.match(r"^\s{2,}\S", line)
    )


def join_wrapped_lines(lines):
    if any(is_structural_line(line) for line in lines):
        return "\n".join(line.strip() for line in lines).strip()

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
    text = source_text.replace("\r\n", "\n").replace("\r", "\n").strip()
    if not config["translation"].get("normalizePDFLineBreaks", True):
        return text

    paragraphs = []
    current = []
    for line in text.split("\n"):
        if line.strip():
            current.append(line)
        elif current:
            paragraphs.append(join_wrapped_lines(current))
            current = []
    if current:
        paragraphs.append(join_wrapped_lines(current))
    return "\n\n".join(paragraph for paragraph in paragraphs if paragraph).strip()


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


def request_google_translation(config, source_text):
    translation = config["translation"]
    api_key = translation.get("googleApiKey", "").strip()
    if not api_key:
        raise TranslationBudgetError(
            "Google translation is enabled, but translation.googleApiKey is empty.\n\n"
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

    translated_text = "\n".join(
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
    return f"Google Translate ({detected_language} -> {target_language})\n\n{translated_text}"


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


def request_google_web_translation(config, source_text):
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
    return f"Google Web Translate ({detected_language} -> {target_language})\n\n{translated_text}"


def estimate_token_count(text):
    cjk_count = sum(1 for character in text if "\u4e00" <= character <= "\u9fff")
    non_cjk_count = len(text) - cjk_count
    return cjk_count + max(1, (non_cjk_count + 3) // 4)


def estimate_message_tokens(messages):
    total = 16
    for message in messages:
        total += 16
        total += estimate_token_count(message.get("content", ""))
    return total


def resolve_output_token_limit(translation, messages, output_token_limit):
    # Budgets are advisory only. Never reject locally; post the request and let the provider respond.
    prompt_tokens = estimate_message_tokens(messages)
    print(
        "[translate] "
        f"prompt_estimate={prompt_tokens} "
        f"contextWindowTokens={translation.get('contextWindowTokens')} "
        f"outputTokenLimit={output_token_limit} "
        f"requestTokenLimit={translation.get('requestTokenLimit')}",
        file=sys.stderr,
        flush=True,
    )
    return output_token_limit


def resolve_thinking_level(translation):
    level = str(translation.get("thinkingLevel") or "").strip().lower()
    if level in {"off", "disabled"}:
        return "none"
    if level:
        return level
    return "high" if translation.get("thinkingEnabled", False) else "none"


def apply_thinking_parameters(body, translation):
    parameter = str(translation.get("thinkingParameter") or "reasoning").strip().lower()
    level = resolve_thinking_level(translation)
    enabled = level not in {"", "none", "off"}

    # Modern OpenAI-compatible gateways advertise `reasoning` on /v1/models.
    # Legacy include_reasoning is mapped to the same effort object so older configs keep working.
    if parameter in {"", "reasoning", "auto", "include_reasoning"}:
        body["reasoning"] = {"effort": level if level else "none"}
        return
    if parameter == "enable_thinking":
        body["enable_thinking"] = enabled
        return
    if parameter == "reasoning_format":
        body["reasoning_format"] = "raw" if enabled else "hidden"
        return
    if parameter == "none":
        return
    # Unknown adapters fall back to the OpenAI-compatible reasoning effort object.
    body["reasoning"] = {"effort": level if level else "none"}


def request_llm_translation(config, source_text):
    translation = config["translation"]
    prompt = translation["promptTemplate"].replace("{{sourceText}}", source_text)
    messages = []
    if translation.get("systemPrompt"):
        messages.append({"role": "system", "content": translation["systemPrompt"]})
    messages.append({"role": "user", "content": prompt})

    body = {
        "model": translation["model"],
        "messages": messages,
    }
    output_token_limit = int(translation.get("outputTokenLimit", 2048) or 0)
    output_token_limit = resolve_output_token_limit(translation, messages, output_token_limit)
    if output_token_limit > 0:
        body["max_completion_tokens"] = output_token_limit
    apply_thinking_parameters(body, translation)
    print(
        "[translate] "
        f"model={translation.get('model')} "
        f"thinkingParameter={translation.get('thinkingParameter', 'reasoning')} "
        f"thinkingLevel={resolve_thinking_level(translation)} "
        f"max_completion_tokens={body.get('max_completion_tokens')}",
        file=sys.stderr,
        flush=True,
    )
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


def request_translation(config, source_text):
    provider = config["translation"].get("provider", "llm").lower()
    if provider == "google_web":
        return request_google_web_translation(config, source_text)
    if provider == "google":
        return request_google_translation(config, source_text)
    if provider == "llm":
        return request_llm_translation(config, source_text)
    raise TranslationBudgetError(f"Unsupported translation.provider: {provider}")


def emit_window_command(source_text, translated_text, status_text="Ready"):
    window = config["translation"]["nativeWindow"]
    body = f"""# Translation

**Status:** {status_text}

## Source

{source_text}

## Result

{translated_text}
"""
    nativewindow.show(window["id"], window["title"], body, window["format"])


def main():
    source_text = normalize_source_text(input_text)
    if not source_text:
        emit_window_command("", "No selected text was provided.", "Missing source")
        return 1

    try:
        translated_text = request_translation(config, source_text)
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
