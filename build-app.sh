#!/bin/bash
set -euo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
DIST_DIR="$PROJECT_DIR/dist"
APP_PATH="$DIST_DIR/Mac Tools.app"
REUSE_PAYLOADS=0
case "${1:-}" in
    '') [ "$#" -eq 0 ] || exit 64 ;;
    --reuse-payloads) [ "$#" -eq 1 ] || exit 64; REUSE_PAYLOADS=1 ;;
    *) echo "Usage: $0 [--reuse-payloads]" >&2; exit 64 ;;
esac

# Use the same persistent identity as ScreenWren without changing payload signatures.
if [ -n "${SCREENWREN_SIGNING_IDENTITY:-}" ]; then
    SIGNING_IDENTITY=$SCREENWREN_SIGNING_IDENTITY
elif [ -f "$PROJECT_DIR/ScreenWren/.screenwren-signing-identity" ]; then
    SIGNING_IDENTITY=$(cat "$PROJECT_DIR/ScreenWren/.screenwren-signing-identity")
    [ -n "$SIGNING_IDENTITY" ] || { echo "Saved signing identity is empty." >&2; exit 1; }
else
    SIGNING_IDENTITY=-
fi
if [ -n "${SCREENWREN_SIGNING_TIMESTAMP:-}" ]; then
    SIGNING_TIMESTAMP=$SCREENWREN_SIGNING_TIMESTAMP
elif [ -z "${SCREENWREN_SIGNING_IDENTITY:-}" ] && [ -f "$PROJECT_DIR/ScreenWren/.screenwren-signing-timestamp" ]; then
    SIGNING_TIMESTAMP=$(cat "$PROJECT_DIR/ScreenWren/.screenwren-signing-timestamp")
else
    SIGNING_TIMESTAMP=secure
fi
case "$SIGNING_TIMESTAMP" in
    secure) TIMESTAMP_OPTION=--timestamp ;;
    none) TIMESTAMP_OPTION=--timestamp=none ;;
    *) echo "SCREENWREN_SIGNING_TIMESTAMP must be secure or none." >&2; exit 64 ;;
esac

if [ "$REUSE_PAYLOADS" = 0 ]; then
    "$PROJECT_DIR/DockPeek/build_app.sh" --no-install --arch universal
    "$PROJECT_DIR/ScreenWren/build-app.sh"
fi
# Validate reused payloads before doing any compilation or signing.
for name in DockPeek ScreenWren; do
    if [ "$name" = DockPeek ]; then
        source_app="$PROJECT_DIR/DockPeek/DockPeek.app"
        identifier=com.andrew.dockpeek
        minimum=14.0
    else
        source_app="$PROJECT_DIR/ScreenWren/dist/ScreenWren.app"
        identifier=io.github.diamondplated.ScreenWren
        minimum=26.0
    fi
    codesign --verify --deep --strict "$source_app"
    test "$(plutil -extract CFBundleIdentifier raw "$source_app/Contents/Info.plist")" = "$identifier"
    test "$(plutil -extract CFBundleExecutable raw "$source_app/Contents/Info.plist")" = "$name"
    test "$(plutil -extract LSMinimumSystemVersion raw "$source_app/Contents/Info.plist")" = "$minimum"
    for architecture in arm64 x86_64; do
        lipo "$source_app/Contents/MacOS/$name" -verify_arch "$architecture"
    done
done
HELPER="$PROJECT_DIR/ScreenWren/dist/ScreenWren.app/Contents/Library/LoginItems/ScreenWrenLoginItem.app"
test "$(plutil -extract CFBundleIdentifier raw "$HELPER/Contents/Info.plist")" = io.github.diamondplated.ScreenWren.LoginItem
for architecture in arm64 x86_64; do
    lipo "$HELPER/Contents/MacOS/ScreenWrenLoginItem" -verify_arch "$architecture"
done

mkdir -p "$DIST_DIR" "$PROJECT_DIR/.build"
STAGING_DIR=$(mktemp -d "$DIST_DIR/.mactools-build.XXXXXX")
trap 'rm -rf "$STAGING_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
STAGING_APP="$STAGING_DIR/Mac Tools.app"
mkdir -p "$STAGING_APP/Contents/MacOS" "$STAGING_APP/Contents/Resources/Applications"
BINARIES=()
for architecture in arm64 x86_64; do
    scratch="$PROJECT_DIR/.build/package-$architecture"
    triple="$architecture-apple-macosx14.0"
    swift build --package-path "$PROJECT_DIR/MacTools" --scratch-path "$scratch" -c release --triple "$triple"
    binary_dir=$(swift build --package-path "$PROJECT_DIR/MacTools" --scratch-path "$scratch" -c release --triple "$triple" --show-bin-path)
    BINARIES+=("$binary_dir/MacTools")
