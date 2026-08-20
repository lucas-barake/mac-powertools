# mac-powertools

Small, focused macOS menu bar utilities. Each app lives in its own directory, builds with a single script, and ships as a zip on the [releases page](https://github.com/lucas-barake/mac-powertools/releases).

| App | What it does |
| --- | --- |
| [Blackout](blackout/) | Truly disconnects the built-in MacBook display while the lid stays open, so macOS stops treating it as a screen. Camera and keyboard keep working, the mouse cannot wake it. |
| [Ringlight](ringlight/) | Draws a bright ring around your screen edges to light your face on webcam. Click-through, and it dims with transparency when your cursor gets near it. |
| [obs-mic](obs-mic/) | Exposes OBS Studio's processed audio as a virtual microphone that any app can select. Installs a CoreAudio driver, a login daemon, and a menu bar level meter from source with `obs-mic/install.sh`. Not shipped as a zip. |

## Install

Download the app's zip from [releases](https://github.com/lucas-barake/mac-powertools/releases), unzip, move the `.app` to `/Applications`, and clear the quarantine flag once (the apps are ad-hoc signed, not notarized):

```sh
xattr -dr com.apple.quarantine /Applications/<App>.app
```

## Build from source

```sh
./blackout/build.sh    # -> blackout/dist/Blackout.app
./ringlight/build.sh   # -> ringlight/dist/Ringlight.app
```

## Releases

Pushing a tag named `<app>-v<version>` (for example `blackout-v1.0.0`) builds that app on CI and publishes the zip as a GitHub release.
