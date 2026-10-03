#!/usr/bin/env bash
# Fetch wilbertpol's 2016 fork of the Mooneye test suite (MIT), as prebuilt by
# c-sp/game-boy-test-roms, into test/wilbertpol/ for test/wilbertpol_test.c3.
#
#   scripts/fetch-wilbertpol.sh
#
# Needs curl, unzip and python3. Like Mooneye then, a test ends at the
# undefined opcode $ED with B C D E H L = 3 5 8 13 21 34 on success, and its
# name ends in the hardware it was checked on: G = DMG, S = SGB, C = CGB,
# A = GBA, mgb/sgb/dmg/cgb; no suffix = all. Only acceptance/,
# emulator-only/ and misc/ are self-checking.
# test/wilbertpol/index.txt gets one line per check: <dmg|cgb> <rom>
set -euo pipefail

VERSION=v7.0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/test/wilbertpol"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -sfL -o "$TMP/roms.zip" \
	"https://github.com/c-sp/game-boy-test-roms/releases/download/$VERSION/game-boy-test-roms-$VERSION.zip"
unzip -q "$TMP/roms.zip" 'mooneye-test-suite-wilbertpol/*' -d "$TMP"
rm -rf "$DEST"
mv "$TMP/mooneye-test-suite-wilbertpol" "$DEST"

python3 - "$DEST" <<'EOF'
import os, re, sys
root = sys.argv[1]
lines = []
for d, _, files in sorted(os.walk(root)):
    rel = os.path.relpath(d, root)
    if not rel.split("/")[0] in ("acceptance", "emulator-only", "misc"):
        continue
    for f in sorted(files):
        if not f.endswith(".gb"):
            continue
        m = re.search(r"-([A-Za-z0-9]+)\.gb$", f)
        tag = m.group(1) if m else ""
        if tag in ("dmg", "G", "GS"):
            models = ["dmg"]
        elif tag in ("C", "cgb"):
            models = ["cgb"]
        elif tag in ("S", "sgb", "sgb2", "A", "mgb"):
            models = []   # not emulated here (SGB timing tests, GBA, Pocket)
        else:
            models = ["dmg", "cgb"]
        rom = os.path.relpath(os.path.join(d, f), root)
        lines += [f"{m} {rom}" for m in models]
open(os.path.join(root, "index.txt"), "w").write("\n".join(lines) + "\n")
print(f"{len(lines)} wilbertpol checks indexed in test/wilbertpol/index.txt")
EOF
