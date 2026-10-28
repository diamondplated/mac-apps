#!/bin/bash
set -euo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
DIST_DIR=${MACTOOLS_DIST_DIR:-"$PROJECT_DIR/dist"}
DOCKPEEK_APP=${MACTOOLS_DOCKPEEK_APP:-"$PROJECT_DIR/DockPeek/DockPeek.app"}
SCREENWREN_APP=${MACTOOLS_SCREENWREN_APP:-"$PROJECT_DIR/ScreenWren/dist/ScreenWren.app"}
SCROLLSPLIT_APP=${MACTOOLS_SCROLLSPLIT_APP:-"$PROJECT_DIR/ScrollSplit/dist/ScrollSplit.app"}
LINKROUTES_APP=${MACTOOLS_LINKROUTES_APP:-"$PROJECT_DIR/LinkRoutes/dist/LinkRoutes.app"}
LATENT_APP=${MACTOOLS_LATENT_APP:-"$PROJECT_DIR/Latent/dist/Latent.app"}
SIFT_APP=${MACTOOLS_SIFT_APP:-"$PROJECT_DIR/Sift/dist/Sift.app"}
APP_PATH="$DIST_DIR/Mac Tools.app"
PAYLOAD_NAMES=(DockPeek ScreenWren ScrollSplit LinkRoutes Latent Sift)
select_payload() {
    case "$1" in
        DockPeek) source_app="$DOCKPEEK_APP"; identifier=com.andrew.dockpeek; minimum=14.0 ;;
        ScreenWren) source_app="$SCREENWREN_APP"; identifier=io.github.diamondplated.ScreenWren; minimum=26.0 ;;
        ScrollSplit) source_app="$SCROLLSPLIT_APP"; identifier=com.andrew.scrollsplit; minimum=14.0 ;;
        LinkRoutes) source_app="$LINKROUTES_APP"; identifier=com.andrew.linkroutes; minimum=14.0 ;;
        Latent) source_app="$LATENT_APP"; identifier=com.diamondplated.latent; minimum=14.0 ;;
        Sift) source_app="$SIFT_APP"; identifier=io.github.diamondplated.sift; minimum=14.0 ;;
        *) echo "Unknown managed app: $1" >&2; exit 1 ;;
    esac
}
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
    "$PROJECT_DIR/ScrollSplit/build-app.sh"
    "$PROJECT_DIR/LinkRoutes/build-app.sh"
    "$PROJECT_DIR/Latent/scripts/build_app.sh" --mac-tools-payload
    "$PROJECT_DIR/Sift/scripts/fetch-duckdb.sh"
    "$PROJECT_DIR/Sift/build-app.sh" --mac-tools-payload
fi
# Validate reused payloads before doing any compilation or signing.
for name in "${PAYLOAD_NAMES[@]}"; do
    select_payload "$name"
    codesign --verify --deep --strict "$source_app"
    test "$(plutil -extract CFBundleIdentifier raw "$source_app/Contents/Info.plist")" = "$identifier"
    test "$(plutil -extract CFBundleExecutable raw "$source_app/Contents/Info.plist")" = "$name"
    test "$(plutil -extract CFBundlePackageType raw "$source_app/Contents/Info.plist")" = APPL
    test -n "$(plutil -extract CFBundleShortVersionString raw "$source_app/Contents/Info.plist")"
    test -n "$(plutil -extract CFBundleVersion raw "$source_app/Contents/Info.plist")"
    test "$(codesign -dv --verbose=4 "$source_app" 2>&1 | sed -n 's/^Identifier=//p')" = "$identifier"
    test "$(plutil -extract LSMinimumSystemVersion raw "$source_app/Contents/Info.plist")" = "$minimum"
    for architecture in arm64 x86_64; do
        lipo "$source_app/Contents/MacOS/$name" -verify_arch "$architecture"
        binary_minimum=$(xcrun vtool -arch "$architecture" -show-build "$source_app/Contents/MacOS/$name" | awk '$1 == "minos" { print $2 }')
        test "$binary_minimum" = "$minimum"
    done
done
HELPER="$SCREENWREN_APP/Contents/Library/LoginItems/ScreenWrenLoginItem.app"
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
# SwiftPM also adds build-directory paths; installed copies must load their own framework.
python3 - "$STAGING_APP/Contents/MacOS/MacTools" <<'PYTHON'
import re, subprocess, sys
binary=sys.argv[1]
load_commands=subprocess.check_output(['otool','-l',binary], text=True)
paths=re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset', load_commands)
for path in sorted(set(paths)):
    if path.startswith('/') and ('.build/' in path or 'PackageFrameworks' in path):
        subprocess.run(['install_name_tool','-delete_rpath',path,binary], check=True)
