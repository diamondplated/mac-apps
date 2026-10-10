#!/bin/bash
set -euo pipefail

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "$DIR"

INSTALL=1
ARCHITECTURE=native
while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-install) INSTALL=0; shift ;;
        --arch)
            [ "$#" -ge 2 ] || { echo "--arch requires native, universal, arm64 or x86_64" >&2; exit 64; }
            ARCHITECTURE=$2; shift 2 ;;
        *) echo "Usage: $0 [--no-install] [--arch native|universal|arm64|x86_64]" >&2; exit 64 ;;
    esac
done
case "$ARCHITECTURE" in
    native) ARCHITECTURES="$(uname -m)" ;;
    universal) ARCHITECTURES="arm64 x86_64" ;;
    arm64|x86_64) ARCHITECTURES=$ARCHITECTURE ;;
    *) echo "Unsupported architecture: $ARCHITECTURE" >&2; exit 64 ;;
esac

APP_NAME="DockPeek"
APP_DIR="$DIR/$APP_NAME.app"
mkdir -p "$DIR/.build"
STAGING_DIR=$(mktemp -d "$DIR/.build/dockpeek-package.XXXXXX")
trap 'rm -rf "$STAGING_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
CONTENTS_DIR="$STAGING_DIR/$APP_NAME.app/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
BINARIES=()
for architecture in $ARCHITECTURES; do
    echo "==> Building DockPeek ($architecture, Release mode)..."
    scratch="$DIR/.build/package-$architecture"
    triple="$architecture-apple-macosx14.0"
    swift build --package-path "$DIR" --scratch-path "$scratch" -c release --triple "$triple"
    binary_dir=$(swift build --package-path "$DIR" --scratch-path "$scratch" -c release --triple "$triple" --show-bin-path)
    BINARIES+=("$binary_dir/$APP_NAME")
done
if [ "${#BINARIES[@]}" -eq 1 ]; then
    cp "${BINARIES[0]}" "$MACOS_DIR/$APP_NAME"
else
    lipo -create "${BINARIES[@]}" -output "$MACOS_DIR/$APP_NAME"
fi
chmod 755 "$MACOS_DIR/$APP_NAME"
for architecture in $ARCHITECTURES; do
    lipo "$MACOS_DIR/$APP_NAME" -verify_arch "$architecture"
done

# Create Info.plist
cat << PLIST > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.andrew.dockpeek</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1.1</string>
    <key>MacToolsSettingsProtocolVersion</key>
    <integer>1</integer>
    <key>CFBundleVersion</key>
    <string>3</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>DockPeek needs Screen Recording access to display live window thumbnail previews.</string>
</dict>
</plist>
PLIST

plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null
test "$(plutil -extract LSMinimumSystemVersion raw "$CONTENTS_DIR/Info.plist")" = 14.0

echo "==> Code signing with stable designated requirement..."
# Preserve the existing designated requirement so TCC recognizes rebuilds.
codesign --force -s - -r='designated => identifier "com.andrew.dockpeek"' "$STAGING_DIR/$APP_NAME.app"
codesign --verify --deep --strict "$STAGING_DIR/$APP_NAME.app"
rm -rf "$APP_DIR"
mv "$STAGING_DIR/$APP_NAME.app" "$APP_DIR"

if [ "$INSTALL" = 1 ]; then
    echo "==> Installing to /Applications/DockPeek.app..."
    rm -rf "/Applications/$APP_NAME.app"
    ditto "$APP_DIR" "/Applications/$APP_NAME.app"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/$APP_NAME.app"
    echo "Installed to: /Applications/$APP_NAME.app"
else
    echo "Packaged: $APP_DIR"
fi
