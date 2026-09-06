# Utsushi

[日本語](README.md) | **English**

A macOS app that transcribes video and audio entirely on device. A single `.app` with no Python and no server.

## What it does

1. Extracts audio from video (AVFoundation; ffmpeg is not bundled)
2. Transcribes it (whisper.cpp on Metal, or the SpeechTranscriber built into macOS)
3. **Removes hallucinations mechanically** (see below)
4. Re-reads with an engine of a different lineage and surfaces the disagreements (sherpa-onnx)
5. Has a language model judge those disagreements (it can only return the **number** of a candidate)
6. Uses context to catch passages every engine got wrong the same way (the model lists words, then **picks one**)
7. Proofreads the Japanese (Apple Foundation Models, with every suggestion passing a gate)
8. Extracts key points (the body is quoted verbatim; the model never writes prose)
9. Exports to Markdown, SRT, VTT, TXT or JSON

One principle runs through all of it:
**the model may only choose or propose, and the code assembles the text.**

## Guarding against hallucination

Whisper-family models always say *something* in silence or noise. This is structural rather than accidental, so the defences are deterministic rather than prompt- or threshold-based.

| Layer | Method | Effect |
|---|---|---|
| Silence gate | Discards text whenever the peak level in a span is below the threshold | Phantom phrases such as "thanks for watching" cannot survive into the output |
| Repetition loop detection | Discards runs of three or more identical segments. **Loops lasting over 10 seconds are re-read with the rolling context switched off** | Once whisper enters a loop it never escapes before the end of the audio (44 minutes vanished from a 57-minute recording). Discarding alone loses the content |
| Known phrases | Drops known hallucination phrases, but only in quiet spans | Keeps them when they were genuinely spoken |
| Density anomaly | Flags spans with too few characters for their length that still contain over 5 seconds of voice | Finds places where the voice detector merged speech into silence |
| Span trimming | Trims silence from **both ends** of a segment down to where audio actually exists | Prevents inflated coverage figures and improves subtitle timing |
| Automatic re-recognition | Re-reads only the suspect spans and substitutes the result only when it carries more information (dropped speech is re-read without voice detection, loops without carried context) | Recovers dropped speech and loops without making things worse. Coverage is recomputed after substitution |

### Timestamps drift, so absorb it in the span

Whisper on Metal **returns different timestamps for identical audio and settings depending on machine load**. Run alone three times it is identical (22 segments, 1,083 characters, 73.5% coverage), yet alongside other tests the same clip once reported 95.1%. **The recognized text is the same (1,083 versus 1,084 characters); only the times move.**

Whisper's voice detection compacts the audio before recognizing it, so when the times are mapped back a segment before a silence can receive an end from beyond it, or the reverse. Previously only the tail was trimmed, so when this happened at the head the span stayed inflated and coverage was misreported. **It breaks in the direction of higher coverage**, which makes it look like an improvement if you only watch the number.

The drift itself cannot be removed, but trimming leading and trailing silence back to where audio exists makes coverage converge on the right value regardless. Whatever is trimmed is recorded as `segmentOverrun`; nothing is fixed silently. Segments of 8 seconds or less are left alone, because trimming them cuts into the start of speech.

## Guarding against hallucination in proofreading

**The language model never writes prose. It proposes edits, which are verified mechanically and dropped when they fail.**

```
source ──▶ dictionary ──▶ notation and filler rules ──▶ model proposal ──▶ EditGate ──▶ accept/reject
           (deterministic)  (deterministic)                                  ↑
                                            anything that fails stays as the original
```

Conditions in `EditGate` (`Sources/UtsushiCore/Correction/EditGate.swift`):

- **Matching reading**: readings before and after are taken with `CFStringTokenizer`, and any edit that changes them is rejected. Recognition errors are homophones, so a correct fix never changes pronunciation. 機構 to 気候 passes; 御社 to 貴社 and 新小物 to BeeX do not.
- **No new alphanumeric tokens**: an independent guard against the model inventing English words absent from the source.
- **Length ratio 0.75–1.35, edit distance within 40**: stops both padding and summarizing.
- **Agreement**: an edit is accepted only when the same suggestion appears twice (on by default).

