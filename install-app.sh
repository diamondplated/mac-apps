#!/bin/bash
set -euo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
SOURCE_APP="$PROJECT_DIR/dist/Mac Tools.app"
INSTALLED_APP="/Applications/Mac Tools.app"
case "${1:-}" in
    '') [ "$#" -eq 0 ] || exit 64; "$PROJECT_DIR/build-app.sh" ;;
    --no-build) [ "$#" -eq 1 ] || { echo "Usage: $0 [--no-build]" >&2; exit 64; } ;;
    *) echo "Usage: $0 [--no-build]" >&2; exit 64 ;;
esac
validate_app() {
    local app=$1
    test "$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")" = com.andrew.mactools
    test "$(plutil -extract CFBundleExecutable raw "$app/Contents/Info.plist")" = MacTools
    test -x "$app/Contents/MacOS/MacTools"
    codesign --verify --deep --strict "$app"
    if codesign -dv "$app" 2>&1 | grep -q '^Signature=adhoc$'; then
        echo "Installation requires a persistent signing certificate; configure ScreenWren's signing identity and rebuild." >&2
        return 1
    fi
}
validate_app "$SOURCE_APP"
if [ -e "$INSTALLED_APP" ] || [ -L "$INSTALLED_APP" ]; then
    [ ! -L "$INSTALLED_APP" ] || { echo "Refusing to replace a symbolic link: $INSTALLED_APP" >&2; exit 1; }
    test "$(plutil -extract CFBundleIdentifier raw "$INSTALLED_APP/Contents/Info.plist")" = com.andrew.mactools
fi

STAGING_DIR=$(mktemp -d /Applications/.mactools-install.XXXXXX)
INSTALL_COMMITTED=0
APP_PLACED=0
cleanup() {
    status=$?
    trap - EXIT
    if [ "$INSTALL_COMMITTED" = 0 ]; then
        if [ "$APP_PLACED" = 1 ]; then
            mv "$INSTALLED_APP" "$STAGING_DIR/failed.app" || {
                echo "Recovery files remain at $STAGING_DIR." >&2; exit 1;
            }
        fi
        if [ -d "$STAGING_DIR/previous.app" ]; then
            mv "$STAGING_DIR/previous.app" "$INSTALLED_APP" || {
                echo "Recovery files remain at $STAGING_DIR." >&2; exit 1;
            }
        fi
    fi
    rm -rf "$STAGING_DIR"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
ditto "$SOURCE_APP" "$STAGING_DIR/Mac Tools.app"
validate_app "$STAGING_DIR/Mac Tools.app"

# Quit the existing manager before replacing its executable. Never force kill it.
RUNNING_PIDS=$(pgrep -x MacTools || true)
if [ -n "$RUNNING_PIDS" ]; then
    kill -TERM $RUNNING_PIDS 2>/dev/null || true
    attempts=0
    while pgrep -x MacTools >/dev/null; do
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 100 ]; then
            echo "Mac Tools did not quit; installation was left unchanged." >&2
            exit 1
        fi
        sleep 0.1
    done
fi
if [ -d "$INSTALLED_APP" ]; then
    mkdir -p "$PROJECT_DIR/dist"
    ditto -c -k --sequesterRsrc --keepParent "$INSTALLED_APP" \
        "$PROJECT_DIR/dist/Mac-Tools-installed-backup-$(date +%Y%m%d-%H%M%S).zip"
    mv "$INSTALLED_APP" "$STAGING_DIR/previous.app"
fi
mv "$STAGING_DIR/Mac Tools.app" "$INSTALLED_APP"
APP_PLACED=1
validate_app "$INSTALLED_APP"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$SOURCE_APP" || true
"$LSREGISTER" -f "$INSTALLED_APP"
INSTALL_COMMITTED=1
open "$INSTALLED_APP"
echo "Installed and opened $INSTALLED_APP"
