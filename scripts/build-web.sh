#!/usr/bin/env bash
# Build wer for the browser (WebAssembly) into build/web/: index.html,
# wer.js, wer.wasm. Serve that folder over HTTP (browsers don't load .wasm
# from file://), e.g.:  python3 -m http.server -d build/web
#
# Needs Emscripten (emcc): if it isn't on the PATH, ~/emsdk/emsdk_env.sh is
# used (git clone https://github.com/emscripten-core/emsdk ~/emsdk, then
# ./emsdk install latest && ./emsdk activate latest).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if ! command -v emcc >/dev/null; then
	# shellcheck disable=SC1091
	source "${EMSDK:-$HOME/emsdk}/emsdk_env.sh" >/dev/null 2>&1
fi
cd "$ROOT"
c3c build web -O3
mkdir -p build/web
cp build/wer.js build/wer.wasm web/index.html web/privacy.html build/web/
echo "$ROOT/build/web"
