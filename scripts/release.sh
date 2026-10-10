#!/bin/bash
set -euo pipefail
PROJECT_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd)
MODE=notarized
PUBLISH=0
PREFLIGHT_ONLY=0
REQUESTED_VERSION=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --local) MODE=local; shift ;;
        --notarized) MODE=notarized; shift ;;
        --publish) PUBLISH=1; shift ;;
        --preflight) PREFLIGHT_ONLY=1; shift ;;
        --version) [ "$#" -ge 2 ] || exit 64; REQUESTED_VERSION=$2; shift 2 ;;
        *) echo "Usage: $0 [--notarized|--local] [--version X.Y.Z] [--preflight] [--publish]" >&2; exit 64 ;;
    esac
done
fail() { echo "Release preflight failed: $*" >&2; exit 1; }
PLIST="$PROJECT_DIR/MacTools/Info.plist"
VERSION=$(plutil -extract CFBundleShortVersionString raw "$PLIST")
BUILD=$(plutil -extract CFBundleVersion raw "$PLIST")
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Version must be X.Y.Z."
[[ "$BUILD" =~ ^[1-9][0-9]*$ ]] || fail "CFBundleVersion must be a positive, increasing integer."
[ -z "$REQUESTED_VERSION" ] || [ "$REQUESTED_VERSION" = "$VERSION" ] || fail "Requested version does not match Info.plist ($VERSION)."

# Resolve credentials before building, submitting, tagging, or publishing anything.
if [ "$MODE" = notarized ]; then
    [ -n "${DEVELOPER_ID_APPLICATION_IDENTITY:-}" ] || fail "DEVELOPER_ID_APPLICATION_IDENTITY is required; no notarized fallback exists."
    [ -n "${NOTARYTOOL_PROFILE:-}" ] || fail "NOTARYTOOL_PROFILE is required (credentials stay in the native keychain)."
    SIGNING_IDENTITY=$DEVELOPER_ID_APPLICATION_IDENTITY
    IDENTITIES=$(security find-identity -v -p codesigning)
    printf '%s\n' "$IDENTITIES" | grep -F "$SIGNING_IDENTITY" | grep -F 'Developer ID Application:' >/dev/null || fail "A valid Developer ID Application certificate and private key were not found in this runner's keychain."
    xcrun notarytool history --keychain-profile "$NOTARYTOOL_PROFILE" --output-format json >/dev/null || fail "The notarytool keychain profile is missing, inaccessible, or invalid."
    SIGNING_TIMESTAMP=secure
else
    SIGNING_IDENTITY=${SCREENWREN_SIGNING_IDENTITY:-}
    if [ -z "$SIGNING_IDENTITY" ] && [ -f "$PROJECT_DIR/ScreenWren/.screenwren-signing-identity" ]; then
        SIGNING_IDENTITY=$(cat "$PROJECT_DIR/ScreenWren/.screenwren-signing-identity")
    fi
    [ -n "$SIGNING_IDENTITY" ] && [ "$SIGNING_IDENTITY" != - ] || fail "--local requires an existing persistent SCREENWREN_SIGNING_IDENTITY; ad-hoc releases are refused."
    SIGNING_TIMESTAMP=${SCREENWREN_SIGNING_TIMESTAMP:-none}
fi

FEED_URL=$(plutil -extract SUFeedURL raw "$PLIST")
FEED_REPOSITORY=$(printf '%s' "$FEED_URL" | sed -nE 's@^https://github.com/([^/]+/[^/]+)/releases/latest/download/appcast.xml$@\1@p')
[ -n "$FEED_REPOSITORY" ] || fail "SUFeedURL must use a public GitHub releases/latest/download/appcast.xml endpoint."
RELEASE_REPOSITORY=${MACTOOLS_RELEASE_REPOSITORY:-$FEED_REPOSITORY}
SOURCE_REPOSITORY=${MACTOOLS_SOURCE_REPOSITORY:-diamondplated/mac-tools}
[ "$RELEASE_REPOSITORY" = "$FEED_REPOSITORY" ] || fail "MACTOOLS_RELEASE_REPOSITORY does not match SUFeedURL."
[ "$(plutil -extract MacToolsReleasesURL raw "$PLIST")" = "https://github.com/$RELEASE_REPOSITORY/releases" ] || fail "MacToolsReleasesURL does not match the download repository."
[ "$(gh api "repos/$RELEASE_REPOSITORY" --jq '.private')" = false ] || fail "The download repository must be public so Sparkle can fetch releases without credentials."

