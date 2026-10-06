#!/usr/bin/env bash
# Fetch gbmicrotest (aappleby/GBMicrotest, MIT), as prebuilt by
# c-sp/game-boy-test-roms, into test/gbmicrotest/ for test/suites/gbmicrotest_test.c3.
#
#   scripts/fetch-gbmicrotest.sh
#
# Needs curl and unzip. The tests were checked on a DMG (DMG-CPU-08); each
# writes its verdict to $FF82 ($01 pass, $FF fail) within a few frames. A
# few ROMs in the set are not tests and write nothing.
set -euo pipefail

VERSION=v7.0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/test/gbmicrotest"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -sfL -o "$TMP/roms.zip" \
	"https://github.com/c-sp/game-boy-test-roms/releases/download/$VERSION/game-boy-test-roms-$VERSION.zip"
unzip -q "$TMP/roms.zip" 'gbmicrotest/*' -d "$TMP"
rm -rf "$DEST"
mv "$TMP/gbmicrotest" "$DEST"
ls "$DEST"/*.gb | xargs -n1 basename > "$DEST/index.txt"
echo "$(wc -l < "$DEST/index.txt") gbmicrotest ROMs in test/gbmicrotest/"
