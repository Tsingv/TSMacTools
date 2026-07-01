#!/usr/bin/env python3
import json
import sys
import urllib.error
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
            "Try setting translation.thinkingParameter to \"reasoning_format\", \"enable_thinking\", or \"none\" "
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


def validate_token_budget(translation, messages, output_token_limit):
    context_window = int(translation.get("contextWindowTokens", 262144) or 0)
    prompt_tokens = estimate_message_tokens(messages)

    if context_window > 0 and output_token_limit > 0 and prompt_tokens + output_token_limit > context_window:
        available_input = max(context_window - output_token_limit, 0)
        raise TranslationBudgetError(
            "Selected text is too long for the configured model budget.\n\n"
            f"Estimated prompt tokens: {prompt_tokens}\n"
            f"Configured output tokens: {output_token_limit}\n"
            f"Context window: {context_window}\n"
            f"Estimated prompt budget available: {available_input}"
        )


def request_translation(config, source_text):
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
    output_token_limit = int(translation.get("outputTokenLimit", 65536) or 0)
    validate_token_budget(translation, messages, output_token_limit)
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
    source_text = input_text.strip()
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
