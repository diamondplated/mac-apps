# MixBar

A small native menu-bar app that gives each app its own volume. macOS 14 or later; universal Apple Silicon and Intel. Per-app control needs macOS 14.2 or later; on 14.0 and 14.1 the mixer says so and touches nothing. A fresh install changes nothing about how the Mac sounds.

Click the menu bar sliders to open the mixer. It lists the apps playing sound now, plus running apps that have a saved setting, each with its icon, a volume slider from 0 to 200 percent with a detent at 100, a mute button and an output menu (**System Default** or a specific output device). Below them are the system output and its volume, **Settings…** (⌘,) and **Quit MixBar** (⌘Q). **Settings…** opens MixBar's page in Mac Tools (`mactools://app/mixBar`); if that page cannot open, it opens Mac Tools, and failing that asks you to install it. Opening MixBar again (from Mac Tools or the Finder) shows the mixer.

## What it does to sound

- **Doing nothing is the default.** An app at 100 percent, unmuted, on System Default is not touched at all. Returning an app to that state removes everything MixBar did to it.
- **Otherwise** MixBar makes a private Core Audio process tap of that app (all of its audio processes, so a browser's helpers move together), silences the app's own output while MixBar replays the tap at the chosen gain to the chosen output, and stops when the setting returns to default or the app has been silent for 10 seconds. Gain changes ramp over 20 ms so a drag does not click, and a soft limiter keeps 200 percent from passing full scale.
- **Remembered.** With **Remember App Volumes** on (the default), an app's volume, mute and output are saved by bundle identifier and reapplied when it next plays. With it off, a choice lasts until the app quits.
- **Privacy.** MixBar listens to an app's sound only to play it back at the volume you chose; nothing is recorded or stored. macOS asks once to allow MixBar under System Audio Recording. There is no public way to ask whether that was allowed, so MixBar learns it: the first sound through a tap means allowed; a first tap that hears only silence for four seconds while its app plays means refused, and MixBar removes every tap and shows **Allow…** in the mixer.

## If MixBar quits or something breaks

The tap silences an app only while MixBar is reading it (`CATapMutedWhenTapped`), and the tap and its aggregate device are private to MixBar. If MixBar quits or crashes, every app plays normally at its own volume. Quitting removes every tap first.

Anything that breaks a live tap (the output device unplugged, a sample-rate or format change, sleep and wake, coreaudiod restarting, the app's audio processes changing, or IO that stops moving for two seconds) ends with a rebuilt tap or no tap, never an app muted with nothing replaying it. A tap is rebuilt once; if it fails again it is removed and tried again only when its setting or output changes or the mixer opens. An output that is not connected falls back to the system output. Sleep removes every tap; wake rebuilds them.

## Development

Run `swift test --package-path MixBar` from the repository root, then `MixBar/build-app.sh`. The build script accepts `SCREENWREN_SIGNING_IDENTITY` and `SCREENWREN_SIGNING_TIMESTAMP` (`secure` or `none`); otherwise it uses the existing ScreenWren signing configuration when available, falling back to ad-hoc signing. It signs with hardened runtime and `MixBar.entitlements` (`com.apple.security.device.audio-input`, for reading a tap's input stream). `MixBar --self-check` runs pure checks and Core Audio symbol lookups only: no tap, aggregate device, audio IO, volume change or permission prompt. `MIXBAR_MIXER_SNAPSHOT=/dir/name.png swift test --package-path MixBar --filter MixerRenderTests` renders the mixer to PNG in light and dark. `Resources/generate-icon.swift <dir>` draws the icon set for `iconutil`.

Everything that touches Core Audio is behind `AudioService`; the engine, grouping, planner and render maths are tested against a fake. The IO callback is C (`MixBarDSP`): no allocation, locks, reference counting, Objective-C messaging or logging, and no buffer outlives it.

## Settings bridge

`MixBar --mac-tools-settings read` returns JSON with `schemaVersion: 1`, `app: "mixBar"`, `remembersVolumes`, `appVolumes`, `audioControlAvailable`, `audioCaptureStatus`, `launchAtLogin` and `loginStatus`. Writable properties are `remembersVolumes`, `appVolumes` and `launchAtLogin`. `appVolumes` is an array of at most 100 `{ "bundleIdentifier", "name", "volume" (0–2), "muted", "outputDeviceUID" (string or null) }`; `name` is ignored on write (MixBar keeps the name it knows, or the installed app's name), duplicate bundle identifiers are rejected, and writing a shorter array forgets the missing apps. `write` accepts one JSON object on stdin; the entire patch is validated before any preference or login mutation. Unknown or read-only keys, nulls, wrong types, volumes outside 0–2, unknown entry keys and empty device UIDs are rejected. Successful writes post `com.andrew.mactools.settingsChanged` for the app domain `com.andrew.mixbar`, and the running app applies them at once.

`audioControlAvailable` is false below macOS 14.2. `audioCaptureStatus` (`unknown`, `granted`, `denied`) comes from a live request/reply to the running app, matched by PID and canonical bundle path; it is `unknown` when MixBar is not running. The CLI never touches Core Audio.
