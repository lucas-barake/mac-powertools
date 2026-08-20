#!/bin/bash
set -euo pipefail

launchctl bootout "gui/$(id -u)/dev.lucasbarake.obsmic.router" 2>/dev/null || true
rm -f ~/Library/LaunchAgents/dev.lucasbarake.obsmic.router.plist

osascript -e 'tell application "OBS Mic Meter" to quit' 2>/dev/null || true
rm -rf "/Applications/OBS Mic Meter.app"

echo "Removing driver and router (admin required)..."
sudo rm -f /usr/local/bin/obsmic-router
sudo rm -rf /Library/Audio/Plug-Ins/HAL/OBSMic.driver
sudo killall coreaudiod

echo "Uninstalled."
