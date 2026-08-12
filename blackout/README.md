# Blackout

A macOS menu bar app that truly disconnects the built-in MacBook display while the lid stays open.

When you work on an external display with the lid open (for the camera, the keyboard, or Touch ID), macOS still treats the built-in panel as a screen. Windows land on it, window managers tile onto it, and moving the mouse wakes it. Blackout removes the panel from the display topology entirely, as if it were not there. The camera, keyboard, trackpad, and Touch ID keep working.

This is a real disconnect, not brightness 0, not gamma tricks, not mirroring. While disabled, the built-in display disappears from the online display list and from System Settings.

## Install

Grab `Blackout.zip` from [releases](https://github.com/lucas-barake/mac-powertools/releases), unzip it, and move `Blackout.app` to `/Applications`.

The app is ad-hoc signed, not notarized, so macOS quarantines the download. Clear the flag once:

```sh
xattr -dr com.apple.quarantine /Applications/Blackout.app
open /Applications/Blackout.app
```

Alternatively, allow it under System Settings → Privacy & Security → Open Anyway after the first blocked launch.

## Usage

Click the display icon in the menu bar:

- **Disable Built-in Display** disconnects the panel.
- **Enable Built-in Display** brings it back.
- **Launch at Login** registers the app with `SMAppService`.

Safety rails:

- Refuses to disable the built-in display when it is the only active display.
- Automatically re-enables the built-in display if every external display disappears while it is off, so the machine is never headless. This is enforced by a watchdog that polls every 2 seconds while the panel is off and retries failed re-enable attempts, not just by a one-shot display-change callback. The check ignores the placeholder virtual display (vendor `unkn`, model `virt`) that the WindowServer brings up when no physical display is active, which would otherwise mask the headless state.
- Remembers the disabled panel across crashes and relaunches: if the app dies while the panel is off, the next launch recovers the state and re-enables the display if no other screen is active.
- Re-enables the display on quit.

## Build

```sh
./build.sh
open dist/Blackout.app
```

Requires macOS 13+ on Apple Silicon. No root, no entitlements, no TCC prompts.

## How it works

Blackout uses the private CoreGraphics symbol `CGSConfigureDisplayEnabled`, resolved at runtime with `dlsym`, inside a standard `CGBeginDisplayConfiguration` / `CGCompleteDisplayConfiguration(.permanently)` transaction. This is the same mechanism behind Lunar's BlackOut disconnect mode and BetterDisplay's "disconnect display".

Because the symbol is private, an OS update could remove or break it. The app resolves it at launch and tells you if it is gone instead of failing silently.

If a re-enable ever fails (reports exist on some Apple Silicon and macOS combinations), closing and reopening the lid or rebooting restores the panel. macOS always re-enables the built-in display on boot.
