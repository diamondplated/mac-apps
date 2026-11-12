# StayLit

A small native menu-bar app that keeps the Mac awake on your terms and makes the keyboard's brightness and volume keys work for external displays. macOS 14 or later; universal Apple Silicon and Intel (display control needs Apple Silicon). Everything starts off.

The menu's first line says what is happening: "Awake for 42 more minutes", "Awake while Xcode is running", "Awake until you turn it off", "Not Keeping Awake", or "Keep Awake Ended at Low Battery". Below it are **Keep Awake** (a switch), **Keep Awake For** (30 Minutes, 1 Hour, 2 Hours, Until I Turn It Off), **Keep Awake While <app> Is Running** for the app you were just using, **Grant Accessibility…** (only while a display-key switch is on without it), **Settings…** and **Quit**. **Settings…** (⌘,) opens StayLit's page in Mac Tools (`mactools://app/stayLit`), where every setting lives; if that page cannot open, it opens Mac Tools, and failing that asks you to install it. The menu bar cup is filled while the Mac is being kept awake.

## Keep awake

- **Now.** Keep Awake holds the Mac awake until you turn it off; Keep Awake For ends by itself. Choosing one replaces the other. A timer does not survive quitting StayLit; the Keep Awake switch does.
- **While an app runs.** The Mac stays awake whenever any app on the list is running and goes back to normal when the last one quits. The menu adds or removes the current app; Mac Tools edits the whole list (up to 50 apps).
- **What awake means.** StayLit holds one IOKit idle-sleep assertion, only while a reason is active, and releases it the moment none is. By default only the system stays awake and the display may sleep; a second switch in Mac Tools keeps the display on too. Closing the lid or choosing Sleep still sleeps the Mac.
- **Never stuck.** On battery below 20 percent, Keep Awake and Keep Awake For turn themselves off and the menu says so; the app list is left alone. Quitting StayLit releases everything, and macOS drops the assertion if StayLit stops for any other reason.

## Brightness and volume keys for external displays

Both switches are off by default. While either is on, StayLit asks for Accessibility and installs one event tap for the media keys; with both off, or without Accessibility, there is no tap.

- **Brightness keys** change the brightness of the external display under the pointer when it answers DDC/CI, with a small indicator on that display. On the built-in display, an Apple display, or a display that does not answer, the keys go to macOS untouched.
- **Volume keys** change a display's own volume over DDC/CI when sound goes to that display over HDMI or DisplayPort and macOS has no volume control for it. Mute sets the display's volume to zero and the next volume or mute key restores it. Otherwise the keys go to macOS untouched.

StayLit reads each display's current value and maximum once when it connects (only while a switch is on), moves sixteen steps across the range like the built-in display, and writes to a display at most once every 60 ms, keeping only the newest value. It uses the private `IOAVService` interface on Apple Silicon, looked up at run time; a missing interface or a silent display means "not supported", never an error. Intel Macs report every display as not supported in this version. The tap passes every other event through, and a tap that macOS disables is re-enabled while it is wanted.

## Development

Run `swift test --package-path StayLit` from the repository root, then `StayLit/build-app.sh`. The build script accepts `SCREENWREN_SIGNING_IDENTITY` and `SCREENWREN_SIGNING_TIMESTAMP` (`secure` or `none`); otherwise it uses the existing ScreenWren signing configuration when available, falling back to ad-hoc signing. `StayLit --self-check` performs pure checks without holding a power assertion, installing a tap, talking to a display, or asking for permissions. `STAYLIT_INDICATOR_SNAPSHOT=/dir/name.png swift test --package-path StayLit --filter IndicatorRenderTests` renders the on-screen indicator to PNG in light and dark. `Resources/generate-icon.swift <dir>` draws the icon set for `iconutil`.

## Settings bridge

`StayLit --mac-tools-settings read` returns JSON with `schemaVersion: 1`, `app: "stayLit"`, `keepAwake`, `keepAwakeApps`, `keepsDisplayAwake`, `brightnessKeysControlDisplays`, `volumeKeysControlDisplays`, `awakeReason`, `externalDisplays`, `launchAtLogin`, `loginStatus`, `permissions` and `permissionsSource`. Writable properties are the five behaviour settings and `launchAtLogin`. `keepAwakeApps` is an array of at most 50 bundle identifiers (letters, digits, `.`, `-`, `_`); duplicates collapse. `write` accepts one JSON object on stdin; the entire patch is validated before any preference or login mutation. Unknown/read-only keys, nulls, non-Boolean switches, and invalid lists are rejected. Successful writes post `com.andrew.mactools.settingsChanged` for the app domain `com.andrew.staylit`, and the running app applies them at once.

`awakeReason` is the sentence the menu shows, or null. `externalDisplays` lists connected external displays as `{ "name", "controllable" }`. Both come from a live request/reply to the running app, matched by PID and canonical bundle path (`permissionsSource: "runningApp"`). When StayLit is not running, `awakeReason` is null, `permissions` are this process's own checks (`permissionsSource: "currentProcess"`), and `controllable` means a DDC/CI channel was found for the display; the running app confirms it by reading the display once a display-key switch is on. The CLI never holds an assertion, installs a tap, or talks to a display.
