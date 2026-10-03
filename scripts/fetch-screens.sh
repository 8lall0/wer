#!/usr/bin/env bash
# Fetch the small screenshot-checked test ROMs of c-sp/game-boy-test-roms
# (cgb-acid-hell, bully, strikethrough, turtle-tests, scribbltests,
# little-things-gb firstwhite, Mooneye's manual-only sprite_priority) into
# test/screens/ for test/screens_test.c3.
#
#   scripts/fetch-screens.sh
#
# Needs curl, unzip and python3. test/screens/index.txt gets one line per
# check: <dmg|cgb> <revision> <frames, or 0 = until LD B,B> <rom> <.rgb>.
# The reference PNGs get .rgb twins (160x144, 3 bytes per pixel).
set -euo pipefail

VERSION=v7.0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/test/screens"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -sfL -o "$TMP/roms.zip" \
	"https://github.com/c-sp/game-boy-test-roms/releases/download/$VERSION/game-boy-test-roms-$VERSION.zip"
unzip -q "$TMP/roms.zip" 'cgb-acid-hell/*' 'bully/*' 'strikethrough/*' 'turtle-tests/*' \
	'scribbltests/*' 'little-things-gb/*' 'mooneye-test-suite/manual-only/*' -d "$TMP"
rm -rf "$DEST"
mkdir -p "$DEST"
mv "$TMP"/cgb-acid-hell "$TMP"/bully "$TMP"/strikethrough "$TMP"/turtle-tests \
	"$TMP"/scribbltests "$TMP"/little-things-gb "$DEST/"
mv "$TMP/mooneye-test-suite/manual-only" "$DEST/mooneye-manual"

python3 - "$DEST" <<'EOF'
import os, sys, struct, zlib

root = sys.argv[1]

def png_to_rgb(path):
    """8-bit RGB/RGBA or 1-8-bit palette PNG -> raw RGB bytes (stdlib only)."""
    data = open(path, "rb").read()
    pos, idat, w, plte = 8, b"", 0, b""
    while pos < len(data):
        n, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if kind == b"IHDR":
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
            assert ctype in (2, 3, 6) and interlace == 0, path
            assert depth == 8 or (ctype == 3 and depth in (1, 2, 4)), path
            bpp = {2: 3, 3: 1, 6: 4}[ctype]
        elif kind == b"PLTE":
            plte = body
        elif kind == b"IDAT":
            idat += body
        pos += 12 + n
    raw = zlib.decompress(idat)
    stride = (w * depth + 7) // 8 if ctype == 3 else w * bpp
    out, prev = bytearray(), bytearray(stride)
    for y in range(h):
        f = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + b) & 255
            elif f == 3: line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        for x in range(w):
            if ctype == 3:
                bit = x * depth
                idx = (line[bit // 8] >> (8 - depth - bit % 8)) & ((1 << depth) - 1)
                out += plte[idx * 3:idx * 3 + 3]
            else:
                out += line[x * bpp:x * bpp + 3]
        prev = line
    return bytes(out)

for d, _, files in os.walk(root):
    for f in files:
        if f.endswith(".png"):
            p = os.path.join(d, f)
            open(p[:-4] + ".rgb", "wb").write(png_to_rgb(p))

# scribbltests were checked on a CPU CGB D; scxly's CGB screenshot shows the
# CGB boot ROM's colours for a DMG game, so only its DMG one is used.
CHECKS = """
cgb c 0 cgb-acid-hell/cgb-acid-hell.gbc cgb-acid-hell/cgb-acid-hell.rgb
dmg c 30 bully/bully.gb bully/bully.rgb
cgb c 30 bully/bully.gb bully/bully.rgb
dmg c 30 strikethrough/strikethrough.gb strikethrough/strikethrough-dmg.rgb
cgb c 30 strikethrough/strikethrough.gb strikethrough/strikethrough-cgb.rgb
dmg c 30 turtle-tests/window_y_trigger/window_y_trigger.gb turtle-tests/window_y_trigger/window_y_trigger.rgb
cgb c 30 turtle-tests/window_y_trigger/window_y_trigger.gb turtle-tests/window_y_trigger/window_y_trigger.rgb
dmg c 30 turtle-tests/window_y_trigger_wx_offscreen/window_y_trigger_wx_offscreen.gb turtle-tests/window_y_trigger_wx_offscreen/window_y_trigger_wx_offscreen.rgb
cgb c 30 turtle-tests/window_y_trigger_wx_offscreen/window_y_trigger_wx_offscreen.gb turtle-tests/window_y_trigger_wx_offscreen/window_y_trigger_wx_offscreen.rgb
dmg c 10 scribbltests/lycscx/lycscx.gb scribbltests/lycscx/lycscx-cgb-dmg.rgb
cgb d 10 scribbltests/lycscx/lycscx.gb scribbltests/lycscx/lycscx-cgb-dmg.rgb
dmg c 10 scribbltests/lycscy/lycscy.gb scribbltests/lycscy/lycscy-cgb-dmg.rgb
cgb d 10 scribbltests/lycscy/lycscy.gb scribbltests/lycscy/lycscy-cgb-dmg.rgb
dmg c 10 scribbltests/palettely/palettely.gb scribbltests/palettely/palettely-dmg.rgb
cgb d 10 scribbltests/palettely/palettely.gb scribbltests/palettely/palettely-cgb.rgb
dmg c 10 scribbltests/scxly/scxly.gb scribbltests/scxly/scxly-dmg.rgb
dmg c 270 scribbltests/statcount/statcount-auto.gb scribbltests/statcount/statcount_auto-cgb-dmg.rgb
cgb d 270 scribbltests/statcount/statcount-auto.gb scribbltests/statcount/statcount_auto-cgb-dmg.rgb
dmg c 30 little-things-gb/firstwhite.gb little-things-gb/firstwhite-dmg-cgb.rgb
cgb c 30 little-things-gb/firstwhite.gb little-things-gb/firstwhite-dmg-cgb.rgb
dmg c 0 mooneye-manual/sprite_priority.gb mooneye-manual/sprite_priority-dmg.rgb
cgb c 0 mooneye-manual/sprite_priority.gb mooneye-manual/sprite_priority-cgb.rgb
"""
lines = [l for l in CHECKS.strip().splitlines()]
open(os.path.join(root, "index.txt"), "w").write("\n".join(lines) + "\n")
print(f"{len(lines)} screenshot checks indexed in test/screens/index.txt")
EOF
