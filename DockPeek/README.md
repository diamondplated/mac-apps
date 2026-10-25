# DockPeek 🔍

A native, lightweight macOS utility built in Swift that brings live window hover previews ("Window Peeking") to the macOS Dock — similar to DockDoor and DockMate.

## Features

- **Live Window Hover Previews:** Hover over any active application icon in the macOS Dock to see live thumbnail previews of all open windows for that app.
- **Smart Alignment:** Automatically detects Dock orientation (Bottom, Left, or Right) and positions the floating preview HUD cleanly adjacent to the hovered icon.
- **Click to Focus:** Clicking any window preview immediately brings that specific window to the front and activates the application.
- **Open Tabs:** Windows that expose an accessible tab strip (including Chrome) show a scrollable list of tab titles below their preview. The active tab is marked; click a tab to select it and bring its window forward. Tabs stay grouped by window, and duplicate titles remain separate entries.
- **Quick Close (`x`):** Hover over a window card to reveal a close button to dismiss windows directly from the preview without switching into the app.
- **Menu Bar Companion:** Runs as an accessory (`LSUIElement`) with a menu bar status icon. It checks permission status and gives one-click access to privacy settings.
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

When you launch DockPeek for the first time, click the **DockPeek icon** in your menu bar (top right) to see the permission status and open the settings shortcuts.

Tab discovery uses the existing Accessibility permission; no browser extension or Automation permission is required. Lists refresh whenever you hover over the app again. Background tabs are listed by title; the thumbnail shows the window's currently selected tab. Availability depends on the app exposing its tab strip, so hidden/collapsed tabs that an app omits from Accessibility cannot be listed. Apps without an accessible tab strip retain their window previews. Discovery skips webpage content and is bounded to keep an unresponsive app or an unusually large accessibility tree from blocking previews.

---

## Rebuilding

To rebuild the app bundle from source at any time:
```bash
cd DockPeek
./build_app.sh
```

---

## Architecture

- **`DockObserver.swift`**: Monitors cursor position relative to the Dock and queries `AXUIElement` on `com.apple.dock` to extract the target application PID and icon coordinates.
- **`HoverDismissalState.swift`**: Uses current pointer geometry and a bounded departure grace period; no cached mouse-enter flag or permanent transit corridor.
- **`WindowService.swift`**: Enumerates active application windows using `CGWindowListCopyWindowInfo` and captures live thumbnails using `CGWindowListCreateImage`. Manages window raising via `AXUIElementPerformAction(kAXRaiseAction)`.
- **`TabService.swift`**: Finds native Accessibility tab groups, reads their tab titles and selection state, and selects the original tab element without relying on a mutable index or a unique title.
- **`PreviewPanel.swift` & `PreviewView.swift`**: Non-activating, floating `NSPanel` hosting a SwiftUI view with native `.ultraThinMaterial` styling, drop shadows, and hover animations.
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

Set `DOCKPEEK_PREVIEW_SNAPSHOT=/tmp/dockpeek-preview.png` on the same command to also save a rendered preview fixture for visual inspection.
