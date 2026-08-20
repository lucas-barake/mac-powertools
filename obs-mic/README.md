# obs-mic

Exposes OBS Studio's processed audio as a virtual microphone called **OBS Mic** that any
app (Zoom, Meet, Discord, browsers) can select. A homegrown recreation of the core of
Rogue Amoeba's Loopback, scoped to this one job.

Three parts:

- **driver/**. A CoreAudio HAL `AudioServerPlugIn` that registers the "OBS Mic" virtual
  device. The plumbing is [BlackHole](https://github.com/ExistentialAudio/BlackHole)'s
  GPL-3 driver, vendored unmodified at commit
  [`ffcb744`](https://github.com/ExistentialAudio/BlackHole/commit/ffcb744) and configured
  at compile time with our own device name, UID, and bundle ID.
- **router/**. `obsmic-router`, an Objective-C daemon that recreates what Loopback's
  engine does on modern macOS: it creates a process tap on OBS
  (`AudioHardwareCreateProcessTap`, macOS 14.2+), wraps the tap and the virtual device in
  a private aggregate device with the virtual device as clock master and drift
  compensation enabled on the tap, and copies tap input to the virtual device's output in
  the IO callback. CoreAudio handles all resampling and clock skew.
- **meter/**. "OBS Mic Meter", a menu bar app installed to `/Applications`. Its icon is a
  live level bar for the virtual device, and its popover health-checks each link in the
  chain (driver, router, OBS, mic permission) so a silent tunnel is diagnosable at a
  glance. `install.sh` copies it in and launches it.

Why this beats a bare BlackHole setup: no Audio MIDI Setup, no multi-output device to
silently break after macOS updates, no manual drift-correction checkbox, and no second
virtual device to park OBS's monitor on. The tap is created muted, so OBS can monitor to
your normal output device and you never hear your own mic. If you do hear it, the router is
not attached, which is the only time OBS's monitor reaches the speakers.

Requires macOS 14.2 or newer.

The virtual device applies no volume of its own. BlackHole maps the macOS input level
slider onto a 64 dB range, so a slider at 69% silently costs 20 dB, and apps with automatic
level control keep dragging it down. The driver is therefore built with its volume control
disabled: the slider macOS still shows for "OBS Mic" does nothing. The one gain stage in
the tunnel is the **Output gain** slider in the meter popover (0 to 400%), which the router
applies in its IO callback. It is stored in the `dev.lucasbarake.obsmic` preference domain
and picked up by the router immediately.

## Install

```
./build.sh
./install.sh   # needs admin, restarts coreaudiod (1s audio blip)
```

Then, once:

1. In OBS: Edit → Advanced Audio Properties → set the sources you want on the virtual
   mic to **Monitor and Output**. Leave Settings → Audio → Monitoring Device on Default.
2. Launch OBS. Approve the one-time "record system audio" permission prompt for
   `obsmic-router`.
3. Approve the microphone prompt for "OBS Mic Meter" if you want the menu bar level to
   move. Denying it only blanks the meter, the virtual mic still works.
4. Select **OBS Mic** as the microphone anywhere.

The router runs as a LaunchAgent (`dev.lucasbarake.obsmic.router`), starts at login,
waits for OBS, and rebuilds the route automatically when OBS restarts or coreaudiod is
reset. Log: `~/Library/Logs/obsmic-router.log`.

## Testing the tunnel without OBS

`obsmic-router` takes an optional bundle identifier and routes that app instead of OBS.
Stop the agent, play anything in QuickTime, and run the router against it. The menu bar
meter should light up.

```
launchctl bootout gui/$(id -u)/dev.lucasbarake.obsmic.router
./build/obsmic-router com.apple.QuickTimePlayerX
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.lucasbarake.obsmic.router.plist
```

## Tests

```
./tests/run.sh
```

Compiles the router source into a harness and checks the notification handlers and the
coreaudiod restart recovery against the real `gState`.

## Uninstall

```
./uninstall.sh
```

## License

GPL-3.0. The driver derives from BlackHole, so the whole directory is distributed under
the GPL-3 text in `LICENSE`.
