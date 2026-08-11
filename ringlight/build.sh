#!/bin/bash
# Builds Ringlight.app into ./dist
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=dist/Ringlight.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Ringlight "$APP/Contents/MacOS/Ringlight"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"
