# RightHere

Finder's missing right-click items: **New File**, **Open Terminal Here** and **Copy Path**, from a small Finder extension. macOS 14 or later; universal Apple Silicon and Intel. The name is a working title.

The containing app has one small window that says whether the extension is on and opens the right pane of System Settings. It has no menu bar icon, is not a login item, and quitting it (closing the window) changes nothing: Finder runs the extension itself.

## Switch it on

1. Open RightHere and choose **Turn On in System Settings** (or open System Settings, Login Items & Extensions, Finder, and tick RightHere).
2. Right-click a folder's background or a file in Finder. If the items do not appear right away, choose Apple menu, Force Quit, Finder, Relaunch.

**Toolbar button.** In Finder, choose View, Customize Toolbar, and drag the RightHere button into the toolbar. It offers the same three items for the folder you are looking at.

## What it adds

- **New File** has a submenu with one entry per configured extension ("Text File", "Markdown File", otherwise "PY File"). It creates `untitled.<ext>` in the folder (beside a selected item), or `untitled 2`, `untitled 3` and so on when the name is taken, then selects it in Finder. It never overwrites.
- **Open Terminal Here** opens the folder in your chosen terminal: a selected folder itself, a selected file's folder, otherwise the folder Finder is showing. Terminal, iTerm, Ghostty, Warp, kitty, WezTerm and Alacritty are offered when installed; a terminal that has gone falls back to Terminal.
- **Copy Path** copies the POSIX path of each selected item, one per line, or the folder's path when nothing is selected.

By default all three show, and New File offers `txt` and `md`. Mac Tools holds every setting; the extension picks up a change the next time a menu opens. Nothing is badged and the extension does nothing in Finder's observation callbacks.

## The only file operation

The one thing RightHere does to your files is create an empty file with a name that is not taken (`O_CREAT | O_EXCL`, so the system refuses an existing name even in a race). Nothing deletes, moves, renames or overwrites. When creating fails (a read-only folder, say) nothing is created and Finder beeps.

## Sandbox and security

A Finder extension must be sandboxed, and a sandboxed process cannot create files in arbitrary folders. This suite is not on the Mac App Store, so the extension carries two narrow temporary exceptions (`Extension/RightHereFinder.entitlements`) and nothing else:

- `com.apple.security.temporary-exception.files.absolute-path.read-write` for `/Users/` and `/Volumes/`: this is what lets New File create the file itself in your home folders, other users' shared folders and external or network volumes. It is the narrowest path list that covers where people create files; folders elsewhere (system locations) fail cleanly. It also grants read access to those paths, which the extension does not use beyond checking that a name is free.
- `com.apple.security.temporary-exception.shared-preference.read-only` for the single domain `com.andrew.righthere`: how the extension reads its settings without an app group.

The extension does the work itself rather than handing it to the app, so there is no URL scheme or helper that another program could ask to create files, and the app does not have to launch for a click. The cost is that the extension's sandbox holds a broad read-write exception for `/Users/` and `/Volumes/`, where a handoff to an unsandboxed app would need none.

Report a vulnerability as described in the repository's `SECURITY.md`.

## Development

Run `swift test --package-path RightHere` from the repository root, then `RightHere/build-app.sh`, which builds a universal, hardened `dist/RightHere.app` with the extension embedded at `Contents/PlugIns/RightHereFinder.appex`, signed inside out (extension with its entitlements first, then the app; never `codesign --deep`). The build script accepts `SCREENWREN_SIGNING_IDENTITY` and `SCREENWREN_SIGNING_TIMESTAMP` (`secure` or `none`); otherwise it uses the existing ScreenWren signing configuration when available, falling back to ad-hoc signing. It never registers the extension: that happens when an installed copy is first opened. `RightHere --self-check` runs pure checks (menu contents, a temporary folder, patch validation) without touching Finder, the extension or preferences. `RIGHTHERE_WINDOW_SNAPSHOT=/dir/name.png swift test --package-path RightHere --filter WindowRenderTests` renders the window to PNG in light and dark, on and off. `Resources/generate-icon.swift <dir>` draws the icon set for `iconutil`.

## Settings bridge

`RightHere --mac-tools-settings read` returns JSON with `schemaVersion: 1`, `app: "rightHere"`, `showsNewFile`, `showsOpenTerminal`, `showsCopyPath` (Booleans, default true), `newFileExtensions` (default `["txt","md"]`), `terminalBundleIdentifier` (default `com.apple.Terminal`), and the read-only `availableTerminals` (installed terminals from the fixed list, as `{ bundleIdentifier, name }`), `extensionEnabled`, `terminalFellBack`, `launchAtLogin` (always false) and `loginStatus` (always `"notApplicable"`).

`write` accepts one JSON object on stdin and validates the whole patch before writing anything. `newFileExtensions` takes 1 to 8 unique entries of 1 to 10 characters from `a-z0-9`; `terminalBundleIdentifier` must be one of `availableTerminals`. Unknown or read-only keys, nulls and wrongly typed values are rejected; `launchAtLogin: false` is accepted and changes nothing, `true` is rejected because the app does not stay running. If the saved terminal is no longer installed, the snapshot reports Terminal with `terminalFellBack: true`. Settings live in the preference domain `com.andrew.righthere`, which the extension reads.
