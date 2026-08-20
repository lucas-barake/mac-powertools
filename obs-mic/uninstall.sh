#!/bin/bash
set -euo pipefail

launchctl bootout "gui/$(id -u)/dev.lucasbarake.obsmic.router" 2>/dev/null || true
rm -f ~/Library/LaunchAgents/dev.lucasbarake.obsmic.router.plist

echo "Removing driver and router (admin required)..."
sudo rm -f /usr/local/bin/obsmic-router
sudo rm -rf /Library/Audio/Plug-Ins/HAL/OBSMic.driver
sudo killall coreaudiod

echo "Uninstalled."
