# obs-mic

Exposes OBS Studio's processed audio as a virtual microphone called **OBS Mic** that any
app (Zoom, Meet, Discord, browsers) can select.

Two parts:

- **driver/**. A CoreAudio HAL `AudioServerPlugIn` that registers the "OBS Mic" virtual
  device. The plumbing is [BlackHole](https://github.com/ExistentialAudio/BlackHole)'s
  GPL-3 driver, vendored unmodified at commit
  [`ffcb744`](https://github.com/ExistentialAudio/BlackHole/commit/ffcb744) and configured
  at compile time with our own device name, UID, and bundle ID, and with its volume
  control disabled.
- **meter/**. "OBS Mic Meter", a menu bar app installed to `/Applications`. Its icon is a
  live level bar for the virtual device. The popover has a "Hear OBS Mic on my speakers"
  toggle that plays exactly what other apps receive from the virtual mic on your current
  default output, and health checks for each link in the chain (driver, OBS monitoring
  device, OBS running, mic permission). `install.sh` copies it in and launches it.

OBS writes its monitor output straight into the device. That is deliberate. OBS's own
desktop audio capture (the macOS Screen Capture source) records the output of every
process except OBS itself, so any separate process writing the mic into the device would
put a second copy of your voice into every recording. An earlier version of this tool
routed through a process tap and did exactly that.

Why this beats a bare BlackHole setup: no Audio MIDI Setup, no multi-output device to
silently break after macOS updates, no manual drift-correction checkbox, and no hidden
attenuation. BlackHole maps the macOS input level slider onto a 64 dB range, so a slider
at 69% silently costs 20 dB, and apps with automatic level control keep dragging it down.
This driver is built without that control: the slider macOS still shows for "OBS Mic" does
nothing, and what comes out is exactly what OBS put in. Set your level in OBS.

Requires macOS 14.2 or newer.

## Install

```
./build.sh
./install.sh   # needs admin, restarts coreaudiod (1s audio blip)
```

Then, once, in OBS:

1. Settings → Audio → Advanced → Monitoring Device: **OBS Mic**.
2. Edit → Advanced Audio Properties → set the sources you want on the virtual mic to
   **Monitor and Output**.
3. Select **OBS Mic** as the microphone anywhere.

You will not hear your own mic: the monitor goes into the virtual device, not your
speakers. Use the meter's "Hear OBS Mic on my speakers" toggle to check it. While that
toggle is on, the meter is an extra process playing your mic, and OBS's desktop audio
capture will pick it up, so turn it off before recording.

Approve the microphone prompt for "OBS Mic Meter" if you want the menu bar level to move.
Denying it only blanks the meter, the virtual mic still works.

## Latency

OBS writes into the device and consumers read from it; there is no tap or aggregate in
between. (The earlier tap route measured 65 ms on its own.) What you perceive is mostly
OBS:

- OBS grows its internal audio buffer whenever a source delivers late (a sleep/wake, a USB
  hiccup), never shrinks it, and caps at 1000 ms. The log line is `adding N milliseconds of
  audio buffering`. Restarting OBS resets it. Setting `LowLatencyAudioBuffering=true` under
  `[Audio]` in `user.ini` (Settings → Audio → Advanced → Low latency audio buffering mode)
  stops the growth; OBS then logs `Enabling fixed audio buffering`.
- Filters such as noise suppression add their own processing delay.

## Tests

```
./tests/run.sh
```

Compiles the meter source into harnesses: one checks the loopback against the real
CoreAudio device, one clicks the popover's Hear checkbox and checks that the loopback
starts and stops with it.

## Uninstall

```
./uninstall.sh
```

## License

GPL-3.0. The driver derives from BlackHole, so the whole directory is distributed under
the GPL-3 text in `LICENSE`.
