#!/bin/bash
# Build Sift.app.
#
#   ./scripts/fetch-duckdb.sh       -> Vendor/duckdb/libduckdb.dylib (once)
#   ./build-app.sh                  -> ./Sift.app
#   ./build-app.sh /Applications    -> installs there
#   ./build-app.sh --mac-tools-payload -> ./dist/Sift.app, the copy Mac Tools embeds and installs:
#                                        universal, hardened runtime, signed with the monorepo's
#                                        persistent identity, not registered with LaunchServices
#
# The app carries a sandboxed Quick Look extension (Contents/PlugIns/SiftPreview.appex) that shows a
# data file as a table when you press Space in Finder. THIS SCRIPT NEVER REGISTERS IT: no pluginkit,
# no qlmanage -r. A build that stays in this folder is not registered with LaunchServices either
# (that is what makes macOS discover an extension); the system finds the extension when an installed
# copy of the app is first opened.
#
# Full Xcode 27 or newer required: swift build, PlistBuddy, sips, iconutil, osascript, install_name_tool,
# codesign and lsregister all ship with the Command Line Tools. Gatekeeper: quarantine is applied
# by whatever *downloads* a file, so a locally built app just launches; zip it to a teammate and
# they get "Apple could not verify…" — the install path for others is
# `git pull && ./scripts/fetch-duckdb.sh && ./build-app.sh`, not a zip.
#
# The result is self-contained: libduckdb.dylib is copied in and the binary is re-pointed at the
# copy, so the app keeps working with this source tree deleted. Nothing Python, nothing symlinked.
set -euo pipefail
cd "$(dirname "$0")"
HERE="$(pwd)"

PAYLOAD=0
if [[ "${1:-}" == --mac-tools-payload ]]; then
  [[ "$#" -eq 1 ]] || exit 64
  PAYLOAD=1
  IDENTITY_FILE="$HERE/../ScreenWren/.screenwren-signing-identity"
  if [[ -n "${SCREENWREN_SIGNING_IDENTITY:-}" ]]; then
    PAYLOAD_IDENTITY=$SCREENWREN_SIGNING_IDENTITY
  elif [[ -s "$IDENTITY_FILE" ]]; then
    PAYLOAD_IDENTITY=$(cat "$IDENTITY_FILE")
  else
    PAYLOAD_IDENTITY=-
  fi
  if [[ -n "${SCREENWREN_SIGNING_TIMESTAMP:-}" ]]; then
    PAYLOAD_TIMESTAMP=$SCREENWREN_SIGNING_TIMESTAMP
  elif [[ -z "${SCREENWREN_SIGNING_IDENTITY:-}" && -f "$HERE/../ScreenWren/.screenwren-signing-timestamp" ]]; then
    PAYLOAD_TIMESTAMP=$(cat "$HERE/../ScreenWren/.screenwren-signing-timestamp")
  else
    PAYLOAD_TIMESTAMP=secure
  fi
  case "$PAYLOAD_TIMESTAMP" in
    secure) PAYLOAD_TIMESTAMP_OPTION=--timestamp ;;
    none) PAYLOAD_TIMESTAMP_OPTION=--timestamp=none ;;
    *) echo "SCREENWREN_SIGNING_TIMESTAMP must be secure or none." >&2; exit 64 ;;
  esac
  mkdir -p "$HERE/dist"
  STAGE="$(mktemp -d "$HERE/dist/.sift-build.XXXXXX")"
  trap 'rm -rf "$STAGE"' EXIT
  DEST="$STAGE"
else
  DEST="${1:-$HERE}"
fi
APP="$DEST/Sift.app"
PLIST="$APP/Contents/Info.plist"
PB=/usr/libexec/PlistBuddy
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
DYLIB="$HERE/Vendor/duckdb/libduckdb.dylib"

if [[ ! -f "$DYLIB" ]]; then
  echo "build-app: no libduckdb yet. Run ./scripts/fetch-duckdb.sh first." >&2
  exit 1
