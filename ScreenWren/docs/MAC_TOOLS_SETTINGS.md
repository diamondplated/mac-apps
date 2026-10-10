# Mac Tools settings bridge

`ScreenWren.app/Contents/MacOS/ScreenWren --mac-tools-settings read` prints one JSON
snapshot and exits without starting the app. `--mac-tools-settings write` accepts
a JSON object on stdin, validates the entire patch, applies it to the same
preferences as the app, and prints a fresh snapshot. Errors go to stderr with a
nonzero exit. Input is limited to 64 KiB. The app's Info.plist advertises
`MacToolsSettingsProtocolVersion = 1`.

Snapshots include `schemaVersion: 1`, `app: "screenWren"`, actual `launchAtLogin`
and `loginStatus`, `captureDestination`, `showsThumbnail`, `adjustBeforeCapture`,
`selectionWidth`, `selectionHeight`, `aspectRatio`, `presets`, and `shortcuts`.
The first two fields and loginStatus are read-only. Settings writes may omit
unchanged fields; unknown fields and null top-level values are rejected.

- Capture destination: `clipboard`, `editor`, `pin`, `save`, or `review`.
- Selection width/height: both 0 for free selection, otherwise 4–16000 each.
- Aspect ratio: 0 for free selection, otherwise 0.01–100.
- Presets: up to 20 `{name,width,height}` objects with unique, nonempty names
  of at most 80 characters and dimensions 4–16000.
- Shortcuts: `{command,title,shortcut}` entries. `shortcut` is null to disable,
  or `{keyCode,carbonModifiers,keyEquivalent,keyLabel}`. Writes may include only
  changed commands. Commands must be known and unique, and the resulting full
  set must have no duplicate physical key/modifier combinations. Key codes are
  0–127; modifiers permit Command, Control, Option, Shift, and require at least
  one of Command, Control, Option. Titles are informational; snapshots always
  regenerate the command title.
- `resetShortcuts: true` restores defaults and cannot accompany `shortcuts`.

Login-item writes require an app directly inside `/Applications` or the current
user's `~/Applications`, with the ScreenWren bundle identifier and embedded login
helper. Renamed app bundles in those locations are supported; build directories
and nested copies are rejected. Writes use ServiceManagement, including its
approval status. Login changes occur
only after validation and before preferences; a failed login operation leaves
preferences untouched.

After a successful write, defaults synchronize and the bridge posts distributed
notification `com.andrew.mactools.settingsChanged`, object
`io.github.diamondplated.ScreenWren`, with boolean `shortcutsChanged`. The running
app synchronizes preferences, re-registers shortcuts when changed, refreshes its
menu/status, and closes cached settings windows so their next opening is fresh.
Editors and captures remain intact.
