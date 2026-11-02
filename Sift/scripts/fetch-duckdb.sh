#!/usr/bin/env bash
# Fetches the prebuilt DuckDB library. Nothing is compiled from source: the C++
# amalgamation is 400 files and this keeps the exact version pin the engine's
# measured behaviors depend on.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="2.0.0"
SHA256="14cd63180614cfd961f7959146ecd9087527ff20b67311efdc3fa1c29c18204d"
URL="https://github.com/duckdb/duckdb/releases/download/v${VERSION}/duckdb-shared-libs-osx-universal.tar.gz"

# Skip only when the files on disk are the pinned version. Presence alone isn't enough: after a
# bump, an existing checkout would keep the old dylib and header while this reported the new one.
STAMP="Vendor/duckdb/VERSION"
if [ -f Vendor/duckdb/libduckdb.dylib ] && [ -f Sources/CDuckDB/duckdb.h ] \
   && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "${VERSION}" ]; then
  echo "libduckdb ${VERSION} already present; delete Vendor/ to refetch."
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Downloading libduckdb ${VERSION}…"
curl -fsSL -o "$tmp/libduckdb.tar.gz" "$URL"

echo "Verifying checksum…"
actual="$(shasum -a 256 "$tmp/libduckdb.tar.gz" | cut -d' ' -f1)"
if [ "$actual" != "$SHA256" ]; then
  echo "CHECKSUM MISMATCH" >&2
  echo "  expected: $SHA256" >&2
  echo "  actual:   $actual" >&2
  exit 1
fi

mkdir -p "$tmp/out"
tar -xzf "$tmp/libduckdb.tar.gz" -C "$tmp/out"
mkdir -p Vendor/duckdb Sources/CDuckDB
cp "$tmp/out/libduckdb.dylib" Vendor/duckdb/
# The header lives beside the module map so the module map needs no -I flag.
cp "$tmp/out/duckdb.h" Sources/CDuckDB/
# Written last, so an interrupted fetch never looks complete.
printf '%s\n' "${VERSION}" > "$STAMP"

echo "libduckdb ${VERSION} ready."
