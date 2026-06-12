# MacTools

MacTools is a Swift-first macOS automation app inspired by Hammerspoon. The project starts with typed core automation models, a Python command bridge, and native AppKit windows that external scripts can drive.

## Quick Start

```sh
swift test
swift run MacTools
python3 scripts/emit_window_command.py
```

Open the full Xcode project with:

```sh
open MacTools.xcodeproj
```

Build and test from the command line:

```sh
xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug -derivedDataPath DerivedData build CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO
xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug -derivedDataPath DerivedData test CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO
open DerivedData/Build/Products/Debug/MacTools.app
```

Architecture notes and migration rules live in `AGENTS.md`. The local Hammerspoon reference checkout is in `references/hammerspoon`.
