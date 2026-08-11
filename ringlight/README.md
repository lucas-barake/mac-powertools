# Ringlight

A macOS menu bar app that turns your screen edges into a ring light for your webcam.

It draws a bright, warm-tinted band around the border of your screen, above everything including fullscreen apps. The band is click-through, and when your cursor gets near the edge it dims and turns translucent so it never hides what you are aiming for. Move away and it comes back to full brightness.

## Install

Grab `Ringlight.zip` from [releases](https://github.com/lucas-barake/mac-powertools/releases), unzip, move `Ringlight.app` to `/Applications`, then clear the quarantine flag once (the app is not notarized):

```sh
xattr -dr com.apple.quarantine /Applications/Ringlight.app
open /Applications/Ringlight.app
```

## Usage

Click the ring icon in the menu bar:

- **Turn Ringlight On/Off** toggles the ring.
- **Screen** picks which screen gets the ring (or all of them).
- **Thickness** — Thin / Medium / Thick.
- **Warmth** — Cool / Soft / Warm color temperature.
- **Intensity** — Low / Medium / Full brightness.
- **Launch at Login** registers the app with `SMAppService`.

Settings persist across launches.

## Build

```sh
./build.sh
open dist/Ringlight.app
```

Requires macOS 13+.
