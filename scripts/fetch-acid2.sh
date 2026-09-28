#!/usr/bin/env bash
# Fetch dmg-acid2 (https://github.com/mattcurrie/dmg-acid2, MIT) into test/acid2/.
#
#   scripts/fetch-acid2.sh
#
# Downloads the ROM and the DMG reference screenshot, and converts the PNG to a
# binary PGM so test/acid2_test.c3 needs no PNG decoder. Needs ImageMagick.
# The files are git-ignored. Without them the test prints one line and passes.
set -euo pipefail

DEST="$(cd "$(dirname "$0")/.." && pwd)/test/acid2"
mkdir -p "$DEST"

curl -fsSL "https://github.com/mattcurrie/dmg-acid2/releases/download/v1.0/dmg-acid2.gb" \
	-o "$DEST/dmg-acid2.gb"
curl -fsSL "https://raw.githubusercontent.com/mattcurrie/dmg-acid2/master/img/reference-dmg.png" \
	-o "$DEST/reference-dmg.png"
magick "$DEST/reference-dmg.png" -colorspace gray -depth 8 "$DEST/reference-dmg.pgm"

echo "fetched dmg-acid2 into $DEST"