These are enforced in code, not in the prompt. Relaxing them requires changing the source.

Errors that change the reading itself, such as company and personal names, cannot be fixed by the model by design. The only route for those is the **proper noun dictionary**, a deliberate line drawn so the model is never asked to guess a name.

The source text always remains in `Segment.original`, corrections are shown as a diff, and each one can be reverted individually.

## Cross-checking against another engine

The same audio is recognized by an engine of a different lineage and the disagreements are extracted (`Sources/UtsushiCore/CrossCheck/`). Agreement is a reason to trust a passage; disagreement is a reason to look.

Measured on the same 11-minute clip (real audio, 160 seconds of speech):

| Engine | Lineage | Speed | Characters | License |
|---|---|---|---|---|
| whisper large-v3-turbo | encoder-decoder | 92× | 1,064 | MIT |
| SenseVoice-Small | non-autoregressive | **90×** | 1,104 | Apache-2.0 |
| ReazonSpeech-k2-v2 | zipformer transducer | 60× | 952 | Apache-2.0 |
| parakeet-tdt_ctc-0.6b-ja | NeMo CTC | 29× | 1,006 | CC BY 4.0 (attribution required; it is added to exports automatically) |

Adding whisper large-v3 achieves little: turbo is distilled from it, so their errors correlate and they are not independent as an ensemble. **Changing the lineage is what matters.**

The **built-in Apple SpeechTranscriber can also be used for cross-checking**. Measured on 57 minutes of real audio:

| Item | Measured |
|---|---|
| Speed | 30 seconds (115×). Nothing to download, so no first-run wait |
| Repetition loops | 0% (whisper large-v3-turbo spent 45% of the same audio in loops) |
| Agreement with others | 0.655 with whisper, 0.622 with the sherpa engines on average. It leans towards neither lineage |

For comparison, SenseVoice and Parakeet agree at 0.762: **the existing cross-check engines resemble each other more.**

It is not suited to primary recognition. It supports neither vocabulary hints nor token likelihoods, so the dictionary cannot correct proper nouns and no low-confidence marks appear. In practice 頂上の手前 ("just before the summit") became 長女の手前 ("in front of the eldest daughter"). Because its errors read as valid Japanese, **you cannot notice them when it is the primary engine.** As a cross-check, the same error surfaces as a disagreement.

### Tried and set aside

**Qwen3-ASR 0.6B (an LLM-decoder model)** remains selectable but is not recommended by default. With identical audio, identical settings, temperature 0 and a fixed seed, its output still changes across processes (753, 758 and 759 characters). Within one process it is consistent, which points at something like the parallel reduction order in onnxruntime, though **the cause has not been identified**. As a cross-check partner it produces "settled last time, undecided this time", so character error rate is not reproducible. It is also 6.7× real time, an order of magnitude behind the others. The settings screen states all of this.

**sherpa-onnx-sense-voice-…-2025-09-09** is unused. The name suggests a newer SenseVoice, but the onnx metadata reads `comment=ASLP-lab/WSYue-ASR`: **it is a different model aimed at Cantonese**. Fed Japanese, it drops the kana and emits only kanji (287 characters for 11 minutes). The build uses the 2024-07-17 release, the original SenseVoice-Small from FunASR.

Judgement of disagreements lives in `DisagreementAdjudicator`. A `@Generable enum` constrains the model to returning the number of a candidate, so there is structurally no room for it to invent a third string. Disagreements with matching readings (機構 versus 気候) are counted separately from those with differing readings. The former cannot be separated acoustically, which makes context the right tool; the latter still holds information in the audio, so a text-only judgement is less reliable. That is why the two are never merged into a single count.

### Sorting disagreements into four kinds

Reading all 282 disagreements left to a human on real data (11 minutes, 4 engines) showed that **only about 5% were worth looking at**. The rest were not recognition errors at all. They are now classified mechanically, and only substantive differences are shown by default.

