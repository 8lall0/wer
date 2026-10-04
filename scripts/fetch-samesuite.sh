#!/usr/bin/env bash
# Fetch and build SameSuite (https://github.com/LIJI32/SameSuite, MIT) into
# test/samesuite/. There are no prebuilt ROMs: needs git and RGBDS.
#
#   scripts/fetch-samesuite.sh
#
# The ROMs are git-ignored. Without them the test prints one line and passes.
set -euo pipefail

DEST="$(cd "$(dirname "$0")/.." && pwd)/test/samesuite"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git clone -q --depth 1 https://github.com/LIJI32/SameSuite "$TMP/src"
# The tests were checked on hardware as assembled by RGBDS of 2018-2019, which
# turned `ld [rXX], a` and `ld a, [rXX]` into the shorter `ldh`. Current RGBDS
# doesn't, and the extra M-cycle (after `ld [rDIV], a` mostly) breaks the APU
# tests' timing: restore the old encoding.
find "$TMP/src" -name "*.asm" -o -name "*.inc" | xargs sed -i -E \
	-e 's/\bld (\[r[A-Z0-9]+\]), a\b/ldh \1, a/' \
	-e 's/\bld a, (\[r[A-Z0-9]+\])/ldh a, \1/'
make -s -C "$TMP/src" -j"$(nproc)" >/dev/null 2>&1 # (RGBDS 1.0 warns about its old syntax)
rm -rf "$DEST"
(cd "$TMP/src" && find . -name "*.gb" | while read -r f; do
	mkdir -p "$DEST/$(dirname "$f")"
	cp "$f" "$DEST/$f"
done)
echo "built $(find "$DEST" -name '*.gb' | wc -l) SameSuite ROMs into $DEST"
