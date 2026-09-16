# Mac Tools

Native macOS utilities, starting with **DockPeek**, a menu bar app that shows
window previews when hovering over application icons in the Dock.

## DockPeek

Source, package configuration, and build instructions are in [DockPeek](DockPeek/README.md).
DockPeek requires macOS 14 or newer and the Swift toolchain (Xcode or Command Line Tools).

From the repository root, compile the app without installing it:

```sh
swift build --package-path DockPeek -c release
```

To build, package, sign, and install it into `/Applications/DockPeek.app`:

```sh
./DockPeek/build_app.sh
open /Applications/DockPeek.app
```

Enable Accessibility and Screen Recording permissions for window detection and previews.

Each utility lives in its own directory. Generated build output and app bundles
are excluded from version control.
