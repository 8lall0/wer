#!/usr/bin/env bash
# Compile wer.exe's Windows resources (icon, manifest, version information
# from project.json) into build/wer.res, which the windows target links.
# Needs llvm-rc.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/resources/windows"
OUT="$ROOT/build"
VERSION="$(sed -n 's/^ *"version": *"\([0-9.]*\)".*/\1/p' "$ROOT/project.json")"
mkdir -p "$OUT"
# llvm-rc has no Windows SDK headers: put in the winver.h values used.
sed -e "s/@VERSION@/$VERSION/g" -e "s/@VERSION_COMMAS@/${VERSION//./,}/g" \
	-e '/#include/d' -e 's/VS_VERSION_INFO/1/' -e 's/VOS_NT_WINDOWS32/0x40004L/' \
	-e 's/VFT_APP/0x1L/' -e 's/VFT2_UNKNOWN/0x0L/' "$SRC/wer.rc.in" > "$OUT/wer.rc"
llvm-rc -no-preprocess -I "$SRC" -FO "$OUT/wer.res" "$OUT/wer.rc"
test -s "$OUT/wer.res"
echo "Windows resources for wer $VERSION: $OUT/wer.res"
