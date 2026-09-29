#!/usr/bin/env bash
# Fetch Blargg's dmg_sound test ROMs (the single-test builds) into
# test/blargg/dmg_sound/ from https://github.com/retrio/gb-test-roms .
#
#   scripts/fetch-blargg.sh
#
# The ROMs are git-ignored. test/blargg_test.c3 runs whatever is present;
# with none it prints one line and passes.
set -euo pipefail

BASE="https://raw.githubusercontent.com/retrio/gb-test-roms/master/dmg_sound/rom_singles"
DEST="$(cd "$(dirname "$0")/.." && pwd)/test/blargg/dmg_sound"
mkdir -p "$DEST"

ROMS=(
	"01-registers" "02-len ctr" "03-trigger" "04-sweep" "05-sweep details"
	"06-overflow on trigger" "07-len sweep period sync" "08-len ctr during power"
	"09-wave read while on" "10-wave trigger while on" "11-regs after power"
	"12-wave write while on"
)

for r in "${ROMS[@]}"; do
	curl -fsSL "$BASE/${r// /%20}.gb" -o "$DEST/$r.gb"
done
echo "fetched ${#ROMS[@]} dmg_sound ROMs into $DEST"
