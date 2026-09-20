# Macindows

Windows-style desktop behaviors for macOS, living in the menu bar.

## Download

Grab **Macindows-1.0.dmg** from the [latest release](https://github.com/linkingforservices/macindows/releases/latest), open it and drag **Macindows** to **Applications**.

First launch shows a permissions guide. Macindows needs:

| Permission | Used for |
|---|---|
| Accessibility | Dock clicks, minimize / restore, window thumbnails |
| Input Monitoring | Raw scroll, mouse speed, Finder keys, ⌘⇧ language switch |
| Screen Recording | Window thumbnails in the Dock preview |
| Automation (Finder) | Control + scroll icon resizing — asked the first time you use it |

Relaunch after granting Screen Recording. Requires macOS 14 or later.

## Features

Every feature is a toggle in **Settings** (right-click the menu bar icon).

### Dock
- Click the front app's Dock icon to minimize its windows; click again to restore.
- Hover a Dock icon for live window thumbnails: click to restore / minimize, **×** to close, right-click or **⋯** for Minimize All and Quit.
- ⌘Tab to an app with only minimized windows brings one back.
- Double-click a title bar to fill the screen and back.
- Click the menu bar icon to show the desktop; click again to bring everything back.

### Finder
- **Control + scroll** resizes icons live (needs View › Show Status Bar for smooth redraw).
- **Enter** opens, **F2** renames (fn + F2 on Mac keyboards), **Backspace** goes back.

### Mouse
- Raw 1:1 scroll wheel, no acceleration, adjustable lines per notch. Trackpad untouched.
- Pointer speed multiplier beyond the system maximum.

### Keyboard
- **⌘ + ⇧** switches input language, like Alt + Shift on Windows.

## Build from source

```sh
./build.sh          # builds Macindows.app, signed with "Apple Development"
./make_dmg.sh       # builds the app and packages Macindows-<version>.dmg
```

Release builds for other Macs need a Developer ID certificate and notarization:

```sh
SIGN_ID="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=macindows ./make_dmg.sh
```

## Notes

- The 1.0 DMG is signed with an Apple Development certificate. On another Mac, right-click the app and choose **Open** the first time.
- Logs: `~/Library/Logs/Macindows.log` (tap failures only).
