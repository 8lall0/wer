#!/usr/bin/env python3
# wer's program icon: a tilted red Game Boy and "wer." on a green blob, as
# 32x32 pixel art in the 16-colour VGA palette (after resources/Rew._icon.png).
#
#   scripts/make-icon.py
#
# Writes resources/wer.svg (the icon, one rect per horizontal run of a colour)
# and src/frontend/icon.c3 (the same pixels, for the window icon). Needs python3.
import math, os
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
N = 32
PAL = {
    'R': '#ff0000', 'M': '#800000', 'C': '#00ffff', 'P': '#ff00ff', 'G': '#008000',
    'Y': '#ffff00', 'K': '#000000', 'g': '#808080', 's': '#c0c0c0', 'O': '#808000',
    'T': '#008080', 'W': '#ffffff', 'B': '#000080',
}
grid = [['.'] * N for _ in range(N)]

ANG = math.radians(22)      # tilt, clockwise
CX, CY = 13.0, 12.6          # body centre on the grid
BW, BH = 17.0, 25.0          # body size (unrotated)

def body_coords(px, py):
    # grid point -> body space (origin top-left of the body), undoing the tilt
    dx, dy = px - CX, py - CY
    c, s = math.cos(-ANG), math.sin(-ANG)
    return dx * c - dy * s + BW / 2, dx * s + dy * c + BH / 2

def in_body(u, v):
    if not (0 <= u <= BW and 0 <= v <= BH): return False
    r = 5.5  # the DMG's rounded bottom-right corner
    if u > BW - r and v > BH - r and math.hypot(u - (BW - r), v - (BH - r)) > r: return False
    return True

def body_layer(u, v):
    if not in_body(u, v): return None
    if 2 <= u <= BW - 2 and 2.2 <= v <= 13.2:          # bezel
        if 3.1 <= u <= BW - 3.1 and 3.3 <= v <= 12.1: return 'C'
        return 'P'
    if (u - 13.0) ** 2 + (v - 17.6) ** 2 <= 1.3: return 'M'   # A
    if (u - 10.8) ** 2 + (v - 19.2) ** 2 <= 1.3: return 'M'   # B
    return 'R'

for y in range(N):
    for x in range(N):
        u, v = body_coords(x + 0.5, y + 0.5)
        c = body_layer(u, v)
        if c: grid[y][x] = c
# bevel: body pixels with no body below-right get the dark red
body = {(x, y) for y in range(N) for x in range(N) if grid[y][x] in 'RMPCK'}
for (x, y) in list(body):
    if grid[y][x] == 'R' and ((x + 1, y) not in body or (x, y + 1) not in body):
        grid[y][x] = 'M'
# d-pad: a clean pixel cross where the rotated d-pad centre lands
c, s_ = math.cos(ANG), math.sin(ANG)
du, dv = 4.6 - BW / 2, 18.4 - BH / 2
px, py = int(CX + du * c - dv * s_), int(CY + du * s_ + dv * c)
for d in range(-2, 3):
    grid[py][px + d] = 'K'
    grid[py + d][px] = 'K'
# screws on the bezel's top corners
for (u, v) in ((2.9, 3.0), (BW - 2.9, 3.0)):
    c, s = math.cos(ANG), math.sin(ANG)
    du, dv = u - BW / 2, v - BH / 2
    gx, gy = CX + du * c - dv * s, CY + du * s + dv * c
    grid[int(gy)][int(gx)] = 'g'

# --- the green blob ---------------------------------------------------------
BX0, BX1, BY0, BY1 = 5.0, 31.8, 19.5, 31.6
def in_blob(x, y):
    cx, cy = (BX0 + BX1) / 2, (BY0 + BY1) / 2
    ax, ay = (BX1 - BX0) / 2, (BY1 - BY0) / 2
    wob = 0
    return abs((x - cx) / ax) ** 3 + abs((y - cy) / ay) ** 3 <= 1 + wob
blob = {(x, y) for y in range(N) for x in range(N) if in_blob(x + 0.5, y + 0.5)}
for (x, y) in blob: grid[y][x] = 'G'
for (x, y) in blob:
    for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        if (x + dx, y + dy) not in blob:
            grid[y][x] = 'K'

