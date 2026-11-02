#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swiftc -module-cache-path "$work/module-cache" -parse-as-library -D SPARKLE_PREFLIGHT_TESTS scripts/sparkle-key-preflight.swift scripts/tests/sparkle-preflight-tests.swift -o "$work/tests"
"$work/tests"
# Compile the production entry point; do not run it against a live keychain.
swiftc -module-cache-path "$work/module-cache" -parse-as-library scripts/sparkle-key-preflight.swift -o "$work/production"
python3 scripts/tests/test-release-noninteractive.py
