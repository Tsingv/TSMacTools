# MacTools

MacTools is a Swift-first macOS automation app inspired by Hammerspoon. The project starts with typed core automation models, a Python command bridge, and native AppKit windows that external scripts can drive.

## Quick Start

```sh
swift test
swift run MacTools
python3 scripts/emit_window_command.py
```

Architecture notes and migration rules live in `AGENTS.md`. The local Hammerspoon reference checkout is in `references/hammerspoon`.
