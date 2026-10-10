#!/bin/sh
set -eu
PROJECT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
IDENTITY_FILE="$PROJECT_DIR/../ScreenWren/.screenwren-signing-identity"
SIGNING_IDENTITY=${LINKROUTES_SIGNING_IDENTITY:-${MACTOOLS_SIGNING_IDENTITY:-${SCREENWREN_SIGNING_IDENTITY:-}}}
IDENTITY_FROM_ENV=$SIGNING_IDENTITY
if [ -z "$SIGNING_IDENTITY" ] && [ -f "$IDENTITY_FILE" ]; then SIGNING_IDENTITY=$(cat "$IDENTITY_FILE"); fi
SIGNING_IDENTITY=${SIGNING_IDENTITY:--}
TIMESTAMP=${LINKROUTES_SIGNING_TIMESTAMP:-${MACTOOLS_SIGNING_TIMESTAMP:-${SCREENWREN_SIGNING_TIMESTAMP:-}}}
if [ -z "$TIMESTAMP" ] && [ -z "$IDENTITY_FROM_ENV" ] && [ -f "$PROJECT_DIR/../ScreenWren/.screenwren-signing-timestamp" ]; then TIMESTAMP=$(cat "$PROJECT_DIR/../ScreenWren/.screenwren-signing-timestamp"); fi
case "${TIMESTAMP:-secure}" in secure) TIMESTAMP_OPTION=--timestamp ;; none) TIMESTAMP_OPTION=--timestamp=none ;; *) echo 'Signing timestamp must be secure or none.' >&2; exit 64 ;; esac
mkdir -p "$PROJECT_DIR/dist"
STAGE=$(mktemp -d "$PROJECT_DIR/dist/.linkroutes-build.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT INT TERM
for ARCH in arm64 x86_64; do
    swift build --package-path "$PROJECT_DIR" --scratch-path "$PROJECT_DIR/.build/release-$ARCH" --configuration release --triple "$ARCH-apple-macosx14.0"
    BIN=$(swift build --package-path "$PROJECT_DIR" --scratch-path "$PROJECT_DIR/.build/release-$ARCH" --configuration release --triple "$ARCH-apple-macosx14.0" --show-bin-path)
    cp "$BIN/LinkRoutes" "$STAGE/LinkRoutes-$ARCH"
done
APP="$STAGE/LinkRoutes.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$STAGE/LinkRoutes-arm64" "$STAGE/LinkRoutes-x86_64" -output "$APP/Contents/MacOS/LinkRoutes"
cp "$PROJECT_DIR/Info.plist" "$APP/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/LinkRoutes.icns" "$APP/Contents/Resources/LinkRoutes.icns"
if [ "$SIGNING_IDENTITY" = - ]; then
    codesign --force --sign - --identifier com.andrew.linkroutes --requirements '=designated => identifier "com.andrew.linkroutes"' "$APP"
else
    codesign --force --sign "$SIGNING_IDENTITY" --options runtime "$TIMESTAMP_OPTION" "$APP"
fi
codesign --verify --strict "$APP"
"$APP/Contents/MacOS/LinkRoutes" --self-check
rm -rf "$PROJECT_DIR/dist/LinkRoutes.app"
mv "$APP" "$PROJECT_DIR/dist/LinkRoutes.app"
echo "Built $PROJECT_DIR/dist/LinkRoutes.app"
