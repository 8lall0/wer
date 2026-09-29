#!/usr/bin/env bash
# Fetch the Mealybug Tearoom tests (https://github.com/mattcurrie/mealybug-tearoom-tests,
# MIT) into test/mealybug/: the ROMs, and the expected screenshots for a DMG
# (DMG-blob) and a CGB (CPU CGB C), converted to binary PGM / PPM so
# test/mealybug_test.c3 needs no PNG decoder. Needs git, unzip and ImageMagick.
#
#   scripts/fetch-mealybug.sh
#
# The files are git-ignored. Without them the test prints one line and passes.
set -euo pipefail

DEST="$(cd "$(dirname "$0")/.." && pwd)/test/mealybug"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git clone -q --depth 1 https://github.com/mattcurrie/mealybug-tearoom-tests "$TMP/repo"
mkdir -p "$DEST/roms" "$DEST/dmg" "$DEST/cgb"
unzip -o -q "$TMP/repo/mealybug-tearoom-tests.zip" -d "$DEST/roms"
for f in "$TMP/repo/expected/DMG-blob/"*.png; do
	magick "$f" -colorspace gray -depth 8 "$DEST/dmg/$(basename "${f%.png}").pgm"
done
for f in "$TMP/repo/expected/CPU CGB C/"*.png; do
	magick "$f" -depth 8 "$DEST/cgb/$(basename "${f%.png}").ppm"
done
echo "fetched Mealybug Tearoom tests into $DEST"
