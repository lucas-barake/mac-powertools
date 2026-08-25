#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -d build/OBSMic.driver || ! -d "build/OBS Mic Meter.app" ]]; then
    ./build.sh
fi

echo "Installing OBSMic.driver (admin required)..."
sudo rm -rf /Library/Audio/Plug-Ins/HAL/OBSMic.driver
sudo cp -R build/OBSMic.driver /Library/Audio/Plug-Ins/HAL/
# Earlier versions shipped a separate routing daemon. Its output showed up in
# OBS's own desktop audio capture, so it is gone and OBS now writes into the
# device directly. Clean it up if it is still installed.
launchctl bootout "gui/$(id -u)/dev.lucasbarake.obsmic.router" 2>/dev/null || true
rm -f ~/Library/LaunchAgents/dev.lucasbarake.obsmic.router.plist
sudo rm -f /usr/local/bin/obsmic-router

echo "Restarting coreaudiod (audio will blip for a second)..."
sudo killall coreaudiod

echo "Installing OBS Mic Meter.app..."
osascript -e 'tell application "OBS Mic Meter" to quit' 2>/dev/null || true
rm -rf "/Applications/OBS Mic Meter.app"
cp -R "build/OBS Mic Meter.app" /Applications/
open "/Applications/OBS Mic Meter.app"

echo
echo "Waiting for the 'OBS Mic' device to appear..."
registered=false
for i in $(seq 1 15); do
    if system_profiler SPAudioDataType | grep -q "OBS Mic"; then
        registered=true
        break
    fi
    sleep 1
done

if [[ "$registered" != true ]]; then
    echo "ERROR: 'OBS Mic' did not register with coreaudiod after 15s." >&2
    echo "The driver is installed but coreaudiod rejected it. Check:" >&2
    echo "  log show --last 2m --predicate 'process == \"coreaudiod\"' | grep -i obsmic" >&2
    exit 1
fi

echo "'OBS Mic' is registered."
echo
echo "Next steps:"
echo "  1. In OBS: Settings -> Audio -> Advanced -> Monitoring Device: 'OBS Mic'."
echo "  2. In OBS: Edit -> Advanced Audio Properties -> set your mic source's"
echo "     Audio Monitoring to 'Monitor and Output'."
echo "  3. Pick 'OBS Mic' as the microphone in any app."
