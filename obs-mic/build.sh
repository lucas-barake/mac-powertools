#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

rm -rf build
mkdir -p build

BUNDLE=build/OBSMic.driver
mkdir -p "$BUNDLE/Contents/MacOS"
cp driver/Info.plist "$BUNDLE/Contents/Info.plist"

clang -bundle -O2 \
    -mmacosx-version-min=13.0 \
    -DkDriver_Name='"OBSMic"' \
    -DkHas_Driver_Name_Format=false \
    -DkDevice_Name='"OBS Mic"' \
    -DkPlugIn_BundleID='"dev.lucasbarake.obsmic"' \
    -DkManufacturer_Name='"OBS Mic Project"' \
    -DkNumber_Of_Channels=2 \
    -DkEnableVolumeControl=false \
    -framework CoreAudio \
    -framework CoreFoundation \
    -framework Accelerate \
    -o "$BUNDLE/Contents/MacOS/OBSMic" \
    driver/OBSMicDriver.c

codesign --force --sign - "$BUNDLE"

APP="build/OBS Mic Meter.app"
mkdir -p "$APP/Contents/MacOS"
cp meter/Info.plist "$APP/Contents/Info.plist"

# Without an explicit target swiftc stamps the SDK's default deployment target,
# which LaunchServices then refuses on the macOS versions this tool supports.
swiftc -O \
    -target "$(uname -m)-apple-macos14.2" \
    -framework AppKit \
    -framework AVFoundation \
    -framework CoreAudio \
    -o "$APP/Contents/MacOS/OBSMicMeter" \
    meter/OBSMicMeter.swift

codesign --force --sign - "$APP"

echo "Built:"
echo "  $BUNDLE"
echo "  $APP"
