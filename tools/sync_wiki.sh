#!/usr/bin/env bash
# wiki/ ディレクトリ (リポジトリ内で版本管理する wiki 原稿) を GitHub Wiki へ発行する。
# 前提: GitHub の Wiki で最初のページを一度だけ Web から作成済みであること
#       (GitHub は Web で初回作成されるまで .wiki.git を生成しない)。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WIKI_REMOTE="git@github.com:yukiinagato/ox-app-doorbell.wiki.git"
TMP="$(mktemp -d /tmp/doorbell-wiki.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

git clone -q "$WIKI_REMOTE" "$TMP"
# 全置換同期 (wiki/ が正)
find "$TMP" -maxdepth 1 -name '*.md' -delete
cp "$ROOT"/wiki/*.md "$TMP/"
cd "$TMP"
git add -A
if git diff --cached --quiet; then
  echo "変更なし"
else
  git commit -q -m "sync from main repo wiki/ ($(cd "$ROOT" && git rev-parse --short HEAD))"
  git push -q
  echo "発行完了: https://github.com/yukiinagato/ox-app-doorbell/wiki"
fi
