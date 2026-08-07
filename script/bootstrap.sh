#!/bin/bash
# whisper.cpp を取得して macOS arm64 用の静的ライブラリを作る。
# 静的リンクにしているのは、Hardened Runtime 下で未署名 dylib を読ませないため。
set -euo pipefail
export PATH=/opt/homebrew/bin:/usr/bin:/bin
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(ls -d /Applications/Xcode*.app 2>/dev/null | head -1)/Contents/Developer}

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WHISPER_TAG="v1.9.1"
V="$ROOT/vendor/whisper.cpp"

for t in git cmake xcodegen; do
  command -v "$t" >/dev/null || { echo "必要なツールがない: $t (brew install $t)"; exit 1; }
done

mkdir -p "$ROOT/vendor"
if [ ! -d "$V" ]; then
  echo "==> whisper.cpp $WHISPER_TAG を取得"
  git clone --depth 1 --branch "$WHISPER_TAG" https://github.com/ggml-org/whisper.cpp.git "$V"
fi

if [ ! -f "$V/build-macos/src/libwhisper.a" ]; then
  echo "==> whisper.cpp をビルド (Metal 埋め込み / 静的)"
  cmake -S "$V" -B "$V/build-macos" -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_EXAMPLES=OFF \
    -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_BLAS_DEFAULT=ON \
    -DGGML_METAL_USE_BF16=ON -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF -DGGML_ACCELERATE=ON \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=13.3
  cmake --build "$V/build-macos" --config Release -j "$(sysctl -n hw.ncpu)"
fi

echo "==> Xcode プロジェクトを生成"
cd "$ROOT" && xcodegen generate

echo "完了。次: script/build_and_run.sh verify"
