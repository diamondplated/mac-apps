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

IDENTITY_FILE="$DIR/../ScreenWren/.screenwren-signing-identity"
if [ -n "${SCREENWREN_SIGNING_IDENTITY:-}" ]; then
    SIGNING_IDENTITY=$SCREENWREN_SIGNING_IDENTITY
elif [ -s "$IDENTITY_FILE" ]; then
    SIGNING_IDENTITY=$(cat "$IDENTITY_FILE")
else
    SIGNING_IDENTITY=-
fi
if [ -n "${SCREENWREN_SIGNING_TIMESTAMP:-}" ]; then
    SIGNING_TIMESTAMP=$SCREENWREN_SIGNING_TIMESTAMP
elif [ -z "${SCREENWREN_SIGNING_IDENTITY:-}" ] && [ -f "$DIR/../ScreenWren/.screenwren-signing-timestamp" ]; then
    SIGNING_TIMESTAMP=$(cat "$DIR/../ScreenWren/.screenwren-signing-timestamp")
else
    SIGNING_TIMESTAMP=secure
fi
case "$SIGNING_TIMESTAMP" in
    secure) TIMESTAMP_OPTION=--timestamp ;;
    none) TIMESTAMP_OPTION=--timestamp=none ;;
    *) echo "SCREENWREN_SIGNING_TIMESTAMP must be secure or none." >&2; exit 64 ;;
esac
if [ "$INSTALL" = 1 ] && [ "$SIGNING_IDENTITY" = - ]; then
    echo "Installing requires the saved local signing identity; an ad-hoc DockPeek loses its permissions on every rebuild." >&2
    exit 1
fi

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
    <string>1.1.2</string>
    <key>MacToolsSettingsProtocolVersion</key>
    <integer>1</integer>
    <key>CFBundleVersion</key>
    <string>4</string>
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

# Sign with the persistent local identity so TCC grants survive rebuilds through its
# certificate-anchored requirement. An identifier-only requirement would let any
# ad-hoc app claiming com.andrew.dockpeek inherit Accessibility and Screen Recording.
if [ "$SIGNING_IDENTITY" = - ]; then
    echo "==> Code signing ad-hoc (verification only; installs need a persistent identity)..."
    codesign --force --options runtime --sign - --timestamp=none "$STAGING_DIR/$APP_NAME.app"
else
    echo "==> Code signing with the persistent local identity..."
    codesign --force --options runtime --sign "$SIGNING_IDENTITY" "$TIMESTAMP_OPTION" "$STAGING_DIR/$APP_NAME.app"
fi
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
