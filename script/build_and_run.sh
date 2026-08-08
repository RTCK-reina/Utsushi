#!/bin/bash
# 単一の .app を常に同じ場所に作り、build / run / verify / test / logs を1本で回す。
set -euo pipefail
export PATH=/opt/homebrew/bin:/usr/bin:/bin
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(ls -d /Applications/Xcode*.app 2>/dev/null | head -1)/Contents/Developer}

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Utsushi"
BUNDLE_ID="app.rtck.Utsushi"
CONFIG="${CONFIG:-Debug}"
APP_BUNDLE="$ROOT/build/$CONFIG/$APP_NAME.app"
MODE="${1:-run}"

quit_running() {
  osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  sleep 0.4
}

build() {
  cd "$ROOT"
  [ -f "$ROOT/$APP_NAME.xcodeproj/project.pbxproj" ] || xcodegen generate
  xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
    -configuration "$CONFIG" -destination 'platform=macOS,arch=arm64' build
}

case "$MODE" in
  build) build ;;
  run)   quit_running; build; open -n "$APP_BUNDLE" ;;
  verify)
    quit_running; build; open -n "$APP_BUNDLE"; sleep 3
    if pgrep -x "$APP_NAME" >/dev/null; then
      echo "OK: $APP_NAME は起動して動作している"
    else
      echo "NG: ビルドは通ったが $APP_NAME が起動していない"; exit 1
    fi
    codesign -dv --verbose=2 "$APP_BUNDLE" 2>&1 | sed -n '1,8p'
    ;;
  test)
    cd "$ROOT"
    [ -f "$ROOT/$APP_NAME.xcodeproj/project.pbxproj" ] || xcodegen generate
    xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
      -configuration Debug -destination 'platform=macOS,arch=arm64' test
    ;;
  logs)
    quit_running; build; open -n "$APP_BUNDLE"
    log stream --predicate "process == \"$APP_NAME\"" --level debug
    ;;
  release)
    CONFIG=Release
    APP_BUNDLE="$ROOT/build/Release/$APP_NAME.app"
    quit_running; build
    echo "できたもの: $APP_BUNDLE"
    codesign -dv --verbose=2 "$APP_BUNDLE" 2>&1 | sed -n '1,6p'
    ;;
  install)
    # /Applications に置く。既存があれば置き換える。
    CONFIG=Release
    APP_BUNDLE="$ROOT/build/Release/$APP_NAME.app"
    quit_running; build
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP_BUNDLE" "/Applications/$APP_NAME.app"
    echo "/Applications/$APP_NAME.app に入れた"
    ;;
  dist)
    # 配布用の .zip を作る。
    #
    # 注意: ad-hoc 署名なので、他の Mac に渡すと Gatekeeper に止められる。
    # 受け取る側は Finder で右クリック →「開く」か、
    #   xattr -dr com.apple.quarantine /Applications/Utsushi.app
    # が要る。これを消すには Apple Developer Program（有償）の
    # Developer ID 証明書と公証が要るので、ここでは対応しない。
    CONFIG=Release
    APP_BUNDLE="$ROOT/build/Release/$APP_NAME.app"
    quit_running; build
    VER=$(defaults read "$APP_BUNDLE/Contents/Info" CFBundleShortVersionString)
    OUT="$ROOT/build/$APP_NAME-$VER-arm64.zip"
    rm -f "$OUT"
    ditto -c -k --keepParent "$APP_BUNDLE" "$OUT"
    echo "できたもの: $OUT"
    echo "受け取る側は初回だけ右クリック →「開く」が要る（ad-hoc 署名のため）"
    ;;
  icon)
    python3 "$ROOT/script/make_icon.py"
    ;;
  clean) rm -rf "$ROOT/build" "$ROOT/$APP_NAME.xcodeproj" ;;
  *) echo "usage: $0 {build|run|verify|test|logs|release|install|dist|icon|clean}"; exit 2 ;;
esac
