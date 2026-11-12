#!/bin/sh
# Builds dist/RightHere.app: universal, hardened, signed, with the sandboxed Finder Sync extension
# embedded at Contents/PlugIns/RightHereFinder.appex.
#
# THIS SCRIPT NEVER REGISTERS THE EXTENSION: no pluginkit, no lsregister, no launching the app.
# A build that stays in dist/ is not known to LaunchServices; macOS finds the extension when an
# installed copy of the app is first opened.
set -eu
PROJECT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
IDENTITY_FILE="$PROJECT_DIR/../ScreenWren/.screenwren-signing-identity"
if [ -n "${SCREENWREN_SIGNING_IDENTITY:-}" ]; then
    SIGNING_IDENTITY=$SCREENWREN_SIGNING_IDENTITY
elif [ -s "$IDENTITY_FILE" ]; then
    SIGNING_IDENTITY=$(cat "$IDENTITY_FILE")
else
    SIGNING_IDENTITY=-
fi
if [ -n "${SCREENWREN_SIGNING_TIMESTAMP:-}" ]; then
    SIGNING_TIMESTAMP=$SCREENWREN_SIGNING_TIMESTAMP
elif [ -z "${SCREENWREN_SIGNING_IDENTITY:-}" ] && [ -f "$PROJECT_DIR/../ScreenWren/.screenwren-signing-timestamp" ]; then
    SIGNING_TIMESTAMP=$(cat "$PROJECT_DIR/../ScreenWren/.screenwren-signing-timestamp")
else
    SIGNING_TIMESTAMP=secure
fi
case "$SIGNING_TIMESTAMP" in
    secure) TIMESTAMP_OPTION=--timestamp ;;
    none) TIMESTAMP_OPTION=--timestamp=none ;;
    *) echo 'SCREENWREN_SIGNING_TIMESTAMP must be secure or none.' >&2; exit 64 ;;
esac
mkdir -p "$PROJECT_DIR/dist"
STAGE=$(mktemp -d "$PROJECT_DIR/dist/.righthere-build.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT INT TERM
for architecture in arm64 x86_64; do
    for product in RightHere RightHereFinder; do
        swift build --package-path "$PROJECT_DIR" --scratch-path "$STAGE/$architecture" --configuration release --triple "$architecture-apple-macosx14.0" --product "$product"
    done
    bin=$(swift build --package-path "$PROJECT_DIR" --scratch-path "$STAGE/$architecture" --configuration release --triple "$architecture-apple-macosx14.0" --show-bin-path)
    cp "$bin/RightHere" "$STAGE/RightHere-$architecture"
    cp "$bin/RightHereFinder" "$STAGE/RightHereFinder-$architecture"
done
APP="$STAGE/RightHere.app"
APPEX="$APP/Contents/PlugIns/RightHereFinder.appex"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APPEX/Contents/MacOS"
lipo -create "$STAGE/RightHere-arm64" "$STAGE/RightHere-x86_64" -output "$APP/Contents/MacOS/RightHere"
lipo -create "$STAGE/RightHereFinder-arm64" "$STAGE/RightHereFinder-x86_64" -output "$APPEX/Contents/MacOS/RightHereFinder"
cp "$PROJECT_DIR/Info.plist" "$APP/Contents/Info.plist"
cp "$PROJECT_DIR/Extension/Info.plist" "$APPEX/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/RightHere.icns" "$APP/Contents/Resources/RightHere.icns"
chmod 755 "$APP/Contents/MacOS/RightHere" "$APPEX/Contents/MacOS/RightHereFinder"
plutil -lint "$APP/Contents/Info.plist" "$APPEX/Contents/Info.plist"
plutil -lint "$PROJECT_DIR/Extension/RightHereFinder.entitlements"
# Versions stay in step: the extension carries the app's.
[ "$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")" = "$(plutil -extract CFBundleShortVersionString raw "$APPEX/Contents/Info.plist")" ] || { echo 'App and extension versions differ.' >&2; exit 1; }
[ "$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")" = "$(plutil -extract CFBundleVersion raw "$APPEX/Contents/Info.plist")" ] || { echo 'App and extension builds differ.' >&2; exit 1; }
# Inside out, no --deep: the extension first, with its sandbox entitlements, then the app with none.
if [ "$SIGNING_IDENTITY" = - ]; then
    codesign --force --options runtime --sign - --timestamp=none --entitlements "$PROJECT_DIR/Extension/RightHereFinder.entitlements" "$APPEX"
    codesign --force --options runtime --sign - --timestamp=none "$APP"
else
    codesign --force --options runtime --sign "$SIGNING_IDENTITY" "$TIMESTAMP_OPTION" --entitlements "$PROJECT_DIR/Extension/RightHereFinder.entitlements" "$APPEX"
    codesign --force --options runtime --sign "$SIGNING_IDENTITY" "$TIMESTAMP_OPTION" "$APP"
fi
codesign --verify --strict "$APPEX"
codesign --verify --strict "$APP"
for architecture in arm64 x86_64; do
    lipo "$APP/Contents/MacOS/RightHere" -verify_arch "$architecture"
    lipo "$APPEX/Contents/MacOS/RightHereFinder" -verify_arch "$architecture"
done
# The extension must be sandboxed and hardened, whatever else changes.
codesign -d --entitlements - "$APPEX" 2>/dev/null | grep -q 'com.apple.security.app-sandbox' || { echo 'The extension is not sandboxed.' >&2; exit 1; }
codesign -dv "$APPEX" 2>&1 | grep -q 'flags=.*runtime' || { echo 'The extension is not hardened.' >&2; exit 1; }
"$APP/Contents/MacOS/RightHere" --self-check
rm -rf "$PROJECT_DIR/dist/RightHere.app"
mv "$APP" "$PROJECT_DIR/dist/RightHere.app"
echo "Built $PROJECT_DIR/dist/RightHere.app"
