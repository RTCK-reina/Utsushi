#!/bin/bash
# NeMo-Speech.cpp を macOS arm64 の静的ライブラリとしてビルドする。
# Nemotron 3 Diarization（話者分離）だけを使う。ASR/TTS/サーバー系は全部切る。
#
# Metal は試したが day-0 リリースの ggml-metal バックエンドが確実に SIGSEGV する
# （テンソルバッファが nil になる上流バグ）。CPU で実時間の約60倍速いので
# 実害はなく、解消されるまで CPU 固定にする。
#
# whisper.cpp と同じく、上流のタグが無い時点のスナップショットをコミットで固定する。
# 97a15af は Nemotron 3 を既定 diarizer にしたコミット（2026-09-24）。
set -u
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(ls -d /Applications/Xcode*.app 2>/dev/null | head -1)/Contents/Developer}
P="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$P/vendor/nemo-speech"
PIN="97a15afa5caa9bce5baaa86c1184103877af4101"
# 上流 build_sentencepiece_static.sh が fetch する commit（v0.2.1系）。
SP_PIN="17d7580d6407802f85855d2cc9190634e2c95624"

cd "$P/vendor" || exit 1
if [ ! -d nemo-speech ]; then
  git clone https://github.com/NVIDIA/NeMo-Speech.cpp.git nemo-speech 2>&1 | tail -2
fi
cd "$S" || exit 1
git fetch -q origin "$PIN" 2>/dev/null || git fetch -q origin
git checkout -q "$PIN" 2>&1 | tail -1
echo "[$(date +%T)] nemo-speech $(git rev-parse --short HEAD)"
# diar は ggml だけあればいい。TTS の open_jtalk 等や llama.cpp は不要
git submodule update --init ggml 2>&1 | tail -2