| | What it is | Measured |
|---|---|---|
| Substantive | Worth a human look | 171 |
| Alignment | Text landed in the neighbouring window; both engines have it | 78 |
| Inflection | Particle and ending variation, repeated throughout the recording | 39 |
| Notation | 三月 versus 3月, いただ versus 頂 | 26 |

**Nothing is thrown away.** Every classification is a mechanical approximation and can be wrong, so the counts are always on screen and one checkbox reveals them all. Hiding is not the same as pretending they never existed.

Care taken in the classification:

- **Repetition alone never collapses an item.** A misrecognized company or personal name repeats, so a rule based on frequency would hide precisely what you most want to see. `.inflection` is limited to pairs made only of hiragana and punctuation.
- **An empty side is kept when the neighbouring window has no text either**, because that is genuinely dropped speech.
- **Homophones are never collapsed.** If both sides contain kanji it is not a mixed-script variation.

#### Still too many (unresolved)

The count fell from 282 to 171, but 171 in 11 minutes is still too many, and **each pass returned less: 282, then 190, then 171.**

The cause is the unit of comparison, not the classification. Strings are matched mechanically over 10-second windows, so spans cut through the middle of words. A fragment has no defined reading, which disables the reading check and increases the number of one-sided spans. Classification can name the symptom but cannot remove the cause.

Fixing it means realigning on sentences (marked by 。？！ and long pauses), which would mean rebuilding `TranscriptAlignment`, so it has been left alone. **More importantly, chasing the count without ground truth cannot distinguish "removed the noise" from "threw away the real findings."** That is what is needed first.

### Normalize notation before comparing

Zipformer writes 三月 where parakeet writes 3月. Both are correct, yet they line up as a disagreement.

`Notation` (`Sources/UtsushiCore/Text/`) normalizes kanji numerals and full- and half-width forms before comparison. The expectation going in was that notation would account for most disagreements; in practice it was 29 of 574, or 5%, so **the guess was wrong**. Separating notation is still worthwhile, but it was not the main cause.

The same normalization is used by the summary gate. It once existed only on the summary side, so the same 三月 and 3月 counted as identical for summaries yet as a disagreement for cross-checking.

The unit of comparison is aligned here too. Segments of 20 to 27 seconds used to fall whole into several 10-second windows, inflating the differences to 574. Text is now split by the overlapping time ratio, which applies equally to engines without word-level timestamps. Adjacent windows use the same rounding, and tests confirm that no characters are lost or duplicated. Zero-length segments, which `SpeechAnalyzer` produces as `end == start`, cannot be split by ratio and are placed whole into the window containing their timestamp; dropping them would silently remove text from the comparison.

## Exports are built for a language model to read

This transcript is written on the assumption that it will be handed to another language model, not only read by a person. What matters then is different.

**A person can compare the body against the audit record at the back; a model will not.** It reads the body as established fact and becomes confidently wrong on the strength of a doubtful word. So "which parts are doubtful" has to sit in the same place as the text.

```
`[00:00:34]` 当社は結構一気通貫で横のつながりも実際にあったりはするので、…
> ↳ candidates from other engines: 「貫」→「関」 / 「一」→「意」
```

**The body is never rewritten.** Candidates are attached beside it and the source is untouched, because handing over a tidied sentence fixes the edit as fact.

The conditions for attaching a note are narrow, since showing everything makes the body unreadable:

- Substantive differences only. Alignment, inflection and notation do not change a reader's judgement.
- Text on both sides. An empty side offers no alternative, so there is nothing the reader can do with it.
- **The word must actually appear on that line.** Disagreements carry a 10-second window, so matching on overlap alone attaches the same note to neighbouring lines, which it used to do.
- Comparable lengths. Showing a pair such as 「〜人事の方」 against 「まずで実際」 makes an entire clause look like a different sentence.

This yields 15 annotated lines for an 11-minute clip, catching things like 部長陣 misheard as 部長人 and 一気通貫 as 一気通関.