fi

rm -rf "$APP"

echo "==> building the app"
if [[ "$PAYLOAD" == 1 ]]; then
  # libduckdb-osx-universal carries both slices, so each architecture links against the same file.
  for arch in arm64 x86_64; do
    triple="$arch-apple-macosx14.0"
    swift build -c release --product SiftApp --scratch-path "$STAGE/$arch" --triple "$triple"
    cp "$(swift build -c release --scratch-path "$STAGE/$arch" --triple "$triple" --show-bin-path)/SiftApp" "$STAGE/SiftApp-$arch"
  done
  lipo -create "$STAGE/SiftApp-arm64" "$STAGE/SiftApp-x86_64" -output "$STAGE/SiftApp"
  BIN="$STAGE/SiftApp"
  echo "==> building the Quick Look extension"
  for arch in arm64 x86_64; do
    triple="$arch-apple-macosx14.0"
    swift build -c release --product SiftPreviewExtension --scratch-path "$STAGE/$arch" --triple "$triple"
    cp "$(swift build -c release --scratch-path "$STAGE/$arch" --triple "$triple" --show-bin-path)/SiftPreviewExtension" "$STAGE/SiftPreview-$arch"
  done
  lipo -create "$STAGE/SiftPreview-arm64" "$STAGE/SiftPreview-x86_64" -output "$STAGE/SiftPreview"
  PREVIEW_BIN="$STAGE/SiftPreview"
else
  swift build -c release --product SiftApp
  BIN="$HERE/.build/release/SiftApp"
  echo "==> building the Quick Look extension"
  swift build -c release --product SiftPreviewExtension
  PREVIEW_BIN="$HERE/.build/release/SiftPreviewExtension"
fi
[[ -x "$BIN" ]] || { echo "build-app: swift build produced no binary" >&2; exit 1; }
[[ -x "$PREVIEW_BIN" ]] || { echo "build-app: swift build produced no extension binary" >&2; exit 1; }

echo "==> assembling the bundle"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Sift"
cp "$DYLIB" "$APP/Contents/Frameworks/"

