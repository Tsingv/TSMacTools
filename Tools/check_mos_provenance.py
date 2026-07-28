#!/usr/bin/env python3
"""Detect exact normalized multi-line matches with the read-only Mos reference.

This is a narrow regression guard against accidentally transplanting implementation blocks. It is
not a general similarity detector or a substitute for legal review.
"""

from __future__ import annotations

import argparse
import re
import sys
from collections import defaultdict
from pathlib import Path


LOCAL_FILES = (
    Path("Sources/MacToolsCore/SmoothScrollModels.swift"),
    Path("Sources/MacToolsMacOS/SmoothScrollController.swift"),
    Path("Sources/MacToolsApp/SmoothScrollController.swift"),
    Path("Sources/MacToolsApp/SettingsWindowController.swift"),
)
REFERENCE_ROOT = Path("references/Mos/Mos")
REFERENCE_SUFFIXES = {".swift", ".m", ".mm", ".h"}


def normalized_lines(path: Path) -> list[tuple[int, str]]:
    lines: list[tuple[int, str]] = []
    for number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        without_comment = re.sub(r"//.*$", "", raw_line)
        normalized = re.sub(r"\s+", "", without_comment).strip()
        if len(normalized) >= 4:
            lines.append((number, normalized))
    return lines


def grams(
    paths: list[Path] | tuple[Path, ...], minimum_lines: int
) -> dict[str, list[tuple[Path, int]]]:
    result: dict[str, list[tuple[Path, int]]] = defaultdict(list)
    for path in paths:
        lines = normalized_lines(path)
        for index in range(len(lines) - minimum_lines + 1):
            window = lines[index : index + minimum_lines]
            result["\n".join(value for _, value in window)].append((path, window[0][0]))
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--minimum-lines", type=int, default=4)
    arguments = parser.parse_args()
    if arguments.minimum_lines < 2:
        parser.error("--minimum-lines must be at least 2")

    missing = [str(path) for path in LOCAL_FILES if not path.is_file()]
    if not REFERENCE_ROOT.is_dir():
        missing.append(str(REFERENCE_ROOT))
    if missing:
        print(f"provenance_check=unavailable missing={','.join(missing)}", file=sys.stderr)
        return 2

    reference_files = sorted(
        path
        for path in REFERENCE_ROOT.rglob("*")
        if path.is_file() and path.suffix.lower() in REFERENCE_SUFFIXES
    )
    local_grams = grams(LOCAL_FILES, arguments.minimum_lines)
    reference_grams = grams(reference_files, arguments.minimum_lines)
    matches = sorted(set(local_grams).intersection(reference_grams))
    if matches:
        print(
            f"provenance_check=failed exact_matches={len(matches)} "
            f"minimum_lines={arguments.minimum_lines}",
            file=sys.stderr,
        )
        for match in matches[:20]:
            local = ", ".join(f"{path}:{line}" for path, line in local_grams[match])
            reference = ", ".join(f"{path}:{line}" for path, line in reference_grams[match])
            print(f"local={local} reference={reference}", file=sys.stderr)
        return 1

    print(
        "provenance_check=passed "
        f"local_files={len(LOCAL_FILES)} reference_files={len(reference_files)} "
        f"minimum_lines={arguments.minimum_lines}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