The document opens with a section on how to read it, declaring the symbols and the **known weaknesses** up front:

- Homophones and proper nouns get confused. Treat any word that does not make sense as a possible misrecognition.
- **Speakers are not separated.** A conversation between several people reads as one continuous speaker.
- Do not treat numbers, proper nouns or dates as settled on the strength of this document alone.

The audit section is explicitly marked as not being spoken content. Without that, its wording gets quoted as if someone had said it.

### Filling the gap cross-checking cannot reach

**A passage that every engine got wrong the same way cannot be detected by cross-checking.** On real data all four engines turned 期初 ("start of the term") into 気象 ("weather"), and the sentence was published as it stood. A majority vote over acoustics cannot reach this; the only remaining evidence is context.

So `PlausibilityChecker` (`Sources/UtsushiCore/Audit/`) has a language model point out words that do not make sense as Japanese. **The principle that the model never writes the body is unchanged.**

```
`[00:00:04]` 大体気象の目標を3月から4月ぐらいに立てまして、…
> ⚠︎ word that does not fit the context: 「気象」 — possibly 「期初」
```

The model may return only a line number, a word on that line, and a word that might belong there. The type has no field in which to return body text.

### Rebuilt after measuring against the real model

When first written it had never once run against the real model, because another process was holding 13 GB and every call was refused with `CriticalMemoryPressure`. Once it did run, **it returned no findings at all**. Isolating the cause showed the feature had been built on a false premise.

The measured capability turned out to be **asymmetric**:

| Question | Result |
|---|---|
| Does it know 期初 and 一気通貫? | **Yes.** It explains both correctly |
| Which word is out of place? | **The same answer three times out of three.** Stable |
| What should that word be (generation)? | **Misses.** 境界, 気温, 目標. Supplying the reading does not help |
| Pick one from a list (selection) | **Correct three times out of three** (it picks 気象) |

**It can locate the word but cannot retrieve the right one.** The knowledge is there; generation cannot reach it, and no prompt got past that.

So the feature was reshaped to fit:

1. **Stage one** lists words that look out of place in context
2. **Stage two** picks the single most suspicious one, because selection is accurate
3. The candidate replacement is **verified by phonetic proximity**, and when it is too far **the candidate alone is dropped while the flag remains**

```
`[00:00:04]` 大体気象の目標を3月から4月ぐらいに立てまして、…
> ⚠︎ word that looks out of place: 「気象」 (the correct word is unknown)
```

Step 3 matters because the candidates the model offers, such as 目標 or 気温, are not even close in sound. Demanding an exact reading match would drop the very case most worth catching, 気象 (kishou) to 期初 (kisho), so the requirement is proximity rather than equality:

| Pair | Reading | Normalized distance | |
|---|---|---|---|
| 気象 → 期初 | kishou / kisho | 0.17 | keep |
| 一気通関 → 一気通貫 | identical | 0.00 | keep |
| 気象 → 気温 | kishou / kion | 0.67 | drop |
| 気象 → 目標 | kishou / mokuhyou | 0.88 | drop |

The highest value to keep is 0.17 and the lowest to drop is 0.67, a wide gap, so the threshold sits at 0.34.

The flag itself passes a separate gate:

| Condition | Why it is dropped |
|---|---|
| **The word must exist in the body** | Otherwise a warning about a nonexistent word sits beside the text |
| The line number must exist | Prevents flags on invented lines |
| Eight characters or fewer | Refuses flags covering a whole sentence |
| Must contain kanji, katakana or alphanumerics | A reader can do nothing with a flagged particle |
| The same word must appear twice | A single mention is the model's whim. **Agreement is judged on the word alone**, because the candidate changes every time and requiring it to match would erase stable findings too |

### This ranks; it does not detect presence

**Even a passage with no errors yields one flag.** Stage two always picks one, and offering "none of these" as an option went unused in measurement.

