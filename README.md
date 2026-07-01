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

On first launch, TSMacTools creates `~/.config/tsmactool/config.jsonc` and `~/.config/tsmactool/scripts`, then stays in the macOS menu bar without occupying Dock space. The status menu can reload configuration, open the configuration folder, and quit the app; Accessibility prompting happens automatically at startup when needed. `config.jsonc` is one normal JSON object with `//` and `/* */` comments allowed. The default config omits derived development-only fields such as `version`, hotkey `id`, `application.name`, and `application.configDirectoryName`.

The repository keeps a tracked example at `example_config/config.jsonc` plus `example_config/scripts`. Local development uses untracked `my_config`, and `~/.config/tsmactool` can be a symlink to that folder. Keep real API keys and personal edits in `my_config`; keep `example_config` complete, commented, and safe to commit.

Set `scripting.pythonPath` to the Python executable TSMacTools should use. Hotkey actions can call built-in Swift interfaces or run user Python scripts. Use `{"kind":"callInterface","interfaceName":"reloadConfiguration"}` for app-provided behavior, or `{"kind":"runScript","path":"scripts/translate_selection.py","function":"main","input":"selectedText","nativeWindowID":"translate"}` to send selected text to a script function. The app loads config once, injects `config`, `input_text`, `nativewindow`, and `window` globals into the script module, then calls the configured function. Scripts do not read `~/.config/tsmactool/config.jsonc` themselves.

The default config is a typed migration of the current Hammerspoon setup: app focus hotkeys, Finder/terminal toggles, command-tab style window switching preferences, and the LLM translation settings. The Finder toggle keeps the recent-window behavior when another app is frontmost; when Finder is already frontmost, it raises an existing Home folder window, or creates a new Home window if the current Finder window is already Home. Translation defaults to `qwen/qwen3.6-27b`. Set `translation.thinkingEnabled` to control model reasoning output and `translation.thinkingParameter` to choose how that preference is sent. The default `"include_reasoning"` works with the Groq-backed CLIProxyAPI path by sending `include_reasoning: false`, which hides reasoning from the returned content but may still consume reasoning tokens upstream. Use `"reasoning_format"` for Groq endpoints that prefer `reasoning_format: hidden`, `"enable_thinking"` for Qwen-compatible endpoints that accept that parameter, or `"none"` for strict endpoints that reject all extra fields. The native translation window renders Markdown, keeps text selectable for copying, and folds returned `<think>...</think>` blocks behind a Show Thinking button. Short status messages such as reload success are shown in separate transient alert panels instead of reusing the script content window. The translation path now targets a floating `window.show` native window instead of Hammerspoon `hs.webview`; that window appears immediately with a spinning `Translating...` state while the script is running, follows light/dark mode, closes when it loses focus by default, and can be pinned from its title bar so later translations update the same long-lived window.

The window switcher is controlled by the `windowSwitcher` section in `~/.config/tsmactool/config.jsonc`. When enabled, TSMacTools installs a CGEvent tap for `Command+Tab` and `Command+\`` so it can cycle the selected Accessibility window in the background, delay the native window list briefly while Command is held, and focus the selected window when Command is released. The tap suppresses the handled tab/backtick key events, but lets modifier `flagsChanged` events continue through the system. Candidate windows are matched and de-duplicated by Accessibility window identity, with filtering based on CG/AX properties such as layer, alpha, role, subrole, and size. AX calls use a short messaging timeout so a slow or hung target app cannot stall the switcher indefinitely. AX lifecycle notifications remove destroyed windows from the recent list, restore the previous application when the frontmost app loses its last switchable window, and keep hidden applications and minimized windows behind active windows. Focusing is AX-only: it clears the target window's minimized AX attribute, sets the system `kAXFocusedApplicationAttribute` and application `kAXFrontmostAttribute` for cross-app switches, performs `kAXRaiseAction` on the target window, sets the window's `kAXMainAttribute` and `kAXFocusedAttribute`, sets the owning application's `kAXFocusedWindowAttribute` to that same window, and verifies the result through an app-level AXObserver listening for `kAXFocusedWindowChangedNotification`. Finder still gets Hammerspoon's delayed AX main-window retry. The focus path avoids AppKit app-wide activation, Carbon front-process calls, synthetic mouse events, and pointer movement. Set `windowSwitcher.debug` to `true` to log CG/AX window attributes, lifecycle notifications, AX focus verification, focus retries, and timing lines such as `[window-switcher] buildChoices elapsed=...` and `[hotkey] runScript terminated elapsed=...`.

TSMacTools also checks Accessibility permission. If it is missing, the app requests the standard macOS prompt and does not open an extra permissions window. Grant access in System Settings > Privacy & Security > Accessibility, then restart the app.

Debug builds are configured to match Xcode's local run signing: Automatically manage signing enabled, Team set to None, and Signing Certificate set to `Sign to Run Locally`. Do not override the project with a different command-line signing identity; doing so changes the app identity and can force macOS TCC to ask for Accessibility permission again. If `--check-accessibility` still prints `accessibility=missing` after granting access, remove the old TSMacTools entry from System Settings and add the current app at `DerivedData/Build/Products/Debug/TSMacTools.app`. A separate `swift` script cannot verify TSMacTools' permission state because TCC checks the calling process.

## Development Rule

When code changes, update both `AGENTS.md` and `README.md` in the same commit. This includes changes to architecture, build settings, permissions, scripting commands, tests, and runtime behavior. If the change affects config fields, script entrypoints, or user-facing automation behavior, update the tracked `example_config` template in the same commit.

Architecture notes and migration rules live in `AGENTS.md`. The local Hammerspoon reference checkout is in `references/hammerspoon`.