SPARKLE_TOOLS_DIR=${SPARKLE_TOOLS_DIR:-}
if [ -z "$SPARKLE_TOOLS_DIR" ]; then
    for candidate in "$PROJECT_DIR/.build/sparkle-tools/bin" "$PROJECT_DIR/.build/package-arm64/artifacts/sparkle/Sparkle/bin" "$PROJECT_DIR/MacTools/.build/artifacts/sparkle/Sparkle/bin"; do
        if [ -x "$candidate/generate_appcast" ]; then SPARKLE_TOOLS_DIR=$candidate; break; fi
    done
fi
if [ -z "$SPARKLE_TOOLS_DIR" ]; then
    swift package --package-path "$PROJECT_DIR/MacTools" resolve
    SPARKLE_TOOLS_DIR="$PROJECT_DIR/MacTools/.build/artifacts/sparkle/Sparkle/bin"
fi
for tool in generate_appcast generate_keys sign_update; do
    [ -n "$SPARKLE_TOOLS_DIR" ] && [ -x "$SPARKLE_TOOLS_DIR/$tool" ] || fail "Set SPARKLE_TOOLS_DIR to the official Sparkle 2.10.0 bin directory."
done
SPARKLE_ACCOUNT=${SPARKLE_KEYCHAIN_ACCOUNT:-mac-tools}
PUBLIC_KEY=$("$SPARKLE_TOOLS_DIR/generate_keys" --account "$SPARKLE_ACCOUNT" -p) || fail "Existing Sparkle keychain key '$SPARKLE_ACCOUNT' is unavailable."
[ "$PUBLIC_KEY" = "$(plutil -extract SUPublicEDKey raw "$PLIST")" ] || fail "Sparkle keychain public key does not match the app's SUPublicEDKey."
[ "$(plutil -extract SURequireSignedFeed raw "$PLIST")" = true ] || fail "Signed feeds must be required."
[ "$(plutil -extract SUVerifyUpdateBeforeExtraction raw "$PLIST")" = true ] || fail "Archive verification before extraction must be required."


# Publishing additionally verifies every published build is older. Read tag data
# for releases predating appcasts, and fail closed if provenance cannot be read.
if [ "$PUBLISH" = 1 ]; then
    [ -z "$(git -C "$PROJECT_DIR" status --porcelain)" ] || fail "Commit the release source before publishing; the working tree must be clean."
    python3 - "$BUILD" "$VERSION" "$RELEASE_REPOSITORY" "$SOURCE_REPOSITORY" <<'PY'
import base64, json, plistlib, subprocess, sys, xml.etree.ElementTree as ET
build, version, repository, source_repository = int(sys.argv[1]), *sys.argv[2:]
def api(path):
    return json.loads(subprocess.check_output(['gh','api',path], text=True))
page = 1
while True:
    releases = api(f'repos/{repository}/releases?per_page=100&page={page}')
    if not releases: break
    for release in releases:
        if release['tag_name'] == 'v' + version:
            raise SystemExit('Release already exists; refusing to overwrite published assets.')
        if release['draft']: continue
        assets={a['name']:a['id'] for a in release['assets']}
        def asset(name):
            return subprocess.check_output(['gh','api',f'repos/{repository}/releases/assets/{assets[name]}','-H','Accept: application/octet-stream'])
        if 'release.json' in assets:
            previous_build=int(json.loads(asset('release.json'))['build'])
        elif 'appcast.xml' in assets:
            feed=ET.fromstring(asset('appcast.xml'))
            previous_build=max(int(v.text) for v in feed.findall('.//{http://www.andymatuschak.org/xml-namespaces/sparkle}version'))
        else:
            source = api(f'repos/{source_repository}/contents/MacTools/Info.plist?ref=' + release['tag_name'])
            previous_build=int(plistlib.loads(base64.b64decode(source['content']))['CFBundleVersion'])
        if previous_build >= build:
            raise SystemExit('CFBundleVersion must exceed every published release.')
    page += 1