The property cannot be removed, so the app does not pretend otherwise. The export states up front that a flag is not evidence of an error, and the interface presents them as prompts to check rather than proof. The test expectation is likewise **not zero but "at most one per span"**; expecting zero would contradict the model's nature and eventually force the expectation to be loosened instead.

Measured on five lines drawn from real 11-minute data plus three clean lines:

| | Before | After |
|---|---|---|
| Five lines with errors | 0 findings (not working) | **1 finding, correct** (気象) |
| Intermediate build | 4 findings, 1 correct | — |
| Three clean lines | 2 false flags | 1 false flag |

Some are still missed: 一気通関 to 一気通貫 is not caught, giving a recall of one in two.

### A longer prompt made it less accurate

The length of the instructions determined the hit rate. **The number of fields to return did not.**

| Instructions | Also ask for a candidate | Caught 気象? |
|---|---|---|
| Long (procedure, two examples, four rules) | yes | no (評価/目標/提出) |
| Long | no | no (評価/振り返り/提出) |
| **Short (three lines)** | yes | **yes** (both runs) |
| **Short** | no | **yes** (both runs) |

The examples in the long version were 異常 to 以上 and 時事録 to 議事録, both **two-character compounds differing by one character**. The model began hunting for words matching that shape, which narrowed the search instead of widening it. **Examples do not help by being added.** There are none now.

Earlier still, the example was 気象 to 期初, which was **the verification data itself**. The answer had been given before the same input was submitted, so **passing would have proved nothing**. If examples are used, keep them independent of the verification data.

Verify with:

```bash
xcodebuild -project Utsushi.xcodeproj -scheme Utsushi \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:UtsushiTests/PlausibilityRealModelTests test
```

The tests separate "the model never ran" from "it ran and missed": the former skips, the latter fails. Both produce zero findings and look identical, and without the distinction an environment problem reads as a product problem. That happened once.

## Summaries

`Sources/UtsushiCore/Summary/`. The model returns only a line number, a headline of at most 30 characters, and a category. The type has no field for body text; the body of a summary is quoted directly from the transcript.

The headline is the one thing the model writes, so `SummaryGate` verifies it against different conditions, since a summary is a paraphrase and the reading check used in proofreading does not apply:

- A headline containing a **number** absent from the quotation is rejected. Half-width, full-width and kanji numerals normalize to the same value, so rewriting 二十名 as 20名 passes.
- A headline containing an **alphanumeric token** absent from the quotation is rejected.
- A headline containing a **katakana word** of three or more characters absent from the quotation is rejected.
- Over 40 or under 2 characters is rejected.

When rejected, the point itself is kept and only the headline is replaced by a mechanical extract from the start of the source line. Both the interface and the export state which kind of headline is shown. A point referring to a nonexistent line number is discarded entirely, because a point without a quotation is the model writing prose.

Long recordings are split to fit the Foundation Models context window (8,192 tokens, roughly 10,000 Japanese characters), 3,000 characters per chunk by default.

## Saved settings

The model, cross-check engines and thresholds are stored in `~/Library/Application Support/Utsushi/settings.json` and restored on the next launch. If the model catalog has changed in the meantime, IDs that no longer exist are dropped on load, so a selection never silently does nothing.

Conversion from settings to pipeline configuration passes through the single function `SessionSettings.makeConfiguration`. When settings were held separately in the interface, a bug appeared where an option was visible on screen but never passed through; the structure now makes that impossible.

## Requirements

- macOS 26 or later (for Foundation Models and SpeechAnalyzer)
- Apple Silicon
- **Apple Intelligence must be enabled** for three features: proofreading, judging disagreements, and flagging words that look out of place. Without it, **transcription, the silence gate, repetition detection, automatic re-recognition, cross-checking and export all still work.** Cross-checking is deterministic up to listing the disagreements; only deciding which side is right uses a model.

## Setup

```bash
brew install cmake xcodegen
script/bootstrap.sh          # fetch and build whisper.cpp, generate the Xcode project
vendor/build_sherpa.sh       # build the cross-check engines (sherpa-onnx v1.13.4, static)
script/build_and_run.sh verify
script/build_and_run.sh test
```

