# Contributing to ScreenWren

Thanks for helping make the capture loop faster, safer, and simpler. ScreenWren is
small on purpose: a native macOS menu-bar app, no account or cloud service, and no
third-party package dependencies.

## Before starting

- Search existing [mac-tools issues](https://github.com/diamondplated/mac-tools/issues)
  and [pull requests](https://github.com/diamondplated/mac-tools/pulls).
- Open a focused feature request before a large product or architecture change.
- Report vulnerabilities privately through [SECURITY.md](SECURITY.md).
- Use synthetic screenshots and OCR text in public issues and test fixtures.

## Development requirements

- macOS 26 or newer.
- Xcode 26 with the macOS 26 SDK.
- Swift 6.2 or the version shipped with the supported Xcode release.

Clone [mac-tools](https://github.com/diamondplated/mac-tools), change into its
`ScreenWren/` directory, then verify the package:

```sh
swift test --parallel
swift build -c release
.build/release/ScreenWren --self-check
```

Build a Universal 2 app (using the saved certificate for a persistent local identity):

```sh
./install-app.sh
```

Run the headless repository harness with:

```sh
./qa.sh
```

It runs Swift tests, rebuilds the app, and validates its archive, both executable
architectures, property lists, nested login item, signatures, and self-checks. To
compare an installed build against a fresh reference build, pass its app path:

```sh
./qa.sh /Applications/ScreenWren.app
```

Real screen capture requires a logged-in graphical macOS session and Screen
Recording permission for the exact app identity being tested. It is explicitly
opt-in:

```sh
SCREENWREN_LIVE_QA=1 ./qa.sh
```

## Project shape

- `Sources/ScreenWren/` — AppKit application, capture, editing, and export code.
- `Sources/ScreenWrenLoginItem/` — quiet native login-item launcher.
- `Tests/ScreenWrenTests/` — Swift XCTest coverage.
- `Resources/` — application icon assets.
- `Info.plist` and `LoginItem-Info.plist` — bundle identities and capabilities.
- `build-app.sh` — reproducible local app-bundle assembly.
- `qa.sh` — package, bundle, signing, and native behavior verification.
- `DESIGN.md` — product invariants, failure behavior, and acceptance gates.

## Design rules

Changes should preserve these boundaries:

1. `⌃P → select → clipboard` remains the shortest ordinary path.
2. Cancellation and pre-delivery failures do not change the clipboard.
3. Stale asynchronous work does not open windows, add Recents, or overwrite newer
   clipboard content.
4. ScreenWren does not persist captures unless the user completes Save, Drag, or a
   chosen Share action.
5. Secure Redact and visual Blur remain clearly different operations.
6. Native Apple APIs and the standard library come before new dependencies.
7. Accessibility labels, keyboard cancellation, and clear failure states are part
   of the feature, not follow-up polish.

Read [DESIGN.md](DESIGN.md) and [PRIVACY.md](PRIVACY.md) before changing capture,
clipboard, export, retention, or permission behavior.

## Code and tests

- Keep UI and AppKit state on the main actor.
- Keep screenshot acquisition separate from clipboard/editor delivery.
- Prefer one shared implementation for Copy, Save, Drag, Share, and Pin rendering.
- Add the smallest runnable test or self-check that would fail if nontrivial logic
  regressed.
- Do not add a third-party dependency for behavior supplied by macOS, Swift, or the
  existing codebase without explicit maintainer agreement.
- Avoid logging captured content, OCR results, window titles, geometry, clipboard
  data, or local paths.

There is no mandatory formatter in the repository. Match the surrounding Swift
style and keep diffs focused.

## Release and CI ownership

The mac-tools repository owns shared CI and release configuration in its root
`.github/` directory. ScreenWren has no nested GitHub workflows. All GitHub Actions
jobs must use Andrew's self-hosted runners.

`build-app.sh` signs the nested login item before the outer app and produces the
Universal 2 bundle and versioned ZIP. Public distribution requires a Developer ID
Application signature and notarization. Keep signing selectors in the ignored
local files documented in [README.md](README.md), and credentials in Keychain or
protected runner secrets.

## Pull requests

A useful pull request includes:

- the user problem and why the change belongs in ScreenWren;
- a concise description of behavior and failure handling;
- automated checks run, with their exact commands;
- manual macOS flows tested, including permission state where relevant;
- screenshots or a short recording for visible UI changes, using synthetic data;
- privacy, clipboard, accessibility, and persistence impact; and
- a changelog entry for user-visible changes.

Do not include signing identities, certificates, notarization credentials, private
captures, or generated `dist/` products. Contributions are licensed under the
project's [MIT License](LICENSE).