echo "==> re-pointing the engine at the bundled copy"
# libduckdb's own install name is already @rpath/libduckdb.dylib (MEASURED: `otool -D`), so the
# binary's LC_LOAD_DYLIB needs no editing — only the search path does. SwiftPM baked in an absolute
# LC_RPATH to Vendor/duckdb (see Package.swift); that one is DELETED rather than left as a
# fallback, because a fallback is how you ship an app that silently only works on the machine that
# built it — it would keep running here and fail for everyone else.
#
# The path to delete is read back off the binary rather than recomputed from $HERE: a symlinked
# checkout makes `pwd` and the manifest's own #filePath disagree, and `-delete_rpath` fails hard on
# a path that is not there, which under `set -e` would take the whole build with it.
EXE="$APP/Contents/MacOS/Sift"
install_name_tool -add_rpath @executable_path/../Frameworks "$EXE"
# sort -u: a universal binary lists each slice's load commands, and install_name_tool edits every
# slice at once, so a repeated path would fail the second delete.
for rp in $(otool -l "$EXE" | awk '/LC_RPATH/ { want = 1 } want && $1 == "path" { print $2; want = 0 }' | sort -u); do
  case "$rp" in /*/Vendor/duckdb) install_name_tool -delete_rpath "$rp" "$EXE" ;; esac
done
# The whole point of the two lines above, asserted rather than assumed.
if otool -l "$EXE" | grep -q "Vendor/duckdb"; then
  echo "build-app: the binary still searches the source tree for libduckdb" >&2
  exit 1
fi

echo "==> Info.plist"
set_plist() { $PB -c "Delete :$1" "$PLIST" 2>/dev/null || true; $PB -c "Add :$1 $2 $3" "$PLIST"; }
set_plist CFBundleExecutable          string  "Sift"
set_plist CFBundleIconFile            string  "AppIcon"
set_plist CFBundlePackageType         string  "APPL"
set_plist CFBundleIdentifier          string  "io.github.diamondplated.sift"
set_plist CFBundleName                string  "Sift"
set_plist CFBundleDisplayName         string  "Sift"
# VERSION and BUILD are committed. They used to come from `git describe` and the commit count,
# which broke in the mac-apps monorepo: the nearest tag can belong to another app, and Mac Tools
# release builds run from a copy with no .git at all, which stamped 0.0.0 (1) and made Mac Tools
# refuse the bundle as a downgrade. Bump both by hand when Sift changes; BUILD only ever goes up
# (2.0.1 shipped as build 193, the old repo's commit count). Tag releases `sift-vX.Y.Z`.
VERSION="${SIFT_VERSION:-$(tr -d '[:space:]' < "$HERE/VERSION")}"
BUILD="$(tr -d '[:space:]' < "$HERE/BUILD")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "build-app: VERSION must be X.Y.Z" >&2; exit 1; }
[[ "$BUILD" =~ ^[1-9][0-9]*$ ]] || { echo "build-app: BUILD must be a positive integer" >&2; exit 1; }
set_plist CFBundleShortVersionString  string  "$VERSION"
set_plist CFBundleVersion             string  "$BUILD"
set_plist LSMinimumSystemVersion      string  "14.0"
set_plist NSHumanReadableCopyright    string  "Copyright © 2026 diamondplated"
set_plist NSHighResolutionCapable     bool    true
# NSAppTransportSecurity is gone with the WKWebView it existed for. The app talks to no network.

echo "==> declaring the formats macOS does not know"
# MEASURED on macOS 26: a .parquet still has NO system UTI — `UTType(filenameExtension: "parquet")`
# answers org.apache.parquet.file only because a previously installed Sift.app declared it
# (lsregister shows the type owned by bundle "Sift", flagged `imported`). Without a declaration it
# is the dynamic `dyn.ah62d4rv4ge81a2pwsf40n7a`, synthesized from the extension. `Imported` (not
# `Exported`) is correct: Apache and the NDJSON community own these formats; Sift only recognizes
# them.
$PB -c "Delete :UTImportedTypeDeclarations" "$PLIST" 2>/dev/null || true
$PB -c "Add :UTImportedTypeDeclarations array" "$PLIST"

$PB -c "Add :UTImportedTypeDeclarations:0 dict" "$PLIST"
$PB -c "Add :UTImportedTypeDeclarations:0:UTTypeIdentifier string org.apache.parquet.file" "$PLIST"
$PB -c "Add :UTImportedTypeDeclarations:0:UTTypeDescription string 'Apache Parquet File'" "$PLIST"
$PB -c "Add :UTImportedTypeDeclarations:0:UTTypeConformsTo array" "$PLIST"
$PB -c "Add :UTImportedTypeDeclarations:0:UTTypeConformsTo:0 string public.data" "$PLIST"
$PB -c "Add :UTImportedTypeDeclarations:0:UTTypeTagSpecification dict" "$PLIST"
$PB -c "Add :UTImportedTypeDeclarations:0:UTTypeTagSpecification:public.filename-extension array" "$PLIST"
$PB -c "Add :UTImportedTypeDeclarations:0:UTTypeTagSpecification:public.filename-extension:0 string parquet" "$PLIST"
$PB -c "Add :UTImportedTypeDeclarations:0:UTTypeTagSpecification:public.filename-extension:1 string parq" "$PLIST"

# NDJSON conforms to public.plain-text, NOT public.json — newline-delimited JSON is not valid JSON.
# Recent macOS declares `public.ndjson` for .ndjson but still leaves .jsonl to this declaration, so
# both spellings are kept and both are listed in the document types below.
$PB -c "Add :UTImportedTypeDeclarations:1 dict" "$PLIST"
$PB -c "Add :UTImportedTypeDeclarations:1:UTTypeIdentifier string org.ndjson.ndjson" "$PLIST"
$PB -c "Add :UTImportedTypeDeclarations:1:UTTypeDescription string 'Newline-Delimited JSON'" "$PLIST"
$PB -c "Add :UTImportedTypeDeclarations:1:UTTypeConformsTo array" "$PLIST"
$PB -c "Add :UTImportedTypeDeclarations:1:UTTypeConformsTo:0 string public.plain-text" "$PLIST"
$PB -c "Add :UTImportedTypeDeclarations:1:UTTypeTagSpecification dict" "$PLIST"
$PB -c "Add :UTImportedTypeDeclarations:1:UTTypeTagSpecification:public.filename-extension array" "$PLIST"
$PB -c "Add :UTImportedTypeDeclarations:1:UTTypeTagSpecification:public.filename-extension:0 string ndjson" "$PLIST"
$PB -c "Add :UTImportedTypeDeclarations:1:UTTypeTagSpecification:public.filename-extension:1 string jsonl" "$PLIST"

echo "==> document types"
# This is what routes a double-click, a Finder "Open With" and `open -a Sift.app file.csv` into
# AppDelegate's `application(_:open:)`. Deliberately NO NSDocumentClass: the app is not
# document-based, and adding one would change what File > Open Recent draws (see AppDelegate).
$PB -c "Delete :CFBundleDocumentTypes" "$PLIST" 2>/dev/null || true
$PB -c "Add :CFBundleDocumentTypes array" "$PLIST"

# Rank Alternate for formats other apps legitimately own, so Sift appears in "Open With" without
# stealing .csv from Numbers or .xlsx from Excel.
add_doctype() { # index, name, rank
  $PB -c "Add :CFBundleDocumentTypes:$1 dict" "$PLIST"
  $PB -c "Add :CFBundleDocumentTypes:$1:CFBundleTypeName string '$2'" "$PLIST"
  $PB -c "Add :CFBundleDocumentTypes:$1:CFBundleTypeRole string Viewer" "$PLIST"
  $PB -c "Add :CFBundleDocumentTypes:$1:LSHandlerRank string $3" "$PLIST"
  $PB -c "Add :CFBundleDocumentTypes:$1:LSItemContentTypes array" "$PLIST"
}
add_uti() { $PB -c "Add :CFBundleDocumentTypes:$1:LSItemContentTypes:$2 string $3" "$PLIST"; }

add_doctype 0 "Tabular Data" Alternate
add_uti 0 0 public.comma-separated-values-text
add_uti 0 1 public.tab-separated-values-text
add_uti 0 2 public.json
add_uti 0 3 org.openxmlformats.spreadsheetml.sheet
add_uti 0 4 org.openxmlformats.spreadsheetml.sheet.macroenabled   # .xlsm
add_uti 0 5 public.plain-text

# Owner for the ones nothing else claims.
add_doctype 1 "Columnar Data" Owner
add_uti 1 0 org.apache.parquet.file
add_uti 1 1 org.ndjson.ndjson
add_uti 1 2 public.ndjson

# Dropping a hive-partitioned directory or a Delta table is a daily workflow for this audience.
add_doctype 2 "Dataset Folder" Alternate
add_uti 2 0 public.folder

echo "==> icon"
WORK="$(mktemp -d)"
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
BASE="$WORK/icon.png"
# Three white bars tapering downward — a sieve — on the brand-orange rounded square, drawn with
# the Cocoa that ships in macOS. Bar y-centres are flipped (1 - cy): Cocoa's origin is bottom-left.
osascript -l JavaScript - "$BASE" <<'EOF' >/dev/null
ObjC.import('AppKit')
function run(argv) {
  const out = argv[0], size = 1024
  const rep = $.NSBitmapImageRep.alloc.initWithBitmapDataPlanesPixelsWidePixelsHighBitsPerSampleSamplesPerPixelHasAlphaIsPlanarColorSpaceNameBytesPerRowBitsPerPixel(
    null, size, size, 8, 4, true, false, $.NSCalibratedRGBColorSpace, 0, 0)
  $.NSGraphicsContext.setCurrentContext($.NSGraphicsContext.graphicsContextWithBitmapImageRep(rep))
  const pad = size * 0.055, r = size * 0.22
  $.NSColor.colorWithCalibratedRedGreenBlueAlpha(240/255, 83/255, 35/255, 1).setFill  // Sift orange
  $.NSBezierPath.bezierPathWithRoundedRectXRadiusYRadius($.NSMakeRect(pad, pad, size - 2*pad, size - 2*pad), r, r).fill
  $.NSColor.whiteColor.setFill
  for (const [cy, hw, hh] of [[0.335, 0.300, 0.052], [0.500, 0.215, 0.052], [0.665, 0.130, 0.052]])
    $.NSBezierPath.fillRect($.NSMakeRect((0.5 - hw) * size, (1 - cy - hh) * size, 2 * hw * size, 2 * hh * size))
  rep.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $()).writeToFileAtomically(out, true)
}
EOF
for s in 16 32 128 256 512; do
  sips -z $s $s "$BASE" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$BASE" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil --convert icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$WORK"

echo "==> Quick Look extension bundle"
# Built by SwiftPM as a plain executable whose entry point is _NSExtensionMain (Package.swift), then
# wrapped here. It does NOT carry its own libduckdb: it loads the app's copy from the parent
# bundle's Frameworks, so the engine ships once and one signature covers it.
APPEX="$APP/Contents/PlugIns/SiftPreview.appex"
APPEX_PLIST="$APPEX/Contents/Info.plist"
mkdir -p "$APPEX/Contents/MacOS"
cp "$PREVIEW_BIN" "$APPEX/Contents/MacOS/SiftPreview"
cp "$HERE/QuickLookExtension/Info.plist" "$APPEX_PLIST"
$PB -c "Set :CFBundleShortVersionString $VERSION" "$APPEX_PLIST"
$PB -c "Set :CFBundleVersion $BUILD" "$APPEX_PLIST"
PEXE="$APPEX/Contents/MacOS/SiftPreview"
install_name_tool -add_rpath @executable_path/../../../../Frameworks "$PEXE"
for rp in $(otool -l "$PEXE" | awk '/LC_RPATH/ { want = 1 } want && $1 == "path" { print $2; want = 0 }' | sort -u); do
  case "$rp" in /*/Vendor/duckdb) install_name_tool -delete_rpath "$rp" "$PEXE" ;; esac
