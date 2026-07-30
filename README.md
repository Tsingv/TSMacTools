# TSMacTools

<p>
  <a href="https://github.com/Tsingv/TSMacTools/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/Tsingv/TSMacTools?display_name=tag&sort=semver"></a>
  <img alt="Platform" src="https://img.shields.io/badge/macOS-13%2B-black?logo=apple">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-first-F05138?logo=swift&logoColor=white">
</p>

Make macOS fit the way you work.

TSMacTools is a native menu bar automation app inspired by Hammerspoon. It combines window-first switching, keyboard and mouse shortcuts, smooth scrolling, selected-text translation, and Python-powered workflows in one compact app.

## What you can do

- **Switch to the window you want.** Cycle through individual windows across applications instead of stopping at the app level, with familiar `Command+Tab` and `Command+\`` controls.
- **Turn almost any shortcut into an action.** Bind keyboard combinations, mouse side buttons, or modifier-plus-mouse chords to focus or toggle apps, simulate keystrokes, reload configuration, translate text, or run a Python function.
- **Make a mouse wheel feel better.** Pick a smooth-scrolling preset, tune each axis, reverse direction independently, and leave trackpad or Magic Mouse gestures untouched.
- **Translate selected text in place.** Use Google Web, Google Cloud Translation, or an LLM and read the result in a selectable, pinnable native Markdown window.
- **Build small native tools with Python.** Scripts can receive selected text and configuration, then present plain text or Markdown through native TSMacTools windows.
- **Keep configuration under your control.** Common options live in Settings, while the underlying JSONC file remains editable and keeps its comments and custom fields.
- **Control menu bar visibility on macOS 26+.** Show or hide supported application menu bar icons directly from the TSMacTools status menu.

## Settings at a glance

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/readme/settings-hotkeys-dark.png">
    <source media="(prefers-color-scheme: light)" srcset="docs/images/readme/settings-hotkeys-light.png">
    <img alt="TSMacTools Hotkeys settings" src="docs/images/readme/settings-hotkeys-light.png" width="900">
  </picture>
</p>

<p align="center"><sub>Combine a trigger, an action, and an optional target without hand-editing configuration.</sub></p>

<table>
  <tr>
    <td width="50%"><img alt="TSMacTools General settings" src="docs/images/readme/settings-general.png"></td>
    <td width="50%"><img alt="TSMacTools Scrolling settings" src="docs/images/readme/settings-scrolling.png"></td>
  </tr>
  <tr>
    <td align="center"><b>General</b><br><sub>Window switching, translation, scripting, and application preferences.</sub></td>
    <td align="center"><b>Scrolling</b><br><sub>Presets, per-axis behavior, gesture bypass, and custom tuning.</sub></td>
  </tr>
</table>

## Get started

1. Download the latest build from [GitHub Releases](https://github.com/Tsingv/TSMacTools/releases/latest), or [build it from source](#build-from-source).
2. Launch TSMacTools. It stays in the menu bar and does not occupy Dock space.
3. Grant the standard macOS Accessibility permission when prompted. This enables global shortcuts, window control, mouse-button actions, and related automation.
4. Open **Settings...** from the status menu:
   - **General** configures window switching, scripting, translation, and application behavior.
   - **Hotkeys** records triggers and assigns their actions.
   - **Scrolling** enables smoothing and chooses a preset or custom curve.

On first launch, TSMacTools creates its configuration at `~/.config/tsmactool/config.jsonc` and a companion `scripts` directory. Most changes made in Settings apply immediately; the status menu also provides **Reload Configuration** and **Open Configuration** actions.

> [!NOTE]
> TSMacTools is under active development. Current release artifacts are development-signed and are not yet notarized for broad distribution.

## Build from source

TSMacTools requires macOS 13 or later and a current Xcode installation.

```sh
open MacTools.xcodeproj
```

Select the **MacTools** scheme, then build and run it from Xcode. The resulting application is named **TSMacTools**.

## Configuration and scripts

The Settings window covers everyday configuration. Advanced options remain available in the comment-friendly JSONC file at `~/.config/tsmactool/config.jsonc`.

- [`example_config/config.jsonc`](example_config/config.jsonc) documents the supported configuration shape without real secrets.
- [`example_config/scripts`](example_config/scripts) contains Python automation examples, including selected-text translation.

Keep provider keys in your local configuration. The tracked examples intentionally contain no real credentials.

## Development

Architecture, implementation constraints, build and test workflows, permission-sensitive diagnostics, and parity notes live in [`AGENTS.md`](AGENTS.md).
