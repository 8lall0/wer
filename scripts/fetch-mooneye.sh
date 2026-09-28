#!/usr/bin/env bash
# Fetch the prebuilt Mooneye Test Suite (https://github.com/Gekkio/mooneye-test-suite)
# into test/mooneye/.
#
#   scripts/fetch-mooneye.sh
#
# The ROMs are git-ignored. test/mooneye_test.c3 runs whatever is present;
# with none it prints one line and passes.
set -euo pipefail

RELEASE="mts-20260714-0944-31510e1"
URL="https://gekkio.fi/files/mooneye-test-suite/$RELEASE/$RELEASE.tar.gz"
DEST="$(cd "$(dirname "$0")/.." && pwd)/test/mooneye"

rm -rf "$DEST"
mkdir -p "$DEST"
curl -fsSL "$URL" | tar xz -C "$DEST" --strip-components=1

echo "fetched $RELEASE into $DEST ($(find "$DEST" -name '*.gb' | wc -l) ROMs)"
