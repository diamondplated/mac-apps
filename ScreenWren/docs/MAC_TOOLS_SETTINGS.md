# Mac Tools settings bridge

`ScreenWren.app/Contents/MacOS/ScreenWren --mac-tools-settings read` prints one JSON
snapshot and exits without starting the app. `--mac-tools-settings write` accepts
a JSON object on stdin, validates the entire patch, applies it to the same
preferences as the app, and prints a fresh snapshot. Errors go to stderr with a
nonzero exit. Input is limited to 64 KiB. The app's Info.plist advertises
`MacToolsSettingsProtocolVersion = 1`.

Snapshots include `schemaVersion: 1`, `app: "screenWren"`, actual `launchAtLogin`
and `loginStatus`, `captureDestination`, `showsThumbnail`, `adjustBeforeCapture`,
`selectionWidth`, `selectionHeight`, `aspectRatio`, `presets`, `shortcuts`,
`permissions`, and `permissionsSource`. The first two fields, loginStatus,
permissions, and permissionsSource are read-only. Settings writes may omit
unchanged fields; unknown fields (including the read-only ones) and null top-level
values are rejected.

`permissions` is `{"screenRecording": Bool}`. macOS may judge the helper process
by the manager that started it, so the helper first asks the running app:

- If exactly one other running process has ScreenWren's bundle identifier and the
  same resolved bundle path as the helper, the helper posts distributed
  notification `com.andrew.screenwren.statusRequest` (object: the bundle
  identifier; userInfo `token`) and waits up to 0.5 s.
- The running app replies with `com.andrew.screenwren.statusReply` (object: the
  token; userInfo `pid` and `permissions`). Replies naming any other pid are
  ignored. This only filters stray replies; it is not authentication, since any
  local process can post a distributed notification. The value is display-only
  status and never grants anything.
- With that reply, `permissions` carries the app's `screenRecording` value and
  `permissionsSource` is `"runningApp"`. With no single matching copy, no reply, or
  a reply without `screenRecording`, the helper reports its own check and
  `permissionsSource` is `"currentProcess"`.

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
- Snapshots list every shortcut command in a fixed order: `capture`, `copyText`,
  `repeatCapture`, `frontWindow`, `freeze`, `recents`, `togglePins`,
  `recordRegion`, `pickColour`. New commands are only ever appended, start
  unassigned, and need no schema change; a write from an older manager that omits
  them leaves them as they are.
- Recording export options (format, size, GIF frame rate) are ScreenWren's own
  preferences and are not part of the bridge.
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
menu/status, and closes a cached Permissions & Shortcuts window so its next opening
is fresh. Editors and captures remain intact.

ScreenWren has no settings window of its own. **Settings…** opens
`mactools://app/screenWren`; when no handler opens that link (a manager that
predates it), ScreenWren launches Mac Tools from `/Applications` or
`~/Applications`, and with neither present it shows an alert.
