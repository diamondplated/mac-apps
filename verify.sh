#!/bin/bash
set -euo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
BUILD=1
case "${1:-}" in
    '') [ "$#" -eq 0 ] || exit 64 ;;
    --no-build) [ "$#" -eq 1 ] || exit 64; BUILD=0 ;;
    *) echo "Usage: $0 [--no-build]" >&2; exit 64 ;;
esac
for script in build-app.sh install-app.sh verify.sh DockPeek/build_app.sh scripts/release.sh; do
    bash -n "$PROJECT_DIR/$script"
done
for script in build-app.sh install-app.sh qa.sh; do
    sh -n "$PROJECT_DIR/ScreenWren/$script"
done
sh -n "$PROJECT_DIR/scripts/verify-login.sh" "$PROJECT_DIR/scripts/install-login-check.sh"
"$PROJECT_DIR/scripts/verify-login.sh" --self-test
python3 "$PROJECT_DIR/scripts/compare-bundles.py" --self-test
for package in "$PROJECT_DIR/DockPeek" "$PROJECT_DIR/ScreenWren" "$PROJECT_DIR/MacTools"; do
    swift test --package-path "$package" --parallel
done
if [ "$BUILD" = 1 ]; then "$PROJECT_DIR/build-app.sh"; fi

APP="$PROJECT_DIR/dist/Mac Tools.app"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
for component in "$SPARKLE" "$SPARKLE/Versions/B/Updater.app" "$SPARKLE/Versions/B/XPCServices/Installer.xpc" "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" "$SPARKLE/Versions/B/Autoupdate"; do
    codesign --verify --deep --strict "$component"
done
for binary in "$SPARKLE/Sparkle" "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app/Contents/MacOS/Updater" "$SPARKLE/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer" "$SPARKLE/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"; do
    for architecture in arm64 x86_64; do lipo "$binary" -verify_arch "$architecture"; done
done
otool -L "$APP/Contents/MacOS/MacTools" | grep -F '@rpath/Sparkle.framework/' >/dev/null
otool -l "$APP/Contents/MacOS/MacTools" | grep -F '@executable_path/../Frameworks' >/dev/null
PLIST="$APP/Contents/Info.plist"
plutil -lint "$PLIST" >/dev/null
test "$(plutil -extract CFBundleIdentifier raw "$PLIST")" = com.andrew.mactools
test "$(plutil -extract CFBundleExecutable raw "$PLIST")" = MacTools
test "$(plutil -extract LSMinimumSystemVersion raw "$PLIST")" = 14.0
codesign --verify --deep --strict "$APP"
for name in MacTools DockPeek ScreenWren ScreenWrenLoginItem; do
    case "$name" in
        MacTools) bundle="$APP"; identifier=com.andrew.mactools; minimum=14.0 ;;
        DockPeek) bundle="$APP/Contents/Resources/Applications/DockPeek.app"; identifier=com.andrew.dockpeek; minimum=14.0 ;;
        ScreenWren) bundle="$APP/Contents/Resources/Applications/ScreenWren.app"; identifier=io.github.diamondplated.ScreenWren; minimum=26.0 ;;
        ScreenWrenLoginItem) bundle="$APP/Contents/Resources/Applications/ScreenWren.app/Contents/Library/LoginItems/ScreenWrenLoginItem.app"; identifier=io.github.diamondplated.ScreenWren.LoginItem; minimum=26.0 ;;
    esac
    test -x "$bundle/Contents/MacOS/$name"
    test "$(plutil -extract CFBundleIdentifier raw "$bundle/Contents/Info.plist")" = "$identifier"
    test "$(plutil -extract LSMinimumSystemVersion raw "$bundle/Contents/Info.plist")" = "$minimum"
    codesign --verify --deep --strict "$bundle"
    for architecture in arm64 x86_64; do
        lipo "$bundle/Contents/MacOS/$name" -verify_arch "$architecture"
        binary_minimum=$(xcrun vtool -arch "$architecture" -show-build "$bundle/Contents/MacOS/$name" | awk '$1 == "minos" { print $2 }')
        test "$binary_minimum" = "$minimum"
    done
done
SCREENWREN="$APP/Contents/Resources/Applications/ScreenWren.app"
"$SCREENWREN/Contents/MacOS/ScreenWren" --self-check
VERSION=$(plutil -extract CFBundleShortVersionString raw "$PLIST")
ARCHIVE="$PROJECT_DIR/dist/Mac-Tools-$VERSION.zip"
test -s "$ARCHIVE"
unzip -tq "$ARCHIVE"
# Verify a fresh archive extraction, including nested signatures and resource bytes.
QA_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mactools-verify.XXXXXX")
trap 'rm -rf "$QA_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ditto -x -k "$ARCHIVE" "$QA_DIR"
codesign --verify --deep --strict "$QA_DIR/Mac Tools.app"
python3 "$PROJECT_DIR/scripts/compare-bundles.py" "$APP" "$QA_DIR/Mac Tools.app"
echo "Mac Tools verification passed."
