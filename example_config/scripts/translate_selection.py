#!/usr/bin/env python3
import json
import urllib.error
import urllib.request


def extract_text(response):
    choices = response.get("choices") or []
    if not choices:
        return ""
    content = (choices[0].get("message") or {}).get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(
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
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as error:
        emit_window_command(source_text, str(error), "Request failed")
        return 1

    emit_window_command(source_text, translated_text)
    return 0
