// whisper.cpp を静的リンクで直接呼ぶためのブリッジ。
// dylib を読み込まないので Hardened Runtime 下でも library validation を無効化せずに済む。
#import "whisper.h"
#import "ggml.h"

// sherpa-onnx（ReazonSpeech / parakeet-ja）。これも静的リンク。
#import "c-api.h"
