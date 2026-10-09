#!/usr/bin/env bash
# Fetch dmg-acid2 and cgb-acid2 (https://github.com/mattcurrie/dmg-acid2,
# https://github.com/mattcurrie/cgb-acid2, both MIT) into test/acid2/.
#
#   scripts/fetch-acid2.sh
#
# Downloads the ROMs and their reference screenshots, and converts the PNGs to
# binary PGM/PPM so test/suites/acid2_test.c3 needs no PNG decoder. Needs ImageMagick.
# The files are git-ignored. Without them the test prints one line and passes.
set -euo pipefail
# ImageMagick 7's magick, else 6's convert (as on Debian and Ubuntu).
magick() { if type -P magick >/dev/null; then command magick "$@"; else convert "$@"; fi; }

DEST="$(cd "$(dirname "$0")/.." && pwd)/test/acid2"
mkdir -p "$DEST"

curl -fsSL "https://github.com/mattcurrie/dmg-acid2/releases/download/v1.0/dmg-acid2.gb" \
	-o "$DEST/dmg-acid2.gb"
curl -fsSL "https://raw.githubusercontent.com/mattcurrie/dmg-acid2/master/img/reference-dmg.png" \
	-o "$DEST/reference-dmg.png"
magick "$DEST/reference-dmg.png" -colorspace gray -depth 8 "$DEST/reference-dmg.pgm"

curl -fsSL "https://github.com/mattcurrie/cgb-acid2/releases/download/v1.1/cgb-acid2.gbc" \
	-o "$DEST/cgb-acid2.gbc"
curl -fsSL "https://raw.githubusercontent.com/mattcurrie/cgb-acid2/master/img/reference.png" \
	-o "$DEST/reference-cgb.png"
magick "$DEST/reference-cgb.png" -depth 8 "$DEST/reference-cgb.ppm"

echo "fetched dmg-acid2 and cgb-acid2 into $DEST"
