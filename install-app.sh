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

# LaunchServices changes to a manager build may affect its embedded app identities.
# Preserve the enabled registrations of actual installed tools, never payloads.
LOGIN_APPS=()
snapshot_tool_login() {
    local app identifier executable app_key snapshot enabled
    for app in /Applications/*.app "$HOME"/Applications/*.app; do
        [ -d "$app" ] && [ ! -L "$app" ] || continue
        identifier=$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist" 2>/dev/null || true)
        case "$identifier" in
            com.andrew.dockpeek) executable=DockPeek; app_key=dockPeek ;;
            io.github.diamondplated.ScreenWren) executable=ScreenWren; app_key=screenWren ;;
            com.andrew.scrollsplit) executable=ScrollSplit; app_key=scrollSplit ;;
            com.andrew.linkroutes) executable=LinkRoutes; app_key=linkRoutes ;;
            *) continue ;;
        esac
        [ "$(plutil -extract MacToolsSettingsProtocolVersion raw "$app/Contents/Info.plist" 2>/dev/null || true)" = 1 ] || continue
        test "$(plutil -extract CFBundleExecutable raw "$app/Contents/Info.plist")" = "$executable"
        codesign --verify --deep --strict "$app"
        snapshot=$("$app/Contents/MacOS/$executable" --mac-tools-settings read)
        test "$(printf '%s' "$snapshot" | plutil -extract schemaVersion raw -o - -)" = 1
        test "$(printf '%s' "$snapshot" | plutil -extract app raw -o - -)" = "$app_key"
        enabled=$(printf '%s' "$snapshot" | plutil -extract launchAtLogin raw -expect bool -o - -)
        case "$enabled" in
            true) LOGIN_APPS+=("$app/Contents/MacOS/$executable") ;;
            false) ;;
            *) echo "$executable did not report a valid launch at login state; installation stopped." >&2; return 1 ;;
        esac
    done
}
restore_tool_login() {
    local executable snapshot failed=0
    for executable in ${LOGIN_APPS[@]+"${LOGIN_APPS[@]}"}; do
        if ! snapshot=$(printf '%s' '{"launchAtLogin":true}' | "$executable" --mac-tools-settings write) ||
           [ "$(printf '%s' "$snapshot" | plutil -extract launchAtLogin raw -expect bool -o - -)" != true ]; then
            echo "Could not preserve launch at login for $executable. Enable it in Mac Tools settings and approve it in System Settings if requested." >&2
            failed=1
        fi
    done
    return "$failed"
}
snapshot_tool_login
REGISTRATION_MAY_CHANGE=0

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
    if [ "$REGISTRATION_MAY_CHANGE" = 1 ]; then
        restore_tool_login || status=1
    fi
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
REGISTRATION_MAY_CHANGE=1
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
REGISTRATION_MAY_CHANGE=1
"$LSREGISTER" -u "$SOURCE_APP" || true
"$LSREGISTER" -f "$INSTALLED_APP"
INSTALL_COMMITTED=1
# Finish removing displaced payload copies before re-registering installed tools.
if [ -d "$STAGING_DIR/previous.app" ]; then rm -rf "$STAGING_DIR/previous.app"; fi
REGISTRATION_MAY_CHANGE=0
restore_tool_login
open "$INSTALLED_APP"
echo "Installed and opened $INSTALLED_APP"