### Production-size verification (over two hours)

**It is part of `script/build_and_run.sh test`,** but it needs material, which is not committed to the repository.

Place `fixtures/long-production.m4a` and no environment variable is needed. With no real recording to hand, concatenate the 11-minute fixture:

```bash
for i in $(seq 1 11); do echo "file '$PWD/fixtures/testclip.m4a'"; done > /tmp/l.txt
ffmpeg -f concat -safe 0 -i /tmp/l.txt -c copy fixtures/long-production.m4a
script/build_and_run.sh test
```

To use material elsewhere, name it explicitly:

```bash
UTSUSHI_PRODUCTION_MEDIA=/absolute/path/to/recording.mov xcodegen generate
script/build_and_run.sh test
```

Xcode's test runner does not inherit environment variables from the calling shell, so XcodeGen passes the path into the test scheme.

**A path given explicitly fails if the file is missing; the default path skips.** Skipping the former would let a typo pass as a completed run. The default path exists at all because, when the check relied on the environment variable alone, running `xcodegen generate` without material **silently skipped it**, and this verification went unexecuted across four commits. A skip looks exactly like a success.

Subcommands of `script/build_and_run.sh`:

| | |
|---|---|
| `build` / `run` | Debug build, launch |
| `verify` | Build, launch, and confirm the process is actually alive |
| `test` | All tests, including those using real audio and real models (the first run downloads models) |
| `release` | Release build |
| `install` | Release build, installed into `/Applications` |
| `dist` | Build a `.dmg` for distribution |
| `icon` | Redraw the icon (`script/make_icon.py`) |
| `logs` | Launch and attach `log stream` |
| `clean` | Remove `build/` and the generated xcodeproj |

`vendor/build_sherpa.sh` pins a tag for reproducibility, which has a real cost: master pins onnxruntime 1.27.1, but upstream replaced that release asset, so configure fails on a hash mismatch. v1.13.4, which pins 1.27.0, works.

Speech models (large-v3-turbo at 1.6 GB, cross-check engines from 160 MB to 1.0 GB) are not bundled into the `.app`; they download to `~/Library/Application Support/Utsushi/Models` on first use. Which models are missing and how much will be fetched is shown before you press start. Files whose size does not match the expected value are discarded, so a truncated download is never used. Files live at `Models/<model id>/<filename>`, and the older flat layout is still readable, so updating never re-fetches 1.6 GB.

## Distribution

`project.yml` enables Hardened Runtime and sets entitlements (sandbox, user-selected file access, network) from the outset. Signing is ad-hoc (`-`). To distribute under a Developer ID, replace `CODE_SIGN_IDENTITY` and `DEVELOPMENT_TEAM` and submit for notarization. whisper.cpp is statically linked, so no additional dylib needs signing and `disable-library-validation` is unnecessary.

`script/build_and_run.sh dist` produces a `.dmg`, but **it remains ad-hoc signed and Gatekeeper will block it on another Mac**. The recipient must right-click and choose Open once in Finder. Removing that requires a Developer ID certificate and notarization through the paid Apple Developer Program, which this repository does not cover. Installing on your own Mac with `install` avoids the issue.

## License

The app itself is under the MIT License (`LICENSE`). © 2026 RTCK

Everything fetched or linked at run time follows its own license:

| | License |
|---|---|
| whisper.cpp | MIT |
| sherpa-onnx / onnxruntime | Apache-2.0 |
| whisper large-v3-turbo | MIT |
| ReazonSpeech k2-v2 | Apache-2.0 |
| SenseVoice-Small (FunASR / Alibaba) | Apache-2.0 |
| Qwen3-ASR (Alibaba) | Apache-2.0 |
| NVIDIA parakeet-tdt_ctc-0.6b-ja | **CC BY 4.0 (attribution required)** |

When parakeet is used for cross-checking, the attribution is added automatically to the exported Markdown.
