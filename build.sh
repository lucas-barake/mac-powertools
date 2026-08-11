#!/bin/bash
# Builds Blackout.app into ./dist
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=dist/Blackout.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Blackout "$APP/Contents/MacOS/Blackout"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"