PY
fi
if [ "$PREFLIGHT_ONLY" = 1 ]; then echo "Release preflight passed ($MODE, $VERSION, build $BUILD)."; exit 0; fi

RELEASE_ROOT="$PROJECT_DIR/dist/release"
mkdir -p "$RELEASE_ROOT" "$PROJECT_DIR/.build"
DESTINATION="$RELEASE_ROOT/v$VERSION-$MODE"
[ ! -e "$DESTINATION" ] || fail "Release output already exists: $DESTINATION (move it aside explicitly before rebuilding)."
WORK=$(mktemp -d "$RELEASE_ROOT/.release.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$WORK/payloads" "$WORK/output"
# Fresh builds live separately; preserve the normal local ScreenWren signatures.
"$PROJECT_DIR/DockPeek/build_app.sh" --no-install --arch universal
ditto "$PROJECT_DIR/DockPeek/DockPeek.app" "$WORK/payloads/DockPeek.app"
SCREEN_SOURCE="$WORK/ScreenWren"
mkdir -p "$SCREEN_SOURCE"
for path in Package.swift Sources Resources Info.plist LoginItem-Info.plist build-app.sh; do
    ditto "$PROJECT_DIR/ScreenWren/$path" "$SCREEN_SOURCE/$path"
done
if [ -f "$PROJECT_DIR/ScreenWren/Package.resolved" ]; then cp "$PROJECT_DIR/ScreenWren/Package.resolved" "$SCREEN_SOURCE/Package.resolved"; fi
SCREENWREN_SIGNING_IDENTITY="$SIGNING_IDENTITY" SCREENWREN_SIGNING_TIMESTAMP="$SIGNING_TIMESTAMP" "$SCREEN_SOURCE/build-app.sh"
ditto "$SCREEN_SOURCE/dist/ScreenWren.app" "$WORK/payloads/ScreenWren.app"

notarize_and_staple() {
    local app=$1 name=$2 archive="$WORK/notary-$2.zip" result="$WORK/notary-$2.json"
    ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
    xcrun notarytool submit "$archive" --keychain-profile "$NOTARYTOOL_PROFILE" --wait --output-format json > "$result"
    python3 - "$result" <<'PY'
import json, sys
result=json.load(open(sys.argv[1]))
if result.get('status') != 'Accepted':
    raise SystemExit('Notarization was not accepted: ' + result.get('status','unknown'))
PY
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    codesign --verify --deep --strict "$app"
    spctl --assess --type execute --verbose=2 "$app"
    cp "$result" "$WORK/output/notarization-$name.json"
}
if [ "$MODE" = notarized ]; then
    # Release-only DockPeek copy adopts Developer ID; its local TCC signature stays intact.
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$WORK/payloads/DockPeek.app"
    notarize_and_staple "$WORK/payloads/DockPeek.app" DockPeek
    notarize_and_staple "$WORK/payloads/ScreenWren.app" ScreenWren
fi
MACTOOLS_DIST_DIR="$WORK/output" MACTOOLS_DOCKPEEK_APP="$WORK/payloads/DockPeek.app" \
MACTOOLS_SCREENWREN_APP="$WORK/payloads/ScreenWren.app" \
SCREENWREN_SIGNING_IDENTITY="$SIGNING_IDENTITY" SCREENWREN_SIGNING_TIMESTAMP="$SIGNING_TIMESTAMP" \
    "$PROJECT_DIR/build-app.sh" --reuse-payloads
APP="$WORK/output/Mac Tools.app"
ARCHIVE="$WORK/output/Mac-Tools-$VERSION.zip"
if [ "$MODE" = notarized ]; then
    notarize_and_staple "$APP" MacTools
    # Stapling changed the bundle: only the rebuilt final archive is distributed/signed.
    rm "$ARCHIVE"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
    printf 'Developer ID signed and notarized.\n' > "$WORK/output/RELEASE-NOTES.md"
else
    printf 'Locally signed; not notarized.\n\nThis build uses the project’s persistent local signing certificate. Gatekeeper trust on other Macs requires manual approval.\n' > "$WORK/output/RELEASE-NOTES.md"
fi
codesign --verify --deep --strict "$APP"
for name in DockPeek ScreenWren; do codesign --verify --deep --strict "$APP/Contents/Resources/Applications/$name.app"; done
unzip -tq "$ARCHIVE"
mkdir "$WORK/roundtrip"
ditto -x -k "$ARCHIVE" "$WORK/roundtrip"
codesign --verify --deep --strict "$WORK/roundtrip/Mac Tools.app"
python3 "$PROJECT_DIR/scripts/compare-bundles.py" "$APP" "$WORK/roundtrip/Mac Tools.app"
cp "$WORK/output/RELEASE-NOTES.md" "$WORK/output/Mac-Tools-$VERSION.md"
DOWNLOAD_URL="https://github.com/$RELEASE_REPOSITORY/releases/download/v$VERSION/"
"$SPARKLE_TOOLS_DIR/generate_appcast" --account "$SPARKLE_ACCOUNT" \
    --download-url-prefix "$DOWNLOAD_URL" --release-notes-url-prefix "$DOWNLOAD_URL" \
    -o "$WORK/output/appcast.xml" "$WORK/output"
"$SPARKLE_TOOLS_DIR/sign_update" --account "$SPARKLE_ACCOUNT" --verify "$WORK/output/appcast.xml"
"$SPARKLE_TOOLS_DIR/sign_update" --account "$SPARKLE_ACCOUNT" -p "$ARCHIVE" > "$WORK/output/Mac-Tools-$VERSION.zip.ed25519"
"$SPARKLE_TOOLS_DIR/sign_update" --account "$SPARKLE_ACCOUNT" --verify "$ARCHIVE" "$(cat "$WORK/output/Mac-Tools-$VERSION.zip.ed25519")"
python3 - "$WORK/output/appcast.xml" "$ARCHIVE" "$VERSION" "$BUILD" "$RELEASE_REPOSITORY" <<'PY'
import os, sys, xml.etree.ElementTree as ET
feed, archive, version, build, repository = sys.argv[1:]
ns={'sparkle':'http://www.andymatuschak.org/xml-namespaces/sparkle'}
items=ET.parse(feed).findall('./channel/item')
item=next((i for i in items if i.findtext('sparkle:version', namespaces=ns)==build), None)
if item is None: raise SystemExit('Appcast is missing the current build.')
e=item.find('enclosure')
expected=f'https://github.com/{repository}/releases/download/v{version}/Mac-Tools-{version}.zip'
assert e.get('url') == expected, 'Unexpected archive URL'
assert e.get('length') == str(os.path.getsize(archive)), 'Archive size mismatch'
assert e.get('{'+ns['sparkle']+'}edSignature') == open(archive + '.ed25519').read().strip(), 'Archive signature mismatch'
PY
python3 - "$WORK/output/release.json" "$VERSION" "$BUILD" "$MODE" "$SOURCE_REPOSITORY" "$(git -C "$PROJECT_DIR" rev-parse HEAD)" <<'PY'
import json, sys
path, version, build, mode, repository, revision=sys.argv[1:]
with open(path,'w') as output:
    json.dump(dict(version=version, build=int(build), signingMode=mode, sourceRepository=repository, sourceRevision=revision),output,indent=2)
PY
(cd "$WORK/output" && shasum -a 256 "Mac-Tools-$VERSION.zip" appcast.xml > SHA256SUMS)
mv "$WORK/output" "$DESTINATION"
echo "Verified $MODE release: $DESTINATION"
if [ "$PUBLISH" = 1 ]; then
    # The single publication step follows all signature, archive, and (when requested)
    # notarization/Gatekeeper checks. Never overwrite an existing release or asset.
    TARGET_ARGS=()
    if [ "$RELEASE_REPOSITORY" = "$SOURCE_REPOSITORY" ]; then TARGET_ARGS=(--target "$(git -C "$PROJECT_DIR" rev-parse HEAD)"); fi
    gh release create "v$VERSION" --repo "$RELEASE_REPOSITORY" ${TARGET_ARGS[@]+"${TARGET_ARGS[@]}"} \
        --title "Mac Tools $VERSION" --notes-file "$DESTINATION/RELEASE-NOTES.md" \
        "$DESTINATION/Mac-Tools-$VERSION.zip" "$DESTINATION/appcast.xml" \
        "$DESTINATION/Mac-Tools-$VERSION.md" "$DESTINATION/Mac-Tools-$VERSION.zip.ed25519" "$DESTINATION/SHA256SUMS" "$DESTINATION/release.json"
fi
