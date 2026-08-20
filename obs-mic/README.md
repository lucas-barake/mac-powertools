# obs-mic

Exposes OBS Studio's processed audio as a virtual microphone called **OBS Mic** that any
app (Zoom, Meet, Discord, browsers) can select. A homegrown recreation of the core of
Rogue Amoeba's Loopback, scoped to this one job.

Two parts:

- **driver/** — a CoreAudio HAL `AudioServerPlugIn` that registers the "OBS Mic" virtual
  device. The plumbing is [BlackHole](https://github.com/ExistentialAudio/BlackHole)'s
  GPL-3 driver, vendored unmodified and configured at compile time with our own device
  name, UID, and bundle ID.
- **router/** — `obsmic-router`, an Objective-C daemon that recreates what Loopback's
  engine does on modern macOS: it creates a process tap on OBS
  (`AudioHardwareCreateProcessTap`, macOS 14.2+), wraps the tap and the virtual device in
  a private aggregate device with the virtual device as clock master and drift
  compensation enabled on the tap, and copies tap input to the virtual device's output in
  the IO callback. CoreAudio handles all resampling and clock skew.

Why this beats a bare BlackHole setup: no Audio MIDI Setup, no multi-output device to
silently break after macOS updates, no manual drift-correction checkbox, and OBS's
monitoring still reaches your headphones because the tap is created unmuted.

## Install

```
./build.sh
./install.sh   # needs admin; restarts coreaudiod (1s audio blip)
```

Then, once:

1. In OBS: Edit → Advanced Audio Properties → set the sources you want on the virtual
   mic to **Monitor and Output**.
2. Launch OBS. Approve the one-time "record system audio" permission prompt for
   `obsmic-router`.
3. Select **OBS Mic** as the microphone anywhere.

The router runs as a LaunchAgent (`dev.lucasbarake.obsmic.router`), starts at login,
waits for OBS, and rebuilds the route automatically when OBS restarts. Log:
`~/Library/Logs/obsmic-router.log`.

## Uninstall

```
./uninstall.sh
```

## License

GPL-3.0 (the driver derives from BlackHole).