done
if [[ -n "$(otool -l "$PEXE" | grep "Vendor/duckdb" || true)" ]]; then
  echo "build-app: the extension still searches the source tree for libduckdb" >&2
  exit 1
fi
# The extension starts at _NSExtensionMain, and must not carry the verifier or its loopback server.
[[ -n "$(otool -l "$PEXE" | grep LC_MAIN || true)" ]] || { echo "build-app: the extension has no entry point" >&2; exit 1; }
# (no `grep -q` on a pipe: under pipefail it can SIGPIPE its producer and report the wrong answer)
if [[ -n "$(nm "$PEXE" 2>/dev/null | grep -E 'LoopbackHTTPServer|SiftVerify' || true)" ]]; then
  echo "build-app: the extension links the verifier" >&2
  exit 1
fi
plutil -lint "$APPEX_PLIST" >/dev/null
# "Open with Sift" is only offered for a type Sift declares, so every type the extension previews
# must be one of the app's document types.
DOCTYPES="$(plutil -extract CFBundleDocumentTypes json -o - "$PLIST")"
for uti in $($PB -c "Print :NSExtension:NSExtensionAttributes:QLSupportedContentTypes" "$APPEX_PLIST" | sed -n 's/^ *//p' | grep -v -e '^Array' -e '^}' -e '^$'); do
  grep -qF "\"$uti\"" <<<"$DOCTYPES" || { echo "build-app: the extension previews $uti but Sift does not declare it as a document type" >&2; exit 1; }
