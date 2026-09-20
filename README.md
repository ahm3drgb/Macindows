# Macindows

Windows-style desktop behaviors for macOS, living in the menu bar.

- **Dock**: click the front app's icon to minimize it; hover an icon for live window thumbnails with minimize / restore / close; ⌘Tab restores minimized windows; double-click a title bar to fill the screen; menu bar icon shows the desktop.
- **Finder**: Control + scroll resizes icons live; Enter opens, F2 renames, Backspace goes back.
- **Mouse**: raw 1:1 scroll wheel (no acceleration) with adjustable lines per notch; pointer speed beyond the system maximum.
- **Keyboard**: ⌘ + ⇧ switches input language.

Everything is a toggle in Settings (right-click the menu bar icon).

## Build

```sh
./build.sh          # builds Macindows.app, signed with "Apple Development"
./make_dmg.sh       # builds the app and packages Macindows-<version>.dmg
```

Release builds need a Developer ID certificate and notarization:

```sh
SIGN_ID="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=macindows ./make_dmg.sh
```

## Permissions

Macindows asks for Accessibility, Input Monitoring and Screen Recording on first launch, and Automation (Finder) the first time you resize icons.

Requires macOS 14 or later.
