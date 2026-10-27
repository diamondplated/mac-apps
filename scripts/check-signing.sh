#!/bin/bash
# Fails when a bundle's designated requirement would let other code inherit its
# TCC grants (an identifier-only requirement), or when hardened runtime is off.
# --certificate also refuses ad-hoc (cdhash) requirements, for releases.
set -euo pipefail
usage() { echo "Usage: $0 [--certificate] BUNDLE... | --self-test" >&2; exit 64; }
check() {
    local certificate=$1 bundle=$2 requirement flags
    requirement=$(codesign --display --requirements - "$bundle" 2>/dev/null | sed -n 's/^designated => //p')
    flags=$(codesign --display --verbose=2 "$bundle" 2>&1 | sed -n 's/^CodeDirectory .*flags=\([^ ]*\).*/\1/p')
    case "$flags" in
        *runtime*) ;;
        *) echo "$bundle: hardened runtime is not enabled (flags=${flags:-none})." >&2; return 1 ;;
    esac
    case "$requirement" in
        *'anchor '*|*'certificate '*) return 0 ;;
        cdhash\ *) [ "$certificate" = 0 ] && return 0
            echo "$bundle: ad-hoc signature; releases need the persistent signing identity." >&2; return 1 ;;
    esac
    echo "$bundle: designated requirement is not bound to a certificate or code hash: ${requirement:-missing}" >&2
    return 1
}
self_test() {
    local scratch app
    scratch=$(mktemp -d "${TMPDIR:-/tmp}/check-signing.XXXXXX")
    trap 'rm -rf "$scratch"' RETURN
    app="$scratch/Probe.app"
    mkdir -p "$app/Contents/MacOS"
    cp /usr/bin/true "$app/Contents/MacOS/Probe"
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
        '<plist version="1.0"><dict><key>CFBundleExecutable</key><string>Probe</string><key>CFBundleIdentifier</key><string>com.example.probe</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>' \
        > "$app/Contents/Info.plist"
    codesign --force --options runtime --sign - --timestamp=none -r='designated => identifier "com.example.probe"' "$app" 2>/dev/null
    if check 0 "$app" 2>/dev/null; then echo "self-test: identifier-only requirement was accepted" >&2; return 1; fi
    codesign --force --sign - --timestamp=none "$app" 2>/dev/null
    if check 0 "$app" 2>/dev/null; then echo "self-test: missing hardened runtime was accepted" >&2; return 1; fi
    codesign --force --options runtime --sign - --timestamp=none "$app" 2>/dev/null
    check 0 "$app" || { echo "self-test: ad-hoc code-hash requirement was rejected" >&2; return 1; }
    if check 1 "$app" 2>/dev/null; then echo "self-test: ad-hoc signature passed the release check" >&2; return 1; fi
    echo "check-signing self-test passed."
}
[ "$#" -gt 0 ] || usage
if [ "$1" = --self-test ]; then [ "$#" -eq 1 ] || usage; self_test; exit; fi
CERTIFICATE=0
if [ "$1" = --certificate ]; then CERTIFICATE=1; shift; [ "$#" -gt 0 ] || usage; fi
for bundle in "$@"; do check "$CERTIFICATE" "$bundle"; done
