#!/bin/bash
# Build only the Quick Look provider. No registration or app launch occurs.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $# -eq 3 ]] || { echo "Usage: $0 output.appex derived-data architectures" >&2; exit 64; }
OUTPUT=$1
DERIVED=$2
ARCHITECTURES=$3
CHECKOUT="$(cd "$ROOT/.." && pwd)"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/AppBundle/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/Resources/AppBundle/Info.plist")
# Xcode prints its command environment, including PATH, in public build logs.
# Its selected developer tools resolve through the system shims; keep user
# executable directories out of this child process without changing HOME.
PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/xcodebuild -project "$ROOT/QuickLookExtension/LatentPreview.xcodeproj" \
    -scheme LatentPreview -configuration Release -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO "ARCHS=$ARCHITECTURES" ONLY_ACTIVE_ARCH=NO \
    "MARKETING_VERSION=$VERSION" "CURRENT_PROJECT_VERSION=$BUILD" \
    "OTHER_SWIFT_FLAGS=-file-prefix-map $CHECKOUT=." build
mkdir -p "$(dirname "$OUTPUT")"
rm -rf "$OUTPUT"
ditto "$DERIVED/Build/Products/Release/LatentPreview.appex" "$OUTPUT"
strip -S "$OUTPUT/Contents/MacOS/LatentPreview"
if strings "$OUTPUT/Contents/MacOS/LatentPreview" | grep -qF "$CHECKOUT"; then
    echo "error: Quick Look extension contains the build checkout path" >&2
    exit 1
fi
plutil -lint "$OUTPUT/Contents/Info.plist" >/dev/null

PLIST="$OUTPUT/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$PLIST")" == com.apple.quicklook.preview ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPrincipalClass' "$PLIST")" == LatentPreview.PreviewProvider ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")" == com.diamondplated.latent.preview ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")" == "$BUILD" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")" == "$VERSION" ]]
