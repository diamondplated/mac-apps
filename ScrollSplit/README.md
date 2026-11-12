# ScrollSplit

A small native menu-bar app for independent mouse-wheel direction and speed. macOS 14 or later; universal Apple Silicon and Intel. ScrollSplit starts off. Choose **Turn On** from its menu when ready.

The menu shows whether ScrollSplit is On, Off or Needs Access, with **Turn On** / **Turn Off**, **Grant Accessibility…** and **Grant Input Monitoring…** (only while missing), **Settings…** and **Quit**. **Settings…** (⌘,) opens ScrollSplit's page in Mac Tools (`mactools://app/scrollSplit`), where every setting lives; if that page cannot open, it opens Mac Tools, and failing that asks you to install it. Opening ScrollSplit again while it is off or lacks access offers to turn it on; while it is working, nothing happens. Permissions are polled only while access is missing.

Discrete mouse-wheel events can reverse vertical and horizontal direction independently, with a 0.25×–4× speed multiplier. Fractional wheel ticks accumulate so slow speeds keep small movements. Continuous scrolling, scroll phases, modifier flags, source identity, and third-axis values stay unchanged. Settings apply live.

## Permissions and hardware limits

Turning on from the menu requests the native Accessibility and Input Monitoring permissions. Review these in System Settings → Privacy & Security. macOS may require reopening ScrollSplit after approval. Startup and the Mac Tools settings bridge never open consent prompts. Stable signing helps macOS retain grants across updates.

Public Quartz wheel events identify continuous scrolling, not physical mouse-versus-trackpad hardware. Trackpads and some high-resolution mice (including many smooth-scrolling drivers) both emit continuous events. ScrollSplit leaves all of those untouched. It customizes discrete wheel mice; it does not claim per-device identification. The speed multiplier scales incoming wheel deltas, not pointer acceleration. Secure Input, third-party drivers, or competing event taps can prevent custom scrolling. Disabling or quitting removes the tap. macOS timeout-disabled taps are re-enabled while consent and the enabled preference remain valid.

## Development

Run `swift test --package-path ScrollSplit` from the repository root, then `ScrollSplit/build-app.sh`. The build script accepts `SCREENWREN_SIGNING_IDENTITY` and `SCREENWREN_SIGNING_TIMESTAMP` (`secure` or `none`); otherwise it uses the existing ScreenWren signing configuration when available, falling back to ad-hoc signing. It also works in an isolated package copy with those environment variables supplied. `ScrollSplit --self-check` performs pure checks without touching event hooks or asking for permissions.

## Settings bridge

`ScrollSplit --mac-tools-settings read` returns JSON with `schemaVersion: 1`, `app: "scrollSplit"`, `enabled`, `reverseVertical`, `reverseHorizontal`, `speedMultiplier`, `launchAtLogin`, `loginStatus`, `permissions`, and `eventTapStatus`. Writable properties are the five behavior/login properties. `write` accepts one JSON object on stdin; the entire patch is validated before any preference or login mutation. Unknown/read-only keys, nulls, mismatched Boolean/number types, and out-of-range speeds are rejected. Successful writes post `com.andrew.mactools.settingsChanged` for the existing app domain `com.andrew.scrollsplit`.

Runtime tap status comes from a live request/reply to the running app, matching its PID and canonical bundle path, not a persisted active flag. Multiple matching processes or a different running copy produce an explicit unknown status. `permissionsSource` distinguishes a running-app response from checks performed by the current CLI process. If the app does not reply, `eventTapActive` is omitted and `eventTapStatus` is `unknown`; an absent process returns `false`/`notRunning`. The CLI never installs a tap. No clipboard, keyboard, or mouse-event history is retained.
