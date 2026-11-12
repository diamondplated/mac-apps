# DockPeek

A native, lightweight macOS utility built in Swift that brings live window hover previews ("Window Peeking") to the macOS Dock — similar to DockDoor and DockMate.

## Features

- **Live Window Hover Previews:** Hover over any active application icon in the macOS Dock to see live thumbnail previews of all open windows for that app.
- **Smart Alignment:** Automatically detects Dock orientation (Bottom, Left, or Right) and positions the floating preview HUD cleanly adjacent to the hovered icon.
- **Click to Focus:** Clicking any window preview immediately brings that specific window to the front and activates the application.
- **Open Tabs:** Windows that expose an accessible tab strip (including Chrome) show a scrollable list of tab titles below their preview. The active tab carries a checkmark; click a tab to select it and bring its window forward. Tabs stay grouped by window, and duplicate titles remain separate entries.
- **Quick Close (`x`):** Hover over a window card to reveal a close button to dismiss windows directly from the preview without switching into the app.
- **Window Switcher (⌥Tab, on by default):** Hold ⌥ and press Tab to see every window of every app, on every Space and display, most recently used first, with minimized windows last. Each card shows a live thumbnail, the app icon and the window title. Tab and ⇧Tab (or the arrow keys) move the highlight; releasing ⌥ switches to that window and Esc closes the panel without switching. A quick ⌥Tab switches straight to the window you were in before, without showing the panel. Turn it off on DockPeek's page in Mac Tools.
- **Dock Click Actions (each off by default):** Three separate switches on DockPeek's page in Mac Tools change what a Dock icon does:
  - **Click to hide:** clicking the icon of the app that is already in front hides it. Every other click (another app, a click with a modifier key, click-and-hold, dragging, right-clicking, the Trash, folders, minimized windows) works as usual.
  - **Scroll to cycle windows:** scrolling over a running app's icon brings its next or previous window forward, one window per scroll step.
  - **Middle-click for a new window:** middle-clicking a running app's icon brings it forward and sends it ⌘N. A middle click on an app that is not running does what it always did.
- **Window Layouts (off by default):** When displays are connected or disconnected, macOS scrambles window positions. With **Restore window layouts** on in Mac Tools, DockPeek remembers where every ordinary window sits for each monitor arrangement and moves them back when that arrangement returns. This is the only DockPeek feature that moves windows by itself, so it starts off.
  - An arrangement is the set of connected displays and where they sit relative to each other. It is recognised by each display's vendor, model and serial (the built-in display by being built in), so it is the same after a reboot or renumbering, and at a different resolution. Positions are stored as fractions of the display, and a restored window is always clamped inside the display's visible area.
  - DockPeek notes window positions a few seconds after windows stop moving. After a display change it waits until the changes stop, then restores each still-open window it has a remembered place for; others are left alone. Windows are matched by app and title; when titles have changed it falls back to window order only if exactly one remembered window and one open window are left for that app, and otherwise leaves them alone. Saving updates the windows that are open and keeps every other remembered place (minimized, full-screen, on another Space, or in an app that is not running yet); places leave only when the 20-arrangement or 300-window cap pushes out the oldest, or on Forget Saved Layouts. A window that appears later (after login, say) is moved to its remembered place once, the first time it is seen, and never again until the displays change. Before moving anything DockPeek checks the displays still form the arrangement it planned for. Full-screen and minimized windows are skipped, and DockPeek never switches Spaces: windows on other Spaces move only if Accessibility lists them.
  - The status menu has **Save Window Layout** and **Restore Window Layout**, which work even with automatic restoring off. Holding Option on the Restore item shows **Forget Saved Layouts**, which asks before deleting. A store file DockPeek cannot read is kept as `WindowLayouts.json.unreadable` instead of being overwritten.
  - Window titles are stored locally in `~/Library/Application Support/DockPeek/WindowLayouts.json` (readable only by you, the 20 most recently used arrangements) with bundle identifiers and frames, and never leave the Mac.