PYTHON
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

for name in "${PAYLOAD_NAMES[@]}"; do
    select_payload "$name"
    codesign --verify --deep --strict "$source_app"
    test "$(plutil -extract CFBundleIdentifier raw "$source_app/Contents/Info.plist")" = "$identifier"
    test "$(plutil -extract LSMinimumSystemVersion raw "$source_app/Contents/Info.plist")" = "$minimum"
    test -n "$(plutil -extract CFBundleShortVersionString raw "$source_app/Contents/Info.plist")"
    ditto "$source_app" "$STAGING_APP/Contents/Resources/Applications/$name.app"
done

# Preserve the complete upstream framework, including symlinks and nested updater code.
SPARKLE_SOURCE=${SPARKLE_FRAMEWORK_PATH:-"$PROJECT_DIR/.build/package-arm64/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"}
test -d "$SPARKLE_SOURCE" || { echo "Sparkle.framework not found: $SPARKLE_SOURCE" >&2; exit 1; }
mkdir -p "$STAGING_APP/Contents/Frameworks"
SPARKLE="$STAGING_APP/Contents/Frameworks/Sparkle.framework"
ditto "$SPARKLE_SOURCE" "$SPARKLE"
for architecture in arm64 x86_64; do lipo "$SPARKLE/Sparkle" -verify_arch "$architecture"; done
otool -L "$STAGING_APP/Contents/MacOS/MacTools" | grep -F '@rpath/Sparkle.framework/' >/dev/null
otool -l "$STAGING_APP/Contents/MacOS/MacTools" | grep -F '@executable_path/../Frameworks' >/dev/null
sign_component() {
    if [ "$SIGNING_IDENTITY" = - ]; then
        codesign --force --options runtime --sign - --timestamp=none "$@"
    else
        codesign --force --options runtime --sign "$SIGNING_IDENTITY" "$TIMESTAMP_OPTION" "$@"
    fi
}
# Sparkle's documented custom-signing order; never recursively re-sign the tool payloads.
sign_component "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
sign_component --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
sign_component "$SPARKLE/Versions/B/Autoupdate"
sign_component "$SPARKLE/Versions/B/Updater.app"
sign_component "$SPARKLE"
codesign --verify --deep --strict "$SPARKLE"
# Self-signed and ad-hoc identities have no Apple Team ID. Allow this bundled
# framework in local builds; Developer ID distributions retain library validation.
MANAGER_ENTITLEMENTS=()
TEAM_ID=$(codesign -dv --verbose=4 "$SPARKLE" 2>&1 | sed -n 's/^TeamIdentifier=//p')
if [ -z "$TEAM_ID" ] || [ "$TEAM_ID" = not\ set ]; then
    cat > "$STAGING_DIR/local.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.cs.disable-library-validation</key><true/></dict></plist>
PLIST
    MANAGER_ENTITLEMENTS=(--entitlements "$STAGING_DIR/local.entitlements")
fi
# Sign only the manager. --deep here would replace the embedded apps' identities.
if [ "$SIGNING_IDENTITY" = - ]; then
    echo "Building an ad-hoc package for verification; installation requires a persistent signing identity." >&2
    codesign --force --options runtime --sign - --timestamp=none ${MANAGER_ENTITLEMENTS[@]+"${MANAGER_ENTITLEMENTS[@]}"} "$STAGING_APP"
else
    codesign --force --options runtime --sign "$SIGNING_IDENTITY" "$TIMESTAMP_OPTION" ${MANAGER_ENTITLEMENTS[@]+"${MANAGER_ENTITLEMENTS[@]}"} "$STAGING_APP"
fi
codesign --verify --deep --strict "$STAGING_APP"
for name in "${PAYLOAD_NAMES[@]}"; do
    embedded="$STAGING_APP/Contents/Resources/Applications/$name.app"
    codesign --verify --deep --strict "$embedded"
done
# Confirm packaging and enclosing-signature creation did not alter any payload bytes.
for name in "${PAYLOAD_NAMES[@]}"; do
    select_payload "$name"
    python3 "$PROJECT_DIR/scripts/compare-bundles.py" "$source_app" "$STAGING_APP/Contents/Resources/Applications/$name.app"
done

ARCHIVE_NAME="Mac-Tools-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$STAGING_APP" "$STAGING_DIR/$ARCHIVE_NAME"
unzip -tq "$STAGING_DIR/$ARCHIVE_NAME"
rm -rf "$APP_PATH"
mv "$STAGING_APP" "$APP_PATH"
mv -f "$STAGING_DIR/$ARCHIVE_NAME" "$DIST_DIR/$ARCHIVE_NAME"
echo "$APP_PATH"
echo "$DIST_DIR/$ARCHIVE_NAME"
