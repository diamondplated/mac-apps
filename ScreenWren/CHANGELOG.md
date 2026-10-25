# Changelog

All notable public changes to ScreenWren will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
published versions will follow [Semantic Versioning](https://semver.org/). The app
is currently pre-1.0, so minor versions may include incompatible behavior changes.

## [Unreleased]

### Added

- Visible editor tools for Select, Pen, Arrow, Box, Text, Highlight, Step, Crop,
  and Redact, with clear tooltips and keyboard equivalents.
- Drag-to-place editable arrows and boxes, arrow angle snapping, and Select-based
  cancellation, with native markup preserved in copy/export and Undo/Redo.
- Visible capture notices with retry or recovery actions and a persistent latest
  result in the menu-bar menu; notices preserve the current app's keyboard focus.
- Coordinator integration coverage for out-of-order capture completion, stale
  permission and window-lookup results, clipboard replacement during OCR, scrolling cancellation,
  and recovery of reviewed redactions after a failed copy.
- Configurable capture destinations, defaulting to clipboard-only, and an optional
  six-second thumbnail with Edit, Save, Pin, and PNG drag actions.
- A session-only thumbnail picker (Control-Shift-P) with removal and vertical,
  side-by-side, or grid composition of selected captures.
- Selection adjustment with arrow keys, exact pixel dimensions, aspect ratios,
  saved size presets, and synchronized cross-display capture at mixed scales.
- Redaction review before copying, with local email/phone/literal-text suggestions,
  manual masks, and protection for newer clipboard content.
- PNG/JPEG export presets with original/1× sizing, JPEG quality, and encoded-size preview.
- Pin opacity, zoom, click-through, menu-based unlocking, and hide/restore (Control-Option-P).
- Editable structured OCR previews for plain text, spreadsheet tables, and code spacing.

### Fixed

- Starting a capture no longer drags an open editor (or any other ScreenWren
  window) in front of the thing you are capturing. They step aside while the
  selector is up and return behind the app you were using.
- Persistent local signing can retain its certificate identity across rebuilds.
  The installer updates one verified `/Applications/ScreenWren.app`, preserves a
  rollback archive, and rejects ad-hoc replacements. Stale login registrations
  can be rebound to the installed helper after asynchronous removal completes.

- Annotation gestures work on the first click in an inactive editor. Pen and
  Highlight capture freehand mouse input and support consecutive editable strokes.
- Native toolbar arrows, rectangles, text, and ink tools use the same reliable
  insertion and drawing paths as the labeled editor controls.
- Arrow creation adds actual native markup rather than reporting a successful
  insertion after a PaperKit toolbar call that did not create an arrow.
- Text insertion reliably creates an editable placeholder without requiring a
  prior native toolbar interaction.
- Drawing and crop/redaction overlays follow the canvas when the toolbar changes
  rows as the window is resized.
- Shortcuts recover from temporary launch conflicts without resetting working
  keys. Shortcut warnings remain visible until registration succeeds.
- Failed hotkey registration removes its event handler only once.
- Switching apps during selection respects the chosen app instead of reactivating
  the app from which capture began; stale selector callbacks are ignored.
- Finish Scrolling Capture stays unavailable during acquisition and seam validation,
  preventing the requested segment from being silently dropped.
- Failed reviewed-image copies preserve the approved result in an editor, including
  captures that exceed the session Recents budget.
- Clipboard failure messages identify where to recover the image rather than
  claiming the clipboard stayed unchanged after a failed write.
- Text-capture recovery retries OCR, and superseded window lookups leave newer
  capture feedback alone.
- Existing custom shortcuts take precedence over conflicting new default shortcuts
  on upgrade; affected new commands remain available from the menu.
- Space and asynchronous window discovery hit-test correctly on offset displays.
- Window-mode clicks snap to windows even when a fixed-size preset is active.
- Odd-sized presets retain their exact pixel dimensions in Freeze captures,
  including after holding Space to reposition them.
- Copy-only captures open a recovery editor when newer clipboard content prevents
  delivery and the image exceeds the session Recents memory limit.
- Permission requests that are denied or no longer produce a system prompt lead
  to Screen Recording Settings. Quit & Reopen remains available whenever access
  is blocked, with Check Again and a way to reveal the exact app copy to re-add.
- Capture permission failures dismiss active selectors and pending work, then
  show recovery instructions even if the preflight check incorrectly says allowed.
- Capture selectors accept keyboard focus, enabling Escape, Space, Tab, and Return.
- Editor annotation shortcuts consume handled keys instead of delivering them to
  the canvas a second time.
- Shortcut conflicts compare physical keys and modifiers, including when keyboard
  layouts or shifted characters produce different display labels.
- Scrolling capture enforces its 256 MB memory limit from the first frame onward.
- Capture and editor menus preserve explicitly disabled actions when opened.
- Universal app builds verify architectures separately for compatibility with
  developer tools that reject multiple architectures in one verification command.

### Improved

- Editor tools wrap at narrow widths, with a separate operation-status strip and
  full status tooltips.
- Builds can remember a development signing identity in a Git-ignored local file.
- The standard Settings command (⌘,) reopens permission and shortcut setup.
- Local ad-hoc builds explicitly report that Screen Recording grants may not
  survive a rebuild; use a consistent signing certificate for development.
- Launching or reopening ScreenWren stays quietly in the menu bar. Readiness opens
  only when requested or when an explicit capture needs permission.
- The capture shortcut starts with region crosshairs. Space opts into window
  snapping; Escape, pressing the capture shortcut again, or switching apps dismisses
  an active selector.
- Standard Cut, Copy, Paste, and Select All commands follow the active text field
  or canvas through the Edit menu.

## [0.5.0] - 2026-07-20

### Added

- Precision region selection with a pixel loupe, live dimensions, and hold-Space
  repositioning.
- Immediate front-window capture, freeze-then-select capture, and exact window or
  region repeat.
- A native Readiness window for permission guidance, configurable global shortcuts,
  conflict reporting, default restoration, and Launch at Login.
- Instant Inspect for selectable image text, detected-code actions, and choosing
  among multiple foreground subjects.
- Editor keyboard commands for arrows, rectangles, highlighting, text, numbered
  steps, selection mode, and Copy and Close.
- Universal 2 app assembly with a signed nested login item and headless bundle QA.
- Initial open-source license, privacy and security policies, contribution guide,
  GitHub community templates, and CI/release workflow drafts.
