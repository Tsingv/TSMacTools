# TSMacTools

TSMacTools is a Swift-first macOS automation app inspired by Hammerspoon. The project starts with typed core automation models, a Python command bridge, user configuration under `~/.config/tsmactool`, and native AppKit windows that external scripts can drive.

The current Xcode app target links `MacToolsCore` and `MacToolsScripting` as static libraries, and explicitly links `AppKit.framework` plus `ApplicationServices.framework`. This keeps the debug `.app` launchable while the architecture remains split into Swift modules.

## Quick Start

```sh
swift test
swift run MacTools
```

Open the full Xcode project with:

```sh
open MacTools.xcodeproj
```

Build and test from the command line:

```sh
xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug -derivedDataPath DerivedData build
xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug -derivedDataPath DerivedData test
open DerivedData/Build/Products/Debug/TSMacTools.app
```

Check whether the built app itself has Accessibility permission:

```sh
DerivedData/Build/Products/Debug/TSMacTools.app/Contents/MacOS/TSMacTools --check-accessibility
```

On first launch, TSMacTools creates `~/.config/tsmactool/config.jsonc` and `~/.config/tsmactool/scripts`, then stays in the macOS menu bar without occupying Dock space. `config.jsonc` is one normal JSON object with `//` and `/* */` comments allowed. The default config omits derived development-only fields such as `version`, hotkey `id`, `application.name`, and `application.configDirectoryName`.

The repository keeps a tracked example at `example_config/config.jsonc` plus `example_config/scripts`. Local development uses untracked `my_config`, and `~/.config/tsmactool` can be a symlink to that folder. Keep real API keys and personal edits in `my_config`; keep `example_config` complete, commented, and safe to commit.

Set `scripting.pythonPath` to the Python executable TSMacTools should use. Hotkey actions can call built-in Swift interfaces or run user Python scripts. Use `{"kind":"callInterface","interfaceName":"reloadConfiguration"}` for app-provided behavior, or `{"kind":"runScript","path":"scripts/translate_selection.py","function":"main","input":"selectedText","nativeWindowID":"translate"}` to send selected text to a script function. The app loads config once, injects `config`, `input_text`, `nativewindow`, and `window` globals into the script module, then calls the configured function. Scripts do not read `~/.config/tsmactool/config.jsonc` themselves.

The default config is a typed migration of the current Hammerspoon setup: app focus hotkeys, Finder/terminal toggles, command-tab style window switching preferences, and the LLM translation settings. The translation path now targets a floating `window.show` native window instead of Hammerspoon `hs.webview`; that window appears immediately with a spinning `Translating...` state while the script is running, follows light/dark mode, closes when it loses focus by default, and can be pinned from its title bar so later translations update the same long-lived window.

The window switcher is controlled by the `windowSwitcher` section in `~/.config/tsmactool/config.jsonc`. When enabled, TSMacTools installs a CGEvent tap for `Command+Tab` and `Command+\`` so it can show a native window list and focus the selected Accessibility window when Command is released. Candidate windows are matched and de-duplicated by Accessibility window identity, with filtering based on CG/AX properties such as layer, alpha, role, subrole, and size. AX lifecycle notifications remove destroyed windows from the recent list, while hidden applications and minimized windows are kept but moved behind active windows. Focusing follows Hammerspoon's `hs.window:focus()` shape: make the AX window main, bring the app frontmost through the Carbon process API, then raise the window. Set `windowSwitcher.debug` to `true` to log CG/AX window attributes, lifecycle notifications, and focus retries.

TSMacTools also checks Accessibility permission. If it is missing, the app requests the standard macOS prompt and does not open an extra permissions window. Grant access in System Settings > Privacy & Security > Accessibility, then restart the app.

Debug builds are configured to match Xcode's local run signing: Automatically manage signing enabled, Team set to None, and Signing Certificate set to `Sign to Run Locally`. Do not override the project with a different command-line signing identity; doing so changes the app identity and can force macOS TCC to ask for Accessibility permission again. If `--check-accessibility` still prints `accessibility=missing` after granting access, remove the old TSMacTools entry from System Settings and add the current app at `DerivedData/Build/Products/Debug/TSMacTools.app`. A separate `swift` script cannot verify TSMacTools' permission state because TCC checks the calling process.

## Development Rule

When code changes, update both `AGENTS.md` and `README.md` in the same commit. This includes changes to architecture, build settings, permissions, scripting commands, tests, and runtime behavior. If the change affects config fields, script entrypoints, or user-facing automation behavior, update the tracked `example_config` template in the same commit.

Architecture notes and migration rules live in `AGENTS.md`. The local Hammerspoon reference checkout is in `references/hammerspoon`.
