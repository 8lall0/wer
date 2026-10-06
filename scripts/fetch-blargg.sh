#!/usr/bin/env bash
# Fetch Blargg's test ROMs (the single-test builds) into test/blargg/<suite>/
# from https://github.com/retrio/gb-test-roms .
#
#   scripts/fetch-blargg.sh
#
# The ROMs are git-ignored. test/suites/blargg_test.c3 runs whatever is present;
# with none it prints one line per suite and passes.
set -euo pipefail

BASE="https://raw.githubusercontent.com/retrio/gb-test-roms/master"
DEST="$(cd "$(dirname "$0")/.." && pwd)/test/blargg"

# fetch <suite> <path in the repository, without .gb> ...
fetch() {
	local suite="$1"
	shift
	mkdir -p "$DEST/$suite"
	for path in "$@"; do
		curl -fsSL "$BASE/${path// /%20}.gb" -o "$DEST/$suite/$(basename "$path").gb"
	done
}

SOUND=(
	"01-registers" "02-len ctr" "03-trigger" "04-sweep" "05-sweep details"
	"06-overflow on trigger" "07-len sweep period sync" "08-len ctr during power"
	"09-wave read while on" "10-wave trigger while on" "11-regs after power"
)
fetch dmg_sound "${SOUND[@]/#/dmg_sound/rom_singles/}" "dmg_sound/rom_singles/12-wave write while on"
# cgb_sound: the same up to 11, and a plain wave test instead of 12.
fetch cgb_sound "${SOUND[@]/#/cgb_sound/rom_singles/}" "cgb_sound/rom_singles/12-wave"

CPU=(
	"01-special" "02-interrupts" "03-op sp,hl" "04-op r,imm" "05-op rp" "06-ld r,r"
	"07-jr,jp,call,ret,rst" "08-misc instrs" "09-op r,r" "10-bit ops" "11-op a,(hl)"
)
fetch cpu_instrs "${CPU[@]/#/cpu_instrs/individual/}"
fetch instr_timing "instr_timing/instr_timing"
TIMING=("01-read_timing" "02-write_timing" "03-modify_timing")
fetch mem_timing "${TIMING[@]/#/mem_timing/individual/}"
fetch mem_timing-2 "${TIMING[@]/#/mem_timing-2/rom_singles/}"
fetch halt_bug "halt_bug"
fetch interrupt_time "interrupt_time/interrupt_time"
OAM=(
	"1-lcd_sync" "2-causes" "3-non_causes" "4-scanline_timing" "5-timing_bug"
	"6-timing_no_bug" "7-timing_effect" "8-instr_effect"
)
fetch oam_bug "${OAM[@]/#/oam_bug/rom_singles/}"

echo "fetched Blargg's test ROMs into $DEST"