done
lipo -create "${BINARIES[@]}" -output "$STAGING_APP/Contents/MacOS/MacTools"
chmod 755 "$STAGING_APP/Contents/MacOS/MacTools"
cp "$PROJECT_DIR/MacTools/Info.plist" "$STAGING_APP/Contents/Info.plist"
cp "$PROJECT_DIR/MacTools/Resources/MacTools.icns" "$STAGING_APP/Contents/Resources/MacTools.icns"
plutil -lint "$STAGING_APP/Contents/Info.plist" >/dev/null
test "$(plutil -extract CFBundleIdentifier raw "$STAGING_APP/Contents/Info.plist")" = com.andrew.mactools
test "$(plutil -extract CFBundleExecutable raw "$STAGING_APP/Contents/Info.plist")" = MacTools
test "$(plutil -extract LSMinimumSystemVersion raw "$STAGING_APP/Contents/Info.plist")" = 14.0
VERSION=$(plutil -extract CFBundleShortVersionString raw "$STAGING_APP/Contents/Info.plist")
case "$VERSION" in
    ''|*[!A-Za-z0-9._-]*) echo "Invalid manager version." >&2; exit 1 ;;
esac
for architecture in arm64 x86_64; do
    lipo "$STAGING_APP/Contents/MacOS/MacTools" -verify_arch "$architecture"
    binary_minimum=$(xcrun vtool -arch "$architecture" -show-build "$STAGING_APP/Contents/MacOS/MacTools" | awk '$1 == "minos" { print $2 }')
    test "$binary_minimum" = 14.0
done

for name in DockPeek ScreenWren; do
    if [ "$name" = DockPeek ]; then
        source_app="$PROJECT_DIR/DockPeek/DockPeek.app"
        identifier=com.andrew.dockpeek
        minimum=14.0
    else
        source_app="$PROJECT_DIR/ScreenWren/dist/ScreenWren.app"
        identifier=io.github.diamondplated.ScreenWren
        minimum=26.0
    fi
    codesign --verify --deep --strict "$source_app"
    test "$(plutil -extract CFBundleIdentifier raw "$source_app/Contents/Info.plist")" = "$identifier"
    test "$(plutil -extract LSMinimumSystemVersion raw "$source_app/Contents/Info.plist")" = "$minimum"
    test -n "$(plutil -extract CFBundleShortVersionString raw "$source_app/Contents/Info.plist")"
    ditto "$source_app" "$STAGING_APP/Contents/Resources/Applications/$name.app"
done

# Sign only the manager. --deep here would replace the embedded apps' identities.
if [ "$SIGNING_IDENTITY" = - ]; then
    echo "Building an ad-hoc package for verification; installation requires a persistent signing identity." >&2
    codesign --force --options runtime --sign - --timestamp=none "$STAGING_APP"
else
    codesign --force --options runtime --sign "$SIGNING_IDENTITY" "$TIMESTAMP_OPTION" "$STAGING_APP"
fi
codesign --verify --deep --strict "$STAGING_APP"
for name in DockPeek ScreenWren; do
    embedded="$STAGING_APP/Contents/Resources/Applications/$name.app"
    codesign --verify --deep --strict "$embedded"
done
# Confirm packaging and enclosing-signature creation did not alter any payload bytes.
diff -qr "$PROJECT_DIR/DockPeek/DockPeek.app" "$STAGING_APP/Contents/Resources/Applications/DockPeek.app"
diff -qr "$PROJECT_DIR/ScreenWren/dist/ScreenWren.app" "$STAGING_APP/Contents/Resources/Applications/ScreenWren.app"

ARCHIVE_NAME="Mac-Tools-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$STAGING_APP" "$STAGING_DIR/$ARCHIVE_NAME"
unzip -tq "$STAGING_DIR/$ARCHIVE_NAME"
rm -rf "$APP_PATH"
mv "$STAGING_APP" "$APP_PATH"
mv -f "$STAGING_DIR/$ARCHIVE_NAME" "$DIST_DIR/$ARCHIVE_NAME"
echo "$APP_PATH"
echo "$DIST_DIR/$ARCHIVE_NAME"