- **Menu Bar Companion:** Runs as an accessory (`LSUIElement`) with a menu bar status icon. The menu shows a status line, **Grant Accessibility…** / **Grant Screen Recording…** only while that permission is missing, **Settings…** (opens DockPeek's page in Mac Tools, `mactools://app/dockPeek`, falling back to opening Mac Tools) and **Quit**.
- **Reliable Dismissal:** Previews close after the pointer spends about 0.6 seconds outside the Dock icon and preview, with a grace period for crossing between them.
- **Lightweight Hover Checks:** Event-driven Dock detection, with pointer-position checks only during an active hover to recover from missed mouse-exit events.

---

## Getting Started

### 1. Install DockPeek
DockPeek ships inside Mac Tools. Download Mac Tools from
[mac-tools-releases](https://github.com/diamondplated/mac-tools-releases/releases/latest),
open it, and install DockPeek from there. Mac Tools keeps it updated.

### 2. Grant macOS Permissions
Because macOS protects other applications' windows and screen contents, two standard permissions are required:

1. **Accessibility (`System Settings > Privacy & Security > Accessibility`)**:
   - Allows DockPeek to identify which application icon you are hovering over in the Dock, and to programmatically raise/focus individual windows when clicked.
2. **Screen Recording (`System Settings > Privacy & Security > Screen & System Audio Recording`)**:
   - Allows macOS to generate live visual thumbnails of running application windows.

When you launch DockPeek for the first time, click the **DockPeek icon** in your menu bar (top right) to see the status and grant any missing permission.

The window switcher and the Dock click actions use only Accessibility. Without Screen Recording, switcher cards show app icons instead of thumbnails; without Accessibility the switcher and the Dock actions do nothing until it is granted from the menu. Each feature installs its keyboard or mouse listener only while it is switched on, and removes it when switched off.

Tab discovery uses the existing Accessibility permission; no browser extension or Automation permission is required. Lists refresh whenever you hover over the app again. Background tabs are listed by title; the thumbnail shows the window's currently selected tab. Availability depends on the app exposing its tab strip, so hidden/collapsed tabs that an app omits from Accessibility cannot be listed. Apps without an accessible tab strip retain their window previews. Discovery skips webpage content and is bounded to keep an unresponsive app or an unusually large accessibility tree from blocking previews.

---

## Rebuilding

To rebuild the app bundle from source at any time:
```bash
cd DockPeek
./build_app.sh
```

DockPeek signs with the same persistent local identity as ScreenWren
(`SCREENWREN_SIGNING_IDENTITY` or the saved identity file) and hardened runtime,
so its certificate-anchored designated requirement keeps permissions across
rebuilds. Without an identity it builds ad-hoc for verification only and refuses
to install. Builds before Mac Tools 1.2.2 used an identifier-only requirement
that any app could satisfy; moving off it needs a one-time re-grant of
Accessibility and Screen Recording.

---

## Architecture

- **`DockObserver.swift`**: Monitors cursor position relative to the Dock and queries `AXUIElement` on `com.apple.dock` to extract the target application PID and icon coordinates.
- **`Switcher/`**: The ⌥Tab window switcher. `SwitcherLogic.swift` holds every decision as pure functions (window order, the previous-window rule, highlight movement, quick ⌥Tab, key routing, grid layout); `SwitcherWindowSource.swift` lists windows from the window server and Accessibility; `SwitcherController.swift` owns the key tap, the session and the panel.
- **`DockClicks/`**: The Dock click actions. `DockClickLogic.swift` decides which clicks and scrolls are acted on and which pass through, and turns scrolling into steps; `DockHitTester.swift` asks only the Dock what is under the pointer; `DockClickController.swift` owns the mouse tap.
- **`Layouts/`**: Window layouts. `LayoutLogic.swift` holds every decision as pure functions (display identity and arrangement key, matching remembered windows to open ones, relative frames and clamping, the settle timers); `LayoutStore.swift` is the capped on-disk store; `LayoutSystem.swift` reads displays and windows and moves windows through Accessibility; `LayoutController.swift` owns a one-second timer and a screen-change observer, installed only while automatic restoring is on. It adds no event tap or hot key.
- **`EventTap.swift`**: Session event taps on their own thread. Unclaimed events pass untouched, a tap the system disables is re-enabled at once, and a switched-off feature's tap is removed.
- **`HoverDismissalState.swift`**: Uses current pointer geometry and a bounded departure grace period; no cached mouse-enter flag or permanent transit corridor.
- **`WindowService.swift`**: Enumerates active application windows using `CGWindowListCopyWindowInfo` and captures live thumbnails using `CGWindowListCreateImage`. Manages window raising via `AXUIElementPerformAction(kAXRaiseAction)`.
- **`TabService.swift`**: Finds native Accessibility tab groups, reads their tab titles and selection state, and selects the original tab element without relying on a mutable index or a unique title.
- **`PreviewPanel.swift` & `PreviewView.swift`**: Non-activating, floating `NSPanel` hosting a SwiftUI view with system material, semantic colours that follow light and dark mode, the suite's corner-radius scale (6, 10, 14), a window shadow, eased hover states and an animated resize when its content changes.
- **`RunningAppPermissions.swift`**: Lets the settings bridge ask the running DockPeek for its own permission state (matching the exact bundle path), so Mac Tools can show it; the snapshot's `permissionsSource` is `runningApp` when it answered and `currentProcess` otherwise.
- **`Permissions.swift`**: Queries and prompts for macOS Accessibility and Screen Recording permissions.
- **`AppDelegate.swift`**: Manages the menu bar status item and coordinates events between the observer and the preview panel.

## Verification

Run the tab-discovery, preview-layout, and hover-dismissal regression tests from the repository root:

```sh
swift test --package-path DockPeek
```

After launching a rebuilt app, check that moving from a Dock icon into its preview keeps it open, while moving out and stopping closes it after about 0.6 seconds. Also check stopping in the gap, leaving beside the preview, dragging away, and moving rapidly between applications. Repeat with side-mounted Docks and additional displays when available.

For tabs, use two Chrome windows with different active tabs, duplicate titles, grouped tabs, and more than five tabs in one window. Hover Chrome in the Dock, scroll the list, and select a background tab in each window. Check a minimized window, close a tab before clicking its old preview entry, and confirm that an ordinary app still shows only its windows. Tab rows switch tabs; the `x` on the thumbnail still closes the entire window.

An optional read-only integration test checks a running Chrome instance and its exposed selection actions (the test host must already have Accessibility access):

```sh
DOCKPEEK_TEST_CHROME=1 swift test --package-path DockPeek
```

Set `DOCKPEEK_PREVIEW_SNAPSHOT=/tmp/dockpeek-preview.png` on the same command to also save rendered preview fixtures for visual inspection: the tabbed fixture at that path, `-light`/`-dark` with `-windows`/`-tabs` variants beside it, and the window switcher as `-switcher-light`/`-switcher-dark` with `-row`, `-wrap` and `-scroll` variants.

For window layouts, dock and undock an external display (and close the lid with one attached), change an external display's resolution and reconnect it, then check that windows return to their places with automatic restoring on, and that the two menu commands do the same by hand with it off.

For the switcher, check a quick ⌥Tab between two windows (no panel flashes), holding ⌥ through several Tabs and ⇧Tabs, the arrow keys, Esc, a window on another Space, a minimized window, and an app that is hidden. For the Dock actions, turn each on in Mac Tools and check its pass-through cases as well as the action itself: a trackpad swipe and a fast wheel spin over an icon should each move one window at a time.
