#!/usr/bin/env bash
# Fetch Blargg's dmg_sound and cgb_sound test ROMs (the single-test builds)
# into test/blargg/{dmg,cgb}_sound/ from https://github.com/retrio/gb-test-roms .
#
#   scripts/fetch-blargg.sh
#
# The ROMs are git-ignored. test/blargg_test.c3 runs whatever is present;
# with none it prints one line and passes.
set -euo pipefail

BASE="https://raw.githubusercontent.com/retrio/gb-test-roms/master"
DEST="$(cd "$(dirname "$0")/.." && pwd)/test/blargg"
mkdir -p "$DEST/dmg_sound" "$DEST/cgb_sound"

ROMS=(
	"01-registers" "02-len ctr" "03-trigger" "04-sweep" "05-sweep details"
	"06-overflow on trigger" "07-len sweep period sync" "08-len ctr during power"
	"09-wave read while on" "10-wave trigger while on" "11-regs after power"
	"12-wave write while on"
)
# cgb_sound: same tests up to 11, and a plain wave test instead of 12.
CGB_ROMS=("${ROMS[@]:0:11}" "12-wave")

for r in "${ROMS[@]}"; do
	curl -fsSL "$BASE/dmg_sound/rom_singles/${r// /%20}.gb" -o "$DEST/dmg_sound/$r.gb"
done
for r in "${CGB_ROMS[@]}"; do
	curl -fsSL "$BASE/cgb_sound/rom_singles/${r// /%20}.gb" -o "$DEST/cgb_sound/$r.gb"
done
echo "fetched ${#ROMS[@]} dmg_sound and ${#CGB_ROMS[@]} cgb_sound ROMs into $DEST"
