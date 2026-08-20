#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

rm -rf build
mkdir -p build

# --- Virtual device driver (HAL AudioServerPlugIn) ---
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
    -framework CoreAudio \
    -framework CoreFoundation \
    -framework Accelerate \
    -o "$BUNDLE/Contents/MacOS/OBSMic" \
    driver/OBSMicDriver.c

codesign --force --sign - "$BUNDLE"

# --- Router (process tap -> virtual device) ---
clang -O2 -fobjc-arc \
    -mmacosx-version-min=14.2 \
    -sectcreate __TEXT __info_plist router/router-info.plist \
    -framework Foundation \
    -framework AppKit \
    -framework CoreAudio \
    -o build/obsmic-router \
    router/obsmic-router.m

codesign --force --sign - --identifier dev.lucasbarake.obsmic.router build/obsmic-router

# --- Menu bar level meter app ---
APP="build/OBS Mic Meter.app"
mkdir -p "$APP/Contents/MacOS"
cp meter/Info.plist "$APP/Contents/Info.plist"

swiftc -O \
    -framework AppKit \
    -framework AVFoundation \
    -framework CoreAudio \
    -o "$APP/Contents/MacOS/OBSMicMeter" \
    meter/OBSMicMeter.swift

codesign --force --sign - "$APP"

echo "Built:"
echo "  $BUNDLE"
echo "  build/obsmic-router"
echo "  $APP"