done

echo "==> signing"
# Ad-hoc signing is mandatory on Apple Silicon — the kernel refuses unsigned arm64 executables.
# Inside-out: the nested dylib first, then the bundle, and only AFTER install_name_tool, since
# editing load commands invalidates a signature. Deliberately NO --options runtime: the hardened
# runtime's library validation would refuse the vendored libduckdb (different signing identity),
# and without notarizing it buys nothing.
if [[ "$PAYLOAD" == 1 ]]; then
  # Mac Tools payloads all run under the hardened runtime. Library validation stays off: the
  # persistent identity is self-signed (no Team ID to match), and DuckDB loads its delta/excel
  # extensions from ~/.duckdb at run time, which no identity of ours signs.
  cat > "$STAGE/Sift.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.cs.disable-library-validation</key><true/></dict></plist>
PLIST
  if [[ "$PAYLOAD_IDENTITY" == "-" ]]; then
    codesign --force --options runtime --sign - --timestamp=none "$APP/Contents/Frameworks/libduckdb.dylib"
    codesign --force --options runtime --sign - --timestamp=none --entitlements "$HERE/QuickLookExtension/SiftPreview.entitlements" "$APPEX"
    codesign --force --options runtime --sign - --timestamp=none --entitlements "$STAGE/Sift.entitlements" "$APP"
  else
    codesign --force --options runtime --sign "$PAYLOAD_IDENTITY" "$PAYLOAD_TIMESTAMP_OPTION" "$APP/Contents/Frameworks/libduckdb.dylib"
    codesign --force --options runtime --sign "$PAYLOAD_IDENTITY" "$PAYLOAD_TIMESTAMP_OPTION" --entitlements "$HERE/QuickLookExtension/SiftPreview.entitlements" "$APPEX"
    codesign --force --options runtime --sign "$PAYLOAD_IDENTITY" "$PAYLOAD_TIMESTAMP_OPTION" --entitlements "$STAGE/Sift.entitlements" "$APP"
  fi
  codesign --verify --deep --strict "$APP"
  for arch in arm64 x86_64; do
    lipo "$APP/Contents/MacOS/Sift" -verify_arch "$arch"
    lipo "$APPEX/Contents/MacOS/SiftPreview" -verify_arch "$arch"
  done
  rm -rf "$HERE/dist/Sift.app"
  mv "$APP" "$HERE/dist/Sift.app"
  echo "Built $HERE/dist/Sift.app"
  exit 0
fi
codesign --force --sign - --timestamp=none "$APP/Contents/Frameworks/libduckdb.dylib"
# The extension is the one part that always runs hardened and sandboxed, whatever the app does.
codesign --force --options runtime --sign - --timestamp=none --entitlements "$HERE/QuickLookExtension/SiftPreview.entitlements" "$APPEX"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | sed 's/^/    /'
[[ -n "$(codesign -d --entitlements - "$APPEX" 2>/dev/null | grep app-sandbox || true)" ]] || { echo "build-app: the extension is not sandboxed" >&2; exit 1; }
[[ -n "$(codesign -dv "$APPEX" 2>&1 | grep 'flags=.*runtime' || true)" ]] || { echo "build-app: the extension is not hardened" >&2; exit 1; }

if [[ "$DEST" == "$HERE" ]]; then
  echo "==> not registering with LaunchServices (the app stays in the source folder)"
else
  echo "==> registering with LaunchServices"
  # Without this, "Open With" silently keeps showing the previous declarations. This is also what
  # lets macOS find the Quick Look extension, so it only happens for a copy installed elsewhere.
  "$LSREGISTER" -f "$APP" || true
fi

echo
echo "Built $APP"
echo "  drop files anywhere in the window, on the Dock icon, or via File > Open"
