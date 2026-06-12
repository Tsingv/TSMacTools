# MacTools

MacTools is a Swift-first macOS automation app inspired by Hammerspoon. The project starts with typed core automation models, a Python command bridge, and native AppKit windows that external scripts can drive.

The current Xcode app target links `MacToolsCore` and `MacToolsScripting` as static libraries, and explicitly links `AppKit.framework` plus `ApplicationServices.framework`. This keeps the debug `.app` launchable while the architecture remains split into Swift modules.

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

Check whether the built app itself has Accessibility permission:

```sh
DerivedData/Build/Products/Debug/MacTools.app/Contents/MacOS/MacTools --check-accessibility
```

On first launch, MacTools checks Accessibility permission. If it is missing, macOS will show a prompt and the app will open a native permissions window. Grant access in System Settings > Privacy & Security > Accessibility, then restart the app.

Debug builds are currently ad-hoc signed. If `--check-accessibility` still prints `accessibility=missing` after granting access, remove the old MacTools entry from System Settings and add the current app at `DerivedData/Build/Products/Debug/MacTools.app`. A separate `swift` script cannot verify MacTools' permission state because TCC checks the calling process.

## Development Rule

When code changes, update both `AGENTS.md` and `README.md` in the same commit. This includes changes to architecture, build settings, permissions, scripting commands, tests, and runtime behavior.

Architecture notes and migration rules live in `AGENTS.md`. The local Hammerspoon reference checkout is in `references/hammerspoon`.