# --- "wer." -------------------------------------------------------------------
GLYPHS = {
 'w': ["YY....YY",
       "YY....YY",
       "YY.YY.YY",
       "YY.YY.YY",
       "YYYYYYYY",
       ".YY..YY."],
 'e': [".YYYY.",
       "YY..YY",
       "YYYYY.",
       "YY....",
       "YY...Y",
       ".YYYY."],
 'r': ["YY.YY.",
       "YYYYYY",
       "YYY...",
       "YY....",
       "YY....",
       "YY...."],
 '.': ["..", "..", "..", "..", "YY", "YY"],
}
TEXT = [('w', 4, 23), ('e', 13, 22), ('r', 20, 23), ('.', 27, 24)]
fill = set()
for ch, gx, gy in TEXT:
    for r, row in enumerate(GLYPHS[ch]):
        for c, p in enumerate(row):
            if p == 'Y': fill.add((gx + c, gy + r))
outline = set()
for (x, y) in fill:
    for dx in (-1, 0, 1):
        for dy in (-1, 0, 1):
            q = (x + dx, y + dy)
            if q not in fill: outline.add(q)
for (x, y) in outline:
    if 0 <= x < N and 0 <= y < N: grid[y][x] = 'K'
for (x, y) in fill:
    grid[y][x] = 'Y'
for (x, y) in fill:  # a highlight on each glyph's top-left
    if (x - 1, y) not in fill and (x, y - 1) not in fill and (x + 1, y) in fill and (x, y + 1) in fill:
        grid[y][x] = 'W'

# --- output -------------------------------------------------------------------
svg = ['<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32" width="256" height="256" shape-rendering="crispEdges">',
       '<title>wer</title>']
for y in range(N):
    x = 0
    while x < N:
        c = grid[y][x]
        if c == '.':
            x += 1
            continue
        e = x
        while e + 1 < N and grid[y][e + 1] == c: e += 1
        svg.append(f'<rect x="{x}" y="{y}" width="{e - x + 1}" height="1" fill="{PAL[c]}"/>')
        x = e + 1
svg.append('</svg>')
open(os.path.join(ROOT, "resources", "wer.svg"), "w").write("\n".join(svg) + "\n")

keys = sorted(PAL)
c3 = ["module icon;", "",
      "// wer's program icon, 32x32 pixels: one character per pixel, indexing",
      "// COLOURS ('.' is transparent). Generated by scripts/make-icon.py, which",
      "// also writes resources/wer.svg.", "",
      "const int SIZE = 32;", "",
      f'const String KEYS = "{"".join(keys)}";',
      f"const uint[{len(keys)}] COLOURS = {{ // 0xRRGGBB",
      "\t" + ", ".join("0x" + PAL[k][1:].upper() for k in keys) + ",",
      "};", "",
      f"const String[{N}] PIXELS = {{"]
c3 += [f'\t"{"".join(r)}",' for r in grid]
c3 += ["};", "",
       "// The icon as RGBA bytes, each pixel `scale` x `scale`: out holds",
       "// (SIZE * scale)^2 * 4 bytes.",
       "fn void rgba(char[] out, int scale) {",
       "\tint w = SIZE * scale;",
       "\tfor (int y = 0; y < w; y++) {",
       "\t\tfor (int x = 0; x < w; x++) {",
       "\t\t\tchar k = PIXELS[y / scale][x / scale];",
       "\t\t\tusz i = (usz)(y * w + x) * 4;",
       "\t\t\tsz? c = KEYS.index_of_char(k);",
       "\t\t\tuint rgb = @ok(c) ? COLOURS[c!!] : 0;",
       "\t\t\tout[i]     = (char)(rgb >> 16);",
       "\t\t\tout[i + 1] = (char)(rgb >> 8);",
       "\t\t\tout[i + 2] = (char)rgb;",
       "\t\t\tout[i + 3] = @ok(c) ? 0xFF : 0;",
       "\t\t}",
       "\t}",
       "}", ""]
open(os.path.join(ROOT, "src", "frontend", "icon.c3"), "w").write("\n".join(c3))
print("wrote resources/wer.svg and src/frontend/icon.c3")
