#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -d build/OBSMic.driver || ! -f build/obsmic-router ]]; then
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

launchctl bootout "gui/$(id -u)/dev.lucasbarake.obsmic.router" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT"

echo
echo "Done. Waiting for the 'OBS Mic' device to appear..."
for i in $(seq 1 15); do
    if system_profiler SPAudioDataType 2>/dev/null | grep -q "OBS Mic"; then
        echo "'OBS Mic' is registered."
        break
    fi
    sleep 1
done

echo
echo "Next steps:"
echo "  1. In OBS: Edit -> Advanced Audio Properties -> set your mic source's"
echo "     Audio Monitoring to 'Monitor and Output'."
echo "  2. Launch OBS. macOS will ask once to allow obsmic-router to record"
echo "     system audio — approve it."
echo "  3. Pick 'OBS Mic' as the microphone in any app."
echo "Router log: ~/Library/Logs/obsmic-router.log"
