#!/usr/bin/env bash
# Publish the web build on GitHub Pages: builds it (scripts/build-web.sh) and
# commits the page, wer.js, wer.wasm and the licenses to the gh-pages branch
# (kept in a worktree at build/gh-pages), then pushes it. The site is
# https://<owner>.github.io/<repo>/ once Pages serves that branch.
#
#   scripts/deploy-web.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
"$ROOT/scripts/build-web.sh" >/dev/null
VERSION="$(sed -n 's/^ *"version": *"\([0-9.]*\)".*/\1/p' project.json)"
SITE="$ROOT/build/gh-pages"

if [ ! -d "$SITE" ]; then
	git fetch -q origin gh-pages 2>/dev/null || true
	if git show-ref -q --verify refs/remotes/origin/gh-pages; then
		git worktree add -q -B gh-pages "$SITE" origin/gh-pages
	else
		git worktree add -q --detach "$SITE"
		(cd "$SITE" && git checkout -q --orphan gh-pages && git rm -rq --cached . && git clean -fdxq)
	fi
fi

cd "$SITE"
cp "$ROOT/build/web/index.html" "$ROOT/build/web/wer.js" "$ROOT/build/web/wer.wasm" "$ROOT/LICENSE" "$ROOT/LICENSE-sameboy" .
touch .nojekyll # served as they are
git add -A
if git diff --cached --quiet; then
	echo "gh-pages already has this build"
else
	git commit -q -m "wer $VERSION in the browser"
	git push -q origin gh-pages
	echo "pushed wer $VERSION to gh-pages"
fi