# --- 上流の SHARED 強制と macOS での static sentencepiece 分岐を直す ---
# 1) add_library(... SHARED ...) を素の add_library に直し BUILD_SHARED_LIBS=OFF を効かせる
# 2) sentencepiece の static archive 分岐が "UNIX AND NOT APPLE" 限定なので macOS にも広げる
# 3) --exclude-libs は GNU ld のオプションで Apple ld64 は解釈できないので消す
# 4) ピン留めした sentencepiece は cmake_minimum_required が古く CMake 4 で止まるので
#    CMAKE_POLICY_VERSION_MINIMUM を渡す必要がある
perl -0pi -e '
  s/add_library\(nemo_speech_asr SHARED \$\{ASR_SOURCES\}\)/add_library(nemo_speech_asr \${ASR_SOURCES})/;
  s/add_library\(nemo_speech_asr_c SHARED c_api\.cpp\)/add_library(nemo_speech_asr_c c_api.cpp)/;
  s/if\(UNIX AND NOT APPLE\)\n    set\(_NEMO_SPEECH_LIBRARY_SUFFIXES/if(UNIX)\n    set(_NEMO_SPEECH_LIBRARY_SUFFIXES/;
  s/    target_link_options\(\n        nemo_speech_asr PRIVATE "LINKER:--exclude-libs,libsentencepiece\.a"\)\n//;
' src/asr/CMakeLists.txt
git diff --stat src/asr/CMakeLists.txt | tail -2

# --- sentencepiece を静的に1本で作る（abseil/protobuf-lite は third_party を内製込み。
# brew の .dylib を拾うとエンドユーザー環境でリンク切れになるので絶対に使わない）---
DEPS="$S/.deps/sentencepiece"
if [ ! -f "$DEPS/lib/libsentencepiece.a" ]; then
  rm -rf "$S/.deps/sp-build"
  mkdir -p "$S/.deps/sp-build" "$DEPS/lib" "$DEPS/include"
  cd "$S/.deps/sp-build" || exit 1
  echo "[$(date +%T)] sentencepiece clone $SP_PIN"
  git init -q src && cd src
  git remote add origin https://github.com/google/sentencepiece.git
  git fetch -q --depth 1 origin "$SP_PIN" || git fetch -q origin
  git checkout -q FETCH_HEAD 2>&1 | tail -1
  cd ..
  cmake -G Ninja -S src -B build -DCMAKE_BUILD_TYPE=Release \
    -DSPM_BUILD_TEST=OFF -DSPM_ENABLE_SHARED=OFF -DSPM_ENABLE_TCMALLOC=OFF \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 > sp-cfg.log 2>&1
  echo "sp_cfg_rc=$?"; tail -4 sp-cfg.log
  cmake --build build --target sentencepiece-static -j "$(sysctl -n hw.ncpu)" > sp-bld.log 2>&1
  echo "sp_bld_rc=$?"; tail -6 sp-bld.log
  cp build/src/libsentencepiece.a "$DEPS/lib/"
  cp src/src/sentencepiece_processor.h "$DEPS/include/"
  cd "$S"
fi
echo "[$(date +%T)] sentencepiece $(ls -la "$DEPS/lib/libsentencepiece.a" | awk '{print $5}') bytes"

rm -rf build-static
echo "[$(date +%T)] configure"
cmake -B build-static -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DNEMO_SPEECH_DEPENDENCY_PREFIX="$S/.deps" \
  -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_TESTING=OFF -DNEMO_SPEECH_BUILD_TESTS=OFF \
  -DNEMO_SPEECH_BUILD_ASR=OFF -DNEMO_SPEECH_BUILD_DIAR=ON \
  -DNEMO_SPEECH_BUILD_TTS=OFF -DNEMO_SPEECH_BUILD_TTS_MOCK=OFF \
  -DNEMO_SPEECH_BUILD_NMT=OFF -DNEMO_SPEECH_BUILD_S2S=OFF \
  -DNEMO_SPEECH_BUILD_EMBEDDER=OFF -DNEMO_SPEECH_BUILD_DENOISER=OFF \
  -DNEMO_SPEECH_BUILD_SOUND_EVENTS=OFF -DNEMO_SPEECH_BUILD_AUDIO_QUERY=OFF \
  -DNEMO_SPEECH_BUILD_HTTP=OFF -DNEMO_SPEECH_BUILD_SERVER=OFF \
  -DNEMO_SPEECH_BUILD_MIC_CAPTURE=OFF -DNEMO_SPEECH_BUILD_AUDIO_TEST=OFF \
  -DNEMO_SPEECH_WITH_VULKAN=OFF -DNEMO_SPEECH_WITH_NORM=OFF \
  -DNEMO_SPEECH_WITH_FLASHLIGHT=OFF \
  -DNEMO_SPEECH_GGML_PATCHED=OFF \
  -DGGML_METAL=OFF -DGGML_NATIVE=ON -DGGML_BLAS=ON \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 > cfg.log 2>&1
echo "cfg_rc=$?"; tail -4 cfg.log
echo "[$(date +%T)] build"
cmake --build build-static --config Release -j "$(sysctl -n hw.ncpu)" > bld.log 2>&1
echo "bld_rc=$?"; tail -6 bld.log

# XcodeGen の LIBRARY_SEARCH_PATHS を1か所にするため .a を平置きに集める
mkdir -p build-static/lib
find build-static -name "lib*.a" ! -path "*/lib/*" -exec cp {} build-static/lib/ \;
cp "$DEPS/lib/libsentencepiece.a" build-static/lib/

# whisper.cpp にも libggml.a があるので、そのままリンクするとシンボルが衝突する。
# nemo-speech 側の ggml / sentencepiece はバージョンが違うため混線すると壊れる。
# そこで必要な .a を全部 `ld -r` で1つのリロケータブルオブジェクトに束ね、
# nemo_speech_* の C API だけを公開シンボルにして残りをローカル化する。
nm -gU build-static/lib/libnemo_speech_asr_c.a \
  | awk '$2=="T" && $3 ~ /^_nemo_speech_/{print $3}' | sort -u \
  > build-static/nemo_exports.txt
ld -r -arch arm64 -platform_version macos 26.0 26.0 -all_load \
  -exported_symbols_list build-static/nemo_exports.txt \
  build-static/lib/libnemo_speech_asr_c.a \
  build-static/lib/libnemo_speech_asr.a \
  build-static/lib/libnemo_speech_runtime_ggml.a \
  build-static/lib/libnemo_speech_common.a \
  build-static/lib/libnemo_speech_engine_registry.a \
  build-static/lib/libggml.a \
  build-static/lib/libggml-base.a \
  build-static/lib/libggml-cpu.a \
  build-static/lib/libggml-blas.a \
  build-static/lib/libsentencepiece.a \
  -o build-static/libnemo_diar.o
echo "=== libnemo_diar.o ==="; ls -la build-static/libnemo_diar.o
nm -gU build-static/libnemo_diar.o | grep -v "nemo_speech_" || true
echo "=== diar.h ==="; ls -la include/nemo_speech/diar.h
echo "[$(date +%T)] DONE_NEMO_SPEECH"
