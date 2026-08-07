#!/bin/bash
# sherpa-onnx を macOS arm64 の静的ライブラリとしてビルドする。
# ReazonSpeech-k2-v2 (zipformer) と parakeet-tdt_ctc-0.6b-ja の両方をこれ1つで賄う。
#
# タグを固定しているのは再現性のためだが、実害もある: master は onnxruntime 1.27.1 を
# pin しているものの、上流がそのリリースアセットを差し替えたためハッシュが合わず
# configure に失敗する。v1.13.4 は 1.27.0 を pin していて通る。
set -u
export PATH=/opt/homebrew/bin:/usr/bin:/bin
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(ls -d /Applications/Xcode*.app 2>/dev/null | head -1)/Contents/Developer}
# スクリプト自身の位置からリポジトリ直下を割り出す（環境に依存させない）
P="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$P/vendor/sherpa-onnx"
TAG="v1.13.4"

cd "$P/vendor" || exit 1
if [ ! -d sherpa-onnx ]; then
  git clone https://github.com/k2-fsa/sherpa-onnx.git 2>&1 | tail -2
fi
cd "$S" || exit 1
git fetch --tags origin > /dev/null 2>&1
git checkout -q "$TAG" 2>&1 | tail -1
echo "[$(date +%T)] sherpa-onnx $(git describe --tags 2>/dev/null)"

rm -rf build-static
echo "[$(date +%T)] configure"
cmake -B build-static -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DSHERPA_ONNX_ENABLE_C_API=ON \
  -DSHERPA_ONNX_ENABLE_TTS=OFF \
  -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF \
  -DSHERPA_ONNX_ENABLE_WEBSOCKET=OFF \
  -DSHERPA_ONNX_ENABLE_SPEAKER_DIARIZATION=OFF \
  -DSHERPA_ONNX_ENABLE_BINARY=OFF \
  -DSHERPA_ONNX_ENABLE_PYTHON=OFF \
  -DSHERPA_ONNX_BUILD_C_API_EXAMPLES=OFF \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.3 > cfg.log 2>&1
echo "cfg_rc=$?"; tail -4 cfg.log
echo "[$(date +%T)] build"
cmake --build build-static --config Release -j "$(sysctl -n hw.ncpu)" > bld.log 2>&1
echo "bld_rc=$?"; tail -6 bld.log
echo "=== .a ==="; find build-static -name "*.a" | sort
echo "=== c-api.h ==="; ls -la sherpa-onnx/c-api/c-api.h
echo "[$(date +%T)] DONE_SHERPA"
