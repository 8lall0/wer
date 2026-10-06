#!/usr/bin/env bash
# Fetch Gambatte's hardware tests (sinamas, via pokemon-speedrunning/gambatte-core)
# as prebuilt by c-sp/game-boy-test-roms into test/gambatte/, and index them
# for test/suites/gambatte_test.c3. From the same collection, the MBC3 tests
# rtc3test and mbc3-tester go to test/mbc3/ (test/suites/mbc3_test.c3).
#
#   scripts/fetch-gambatte.sh
#
# Needs curl, unzip and python3. The expected result is in each ROM's name,
# as Gambatte's own testrunner reads it:
#   ..._dmg08_cgb04c_outXX  both models show hex XX in the top-left corner
#   ..._dmg08_outXX / _cgb04c_outYY, or just _outYY (CGB only)
#   ..._outaudio0 / 1       the last frame is silent / is not
#   <rom>_dmg08.png, <rom>_cgb04c.png, <rom>_dmg08_cgb04c.png: the whole screen
# test/gambatte/index.txt gets one line per check:
#   <dmg|cgb> <hex|audio|png> <rom> <expected: hex digits, 0/1, or .rgb file>
# and every reference PNG a .rgb twin (160x144, 3 bytes per pixel).
set -euo pipefail

VERSION=v7.0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/test/gambatte"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -sfL -o "$TMP/roms.zip" \
	"https://github.com/c-sp/game-boy-test-roms/releases/download/$VERSION/game-boy-test-roms-$VERSION.zip"
unzip -q "$TMP/roms.zip" 'gambatte/*' 'rtc3test/*' 'mbc3-tester/*' -d "$TMP"
rm -rf "$DEST" "$ROOT/test/mbc3"
mv "$TMP/gambatte" "$DEST"
mkdir -p "$ROOT/test/mbc3"
cp "$TMP"/rtc3test/*.gb "$TMP"/rtc3test/*-dmg.png "$TMP"/mbc3-tester/*.gb "$TMP"/mbc3-tester/*-dmg.png "$ROOT/test/mbc3/"

python3 - "$DEST" "$ROOT/test/mbc3" <<'EOF'
import os, sys, struct, zlib

root = sys.argv[1]

def png_to_rgb(path):
    """8-bit RGB/RGBA PNG -> raw RGB bytes (stdlib only)."""
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", path
    pos, idat, w = 8, b"", 0
    while pos < len(data):
        n, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if kind == b"IHDR":
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
            assert depth == 8 and ctype in (2, 6) and interlace == 0, path
            bpp = 4 if ctype == 6 else 3
        elif kind == b"IDAT":
            idat += body
        pos += 12 + n
    raw = zlib.decompress(idat)
    stride = w * bpp
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
            out += line[x * bpp:x * bpp + 3]
        prev = line
    return bytes(out)

lines = []
for d, _, files in sorted(os.walk(root)):
    for f in sorted(files):
        if not f.endswith((".gb", ".gbc")):
            continue
        rom = os.path.relpath(os.path.join(d, f), root)
        s = rom[:rom.rfind(".")]
        checks = []
        def out(tag, model):
            v = s[s.find(tag) + len(tag):]
            if v.startswith("audio"):
                checks.append((model, "audio", v[5]))
            else:
                checks.append((model, "hex", v.split("_")[0]))
        if "dmg08_cgb04c_out" in s:
            out("dmg08_cgb04c_out", "dmg"); out("dmg08_cgb04c_out", "cgb")
        elif "dmg08_out" in s:
            out("dmg08_out", "dmg")
            if "cgb04c_out" in s: out("cgb04c_out", "cgb")
        elif "_out" in s:
            out("_out", "cgb")
        for suffix, models in (("_dmg08_cgb04c", ("dmg", "cgb")), ("_cgb04c", ("cgb",)), ("_dmg08", ("dmg",))):
            png = os.path.join(root, s + suffix + ".png")
            if os.path.exists(png):
                open(png[:-4] + ".rgb", "wb").write(png_to_rgb(png))
                for m in models:
                    checks.append((m, "png", s + suffix + ".rgb"))
                if suffix == "_dmg08_cgb04c":
                    break
        for model, kind, expect in checks:
            lines.append(f"{model} {kind} {rom} {expect}")

open(os.path.join(root, "index.txt"), "w").write("\n".join(lines) + "\n")
print(f"{len(lines)} Gambatte checks indexed in test/gambatte/index.txt")

mbc3 = sys.argv[2]
for f in os.listdir(mbc3):
    if f.endswith(".png"):
        open(os.path.join(mbc3, f[:-4] + ".rgb"), "wb").write(png_to_rgb(os.path.join(mbc3, f)))
print("MBC3 tests in test/mbc3/")
EOF
