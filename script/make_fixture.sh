#!/bin/bash
# 統合テスト用の検証素材を作る。
# 「発話 → 約8分の無音（休憩） → 発話再開」を含む区間を切り出す。
# この構成でないと、無音ゲート・カバレッジの穴検出・自動再認識のどれも試せない。
set -euo pipefail
export PATH=/opt/homebrew/bin:/usr/bin:/bin
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-}"
START="${2:-3420}"    # 元動画での開始秒
DUR="${3:-660}"

if [ -z "$SRC" ]; then
  echo "usage: $0 <source-video> [start-sec] [duration-sec]"
  echo "  例: $0 ~/Movies/2026-08-05\\ 09-57-32.mov 3420 660"
  exit 2
fi
command -v ffmpeg >/dev/null || { echo "ffmpeg が必要 (brew install ffmpeg)"; exit 1; }

mkdir -p "$ROOT/fixtures"
ffmpeg -nostdin -y -ss "$START" -t "$DUR" -i "$SRC" \
  -map 0:a:0 -c:a aac -b:a 128k -vn "$ROOT/fixtures/testclip.m4a"
ls -la "$ROOT/fixtures/testclip.m4a"
echo "完了。IntegrationTests がこの素材を使う（無い場合はスキップされる）"
