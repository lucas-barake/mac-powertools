#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -d build/OBSMic.driver || ! -f build/obsmic-router || ! -d "build/OBS Mic Meter.app" ]]; then
    ./build.sh
fi

echo "Installing OBSMic.driver (admin required)..."
sudo rm -rf /Library/Audio/Plug-Ins/HAL/OBSMic.driver
sudo cp -R build/OBSMic.driver /Library/Audio/Plug-Ins/HAL/
sudo install -m 755 build/obsmic-router /usr/local/bin/obsmic-router

echo "Restarting coreaudiod (audio will blip for a second)..."
sudo killall coreaudiod

AGENT=~/Library/LaunchAgents/dev.lucasbarake.obsmic.router.plist
mkdir -p ~/Library/LaunchAgents ~/Library/Logs
cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>dev.lucasbarake.obsmic.router</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/local/bin/obsmic-router</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardErrorPath</key>
	<string>$HOME/Library/Logs/obsmic-router.log</string>
</dict>
</plist>
EOF

LABEL=dev.lucasbarake.obsmic.router
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
# bootout returns before launchd has finished unloading the service, and a
# bootstrap issued in that window fails with "Input/output error".
for i in $(seq 1 20); do
    launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || break
    sleep 0.5
done
launchctl bootstrap "gui/$(id -u)" "$AGENT"

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
echo "  1. In OBS: Edit -> Advanced Audio Properties -> set your mic source's"
echo "     Audio Monitoring to 'Monitor and Output'."
echo "  2. Launch OBS. macOS will ask once to allow obsmic-router to record"
echo "     system audio. Approve it."
echo "  3. Pick 'OBS Mic' as the microphone in any app."
echo "Router log: ~/Library/Logs/obsmic-router.log"
