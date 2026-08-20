#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

clang -fobjc-arc -mmacosx-version-min=14.2 \
    -framework Foundation -framework AppKit -framework CoreAudio -framework Accelerate \
    -o "$OUT/router-handlers" router-handlers.m
"$OUT/router-handlers"

# Swift allows top-level statements in one file only, so the meter's app
# bootstrap is dropped and everything above it compiled in as is.
awk '/^let app = NSApplication.shared$/ { exit } { print }' \
    ../meter/OBSMicMeter.swift > "$OUT/OBSMicMeter.swift"
grep -q 'final class Loopback' "$OUT/OBSMicMeter.swift"

swiftc -target "$(uname -m)-apple-macos14.2" \
    -framework AppKit -framework AVFoundation -framework CoreAudio \
    -o "$OUT/meter-loopback" "$OUT/OBSMicMeter.swift" meter-loopback.swift
"$OUT/meter-loopback"
