// whisper.cpp を静的リンクで直接呼ぶためのブリッジ。
// dylib を読み込まないので Hardened Runtime 下でも library validation を無効化せずに済む。
#import "whisper.h"
#import "ggml.h"

// sherpa-onnx（ReazonSpeech / parakeet-ja）。これも静的リンク。
#import "c-api.h"

// NeMo-Speech.cpp の話者分離（Nemotron 3 Diarization）。これも静的リンク。
// upstream の ggml と同梱物を束ねた libnemo_diar.o 経由で、nemo_speech_*
// 以外のシンボルはローカル化してある（whisper 側の ggml と衝突しない）。
#import "nemo_speech/diar.h"
