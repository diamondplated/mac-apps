#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
SOURCE_APP="$PROJECT_DIR/dist/ScreenWren.app"
INSTALLED_APP=/Applications/ScreenWren.app
BUILD=1
REPAIR_LOGIN_ITEM=0
for argument in "$@"; do
    case "$argument" in
        --no-build) BUILD=0 ;;
        --repair-login-item) REPAIR_LOGIN_ITEM=1 ;;
        *) echo "Usage: $0 [--no-build] [--repair-login-item]" >&2; exit 64 ;;
    esac
done

if [ "$BUILD" = 1 ]; then "$PROJECT_DIR/build-app.sh"; fi
codesign --verify --deep --strict "$SOURCE_APP"
if codesign -dv "$SOURCE_APP" 2>&1 | grep -q '^Signature=adhoc$'; then
    echo "Installation requires a persistent signing certificate. Configure the local signing identity first." >&2
    exit 1
fi
"$SOURCE_APP/Contents/MacOS/ScreenWren" --self-check

# A bundle swap can invalidate ServiceManagement registration even when all
# preferences survive. Read the installed app's own state before moving it.
PRESERVE_LOGIN_ITEM=0
if [ -e "$INSTALLED_APP" ] || [ -L "$INSTALLED_APP" ]; then
    [ ! -L "$INSTALLED_APP" ] || { echo "Refusing to replace a symbolic link: $INSTALLED_APP" >&2; exit 1; }
    test "$(plutil -extract CFBundleIdentifier raw "$INSTALLED_APP/Contents/Info.plist")" = io.github.diamondplated.ScreenWren
    test "$(plutil -extract CFBundleExecutable raw "$INSTALLED_APP/Contents/Info.plist")" = ScreenWren
    codesign --verify --deep --strict "$INSTALLED_APP"
    if [ "$(plutil -extract MacToolsSettingsProtocolVersion raw "$INSTALLED_APP/Contents/Info.plist" 2>/dev/null || true)" = 1 ]; then
        LOGIN_SNAPSHOT=$("$INSTALLED_APP/Contents/MacOS/ScreenWren" --mac-tools-settings read)
        test "$(printf '%s' "$LOGIN_SNAPSHOT" | plutil -extract app raw -o - -)" = screenWren
        test "$(printf '%s' "$LOGIN_SNAPSHOT" | plutil -extract schemaVersion raw -o - -)" = 1
        case "$(printf '%s' "$LOGIN_SNAPSHOT" | plutil -extract launchAtLogin raw -expect bool -o - -)" in
            true) PRESERVE_LOGIN_ITEM=1 ;;
            false) ;;
            *) echo "ScreenWren did not report a valid launch at login state; installation stopped." >&2; exit 1 ;;
        esac
    fi
fi

restore_login_item() {
    LOGIN_SNAPSHOT=$(printf '%s' '{"launchAtLogin":true}' | "$INSTALLED_APP/Contents/MacOS/ScreenWren" --mac-tools-settings write) || return 1
    if [ "$(printf '%s' "$LOGIN_SNAPSHOT" | plutil -extract launchAtLogin raw -expect bool -o - -)" != true ]; then
        echo "Launch at login needs attention. Enable it in ScreenWren settings and approve it in System Settings if requested." >&2
        return 1
    fi
}

STAGING_DIR=$(mktemp -d /Applications/.screenwren-install.XXXXXX)
INSTALL_COMMITTED=0
APP_PLACED=0
cleanup() {
    status=$?
    restored_previous=0
    trap - EXIT
    if [ "$INSTALL_COMMITTED" = 0 ]; then
        if [ "$APP_PLACED" = 1 ] && [ -d "$INSTALLED_APP" ]; then
            if ! mv "$INSTALLED_APP" "$STAGING_DIR/failed.app"; then
                echo "Could not restore the previous app; recovery files remain at $STAGING_DIR." >&2
                exit 1
            fi
        fi
        if [ -d "$STAGING_DIR/previous.app" ]; then
            if ! mv "$STAGING_DIR/previous.app" "$INSTALLED_APP"; then
                echo "Could not restore the previous app; recovery files remain at $STAGING_DIR." >&2
                exit 1
            fi
            restored_previous=1
        fi
    fi
    rm -rf "$STAGING_DIR"
    if [ "$restored_previous" = 1 ] && [ "$PRESERVE_LOGIN_ITEM" = 1 ]; then
        restore_login_item || { echo "The previous app was restored, but launch at login could not be restored." >&2; status=1; }
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
ditto "$SOURCE_APP" "$STAGING_DIR/ScreenWren.app"
codesign --verify --deep --strict "$STAGING_DIR/ScreenWren.app"

# Stop old copies before swapping the bundle; wait for exit without a SIGKILL fallback.
RUNNING_PIDS=$(pgrep -x ScreenWren || true)
if [ -n "$RUNNING_PIDS" ]; then
    kill -TERM $RUNNING_PIDS 2>/dev/null || true
    attempts=0
    while pgrep -x ScreenWren >/dev/null; do
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 100 ]; then
            echo "ScreenWren did not quit; installation was left unchanged." >&2
            exit 1
        fi
        sleep 0.1
    done
fi

if [ -d "$INSTALLED_APP" ]; then
    BACKUP="$PROJECT_DIR/dist/ScreenWren-installed-backup-$(date +%Y%m%d-%H%M%S).zip"
    ditto -c -k --sequesterRsrc --keepParent "$INSTALLED_APP" "$BACKUP"
    mv "$INSTALLED_APP" "$STAGING_DIR/previous.app"
fi
mv "$STAGING_DIR/ScreenWren.app" "$INSTALLED_APP"
APP_PLACED=1
codesign --verify --deep --strict "$INSTALLED_APP"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for build_copy in "$PROJECT_DIR"/dist/*.app; do
    [ -d "$build_copy" ] || continue
    build_identifier=$(plutil -extract CFBundleIdentifier raw "$build_copy/Contents/Info.plist" 2>/dev/null || true)
    [ "$build_identifier" = io.github.diamondplated.ScreenWren ] || continue
    "$LSREGISTER" -u "$build_copy"
    if [ -d "$build_copy/Contents/Library/LoginItems/ScreenWrenLoginItem.app" ]; then
        "$LSREGISTER" -u "$build_copy/Contents/Library/LoginItems/ScreenWrenLoginItem.app"
    fi
done
"$LSREGISTER" -f "$INSTALLED_APP"
# The verified installation is committed. Keep it if optional OS registration
# needs user approval, so the repair can be retried from the canonical copy.
INSTALL_COMMITTED=1
# Remove the displaced registered bundle before restoring the canonical copy's
# registration, so later backup cleanup cannot invalidate the restored item.
if [ -d "$STAGING_DIR/previous.app" ]; then rm -rf "$STAGING_DIR/previous.app"; fi
if [ "$REPAIR_LOGIN_ITEM" = 1 ]; then
    "$INSTALLED_APP/Contents/MacOS/ScreenWren" --repair-login-item
elif [ "$PRESERVE_LOGIN_ITEM" = 1 ]; then
    restore_login_item
fi
open "$INSTALLED_APP"
echo "Installed and reopened $INSTALLED_APP"
