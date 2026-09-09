#!/usr/bin/env bash
# Fetch SingleStepTests/sm83 CPU test vectors into test/sm83/v1/.
#
#   scripts/fetch-sm83-tests.sh          curated subset (~25 MB) used by CI
#   scripts/fetch-sm83-tests.sh --all    every opcode (~500 MB, sweep ~5 min)
#
# The vectors are git-ignored. test/sm83_test.c3 runs whatever is present.
set -euo pipefail

BASE="https://raw.githubusercontent.com/SingleStepTests/sm83/main/v1"
DEST="$(cd "$(dirname "$0")/.." && pwd)/test/sm83/v1"
mkdir -p "$DEST"

# Opcodes not modelled by the harness: STOP, HALT, and the SM83's undefined bytes.
SKIP="10 76 d3 db dd e3 e4 eb ec ed f4 fc fd"

subset() {
	# One representative opcode per instruction family + a CB spread.
	printf '%s\n' 00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f \
	     17 18 1f 20 27 2a 2f 31 32 34 35 37 39 3f \
	     40 46 70 80 86 88 8e 90 96 98 a0 a6 a8 b0 b8 be \
	     c0 c1 c2 c3 c4 c5 c6 c7 c9 cd d6 d9 de \
	     e0 e2 e8 e9 ea f0 f1 f3 f8 f9 fa fb fe
	for o in 00 06 30 38 40 46 80 c0; do echo "cb $o"; done
}

all() {
	for i in $(seq 0 255); do
		o=$(printf '%02x' "$i")
		case " $SKIP " in *" $o "*) continue;; esac
		echo "$o"
	done
	for i in $(seq 0 255); do printf 'cb %02x\n' "$i"; done
}

if [[ "${1:-}" == "--all" ]]; then LIST=$(all); else LIST=$(subset); fi

count=0
while IFS= read -r name; do
	[[ -z "$name" ]] && continue
	out="$DEST/${name}.json"
	url="$BASE/${name// /%20}.json"
	if curl -fsS "$url" -o "$out"; then
		count=$((count + 1))
	else
		echo "warn: failed $name" >&2
	fi
done <<< "$LIST"

echo "fetched $count files into $DEST"
