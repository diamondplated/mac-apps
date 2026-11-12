#!/bin/sh
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
STAGE=$(mktemp -d "$PROJECT_DIR/dist/.mixbar-build.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT INT TERM
for architecture in arm64 x86_64; do
    swift build --package-path "$PROJECT_DIR" --scratch-path "$STAGE/$architecture" --configuration release --triple "$architecture-apple-macosx14.0"
    bin=$(swift build --package-path "$PROJECT_DIR" --scratch-path "$STAGE/$architecture" --configuration release --triple "$architecture-apple-macosx14.0" --show-bin-path)
    cp "$bin/MixBar" "$STAGE/MixBar-$architecture"
done
APP="$STAGE/MixBar.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$STAGE/MixBar-arm64" "$STAGE/MixBar-x86_64" -output "$APP/Contents/MacOS/MixBar"
cp "$PROJECT_DIR/Info.plist" "$APP/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/MixBar.icns" "$APP/Contents/Resources/MixBar.icns"
chmod 755 "$APP/Contents/MacOS/MixBar"
plutil -lint "$APP/Contents/Info.plist"
ENTITLEMENTS="$PROJECT_DIR/MixBar.entitlements"
plutil -lint "$ENTITLEMENTS"
if [ "$SIGNING_IDENTITY" = - ]; then
    codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign - --timestamp=none "$APP"
else
    codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGNING_IDENTITY" "$TIMESTAMP_OPTION" "$APP"
fi
codesign --verify --strict "$APP"
lipo "$APP/Contents/MacOS/MixBar" -verify_arch arm64
lipo "$APP/Contents/MacOS/MixBar" -verify_arch x86_64
"$APP/Contents/MacOS/MixBar" --self-check
rm -rf "$PROJECT_DIR/dist/MixBar.app"
mv "$APP" "$PROJECT_DIR/dist/MixBar.app"
echo "Built $PROJECT_DIR/dist/MixBar.app"
