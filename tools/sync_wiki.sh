#!/usr/bin/env bash
# Publish the tracked wiki/ source directory to GitHub Wiki.
# Prerequisite: create the first Wiki page once through GitHub's web interface because GitHub
# does not create the .wiki.git repository until that initial page exists.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WIKI_REMOTE="git@github.com:yukiinagato/ox-app-doorbell.wiki.git"
TMP="$(mktemp -d /tmp/doorbell-wiki.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

git clone -q "$WIKI_REMOTE" "$TMP"
# Replace all Markdown pages; the tracked wiki/ directory is the source of truth.
find "$TMP" -maxdepth 1 -name '*.md' -delete
cp "$ROOT"/wiki/*.md "$TMP/"
cd "$TMP"
git add -A
if git diff --cached --quiet; then
  echo "No changes."
else
  git commit -q -m "sync from main repo wiki/ ($(cd "$ROOT" && git rev-parse --short HEAD))"
  git push -q
  echo "Published: https://github.com/yukiinagato/ox-app-doorbell/wiki"
fi
