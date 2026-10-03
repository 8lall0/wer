#!/usr/bin/env bash
# Fetch the AGE test ROMs (c-sp/age-test-roms, MIT), as prebuilt by
# c-sp/game-boy-test-roms, into test/age/ and index them for
# test/age_test.c3.
#
#   scripts/fetch-age.sh
#
# Needs curl, unzip and python3. Each ROM's name lists the hardware it was
# verified on: dmgC (DMG-CPU C), cgbBCE (CPU CGB B, C and E), cgbBC, cgbE,
# and ncm... for a CGB running a DMG game (non-CGB mode). Visual tests come
# with a screenshot per device instead (<rom>-cgbBCE.png, ...).
# test/age/index.txt gets one line per check, for a DMG and a CGB-B, C, E:
#   <dmg|cgb> <b|c|e> <regs|shot> <rom> <.rgb file or -> <pass|fail> <tag>
# `pass`: that revision is in the name; `fail`: verified to differ there.
# Every reference PNG gets a .rgb twin (160x144, 3 bytes per pixel).
set -euo pipefail

VERSION=v7.0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/test/age"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -sfL -o "$TMP/roms.zip" \
	"https://github.com/c-sp/game-boy-test-roms/releases/download/$VERSION/game-boy-test-roms-$VERSION.zip"
unzip -q "$TMP/roms.zip" 'age-test-roms/*' -d "$TMP"
rm -rf "$DEST"
mv "$TMP/age-test-roms" "$DEST"

python3 - "$DEST" <<'EOF'
import os, re, sys, struct, zlib

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

TAG = re.compile(r"(dmg|cgb|ncm)([A-E]+)")

def checks(tag, kind, rom, ref):
    m = TAG.fullmatch(tag)
    hw, revs = m.group(1), m.group(2)
    if hw == "dmg":
        return [f"dmg c {kind} {rom} {ref} pass {tag}"]
    # The CGB revisions AGE was verified on: B, C and E.
    return [f"cgb {r} {kind} {rom} {ref} {'pass' if r.upper() in revs else 'fail'} {tag}" for r in "bce"]

lines = []
for d, _, files in sorted(os.walk(root)):
    for f in sorted(files):
        if not f.endswith(".gb"):
            continue
        rom = os.path.relpath(os.path.join(d, f), root)
        base = f[:-3]
        shots = [x for x in sorted(files) if x.endswith(".png") and TAG.fullmatch(x[len(base) + 1:-4] or "-")
                 and x.startswith(base + "-")]
        if shots:
            for png in shots:
                rgb = os.path.join(d, png[:-4] + ".rgb")
                open(rgb, "wb").write(png_to_rgb(os.path.join(d, png)))
                lines += checks(png[len(base) + 1:-4], "shot", rom, os.path.relpath(rgb, root))
            continue
        for tag in TAG.findall(base):
            lines += checks("".join(tag), "regs", rom, "-")

open(os.path.join(root, "index.txt"), "w").write("\n".join(lines) + "\n")
print(f"{len(lines)} AGE checks indexed in test/age/index.txt")
EOF
