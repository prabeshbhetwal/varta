# Native setup and verification

Varta targets Apple Silicon/macOS 14+. The source uses whisper.cpp/Metal for speech
and local MLX Llama 3.1 8B Instruct 4-bit for generation/translation. Model weights
are external assets; no app runtime cloud adapter or synthetic fallback is used.

## Engine preparation

The pinned official framework is whisper.cpp v1.8.3:
[release asset](https://github.com/ggml-org/whisper.cpp/releases/download/v1.8.3/whisper-v1.8.3-xcframework.zip),
SHA-256 a970006f256c8e689bc79e73f7fa7ddb8c1ed2703ad43ee48eb545b5bb6de6af.
CI verifies the checksum and confined extraction before selecting its macOS/arm64
slice. The tracked placeholder is preserved.

After obtaining/extracting that framework into a separate local folder, prepare
configuration before opening/building the workspace:

    python3 Native/prepare-whisper.py \
      --xcframework /absolute/path/to/whisper.xcframework \
      --config-output "$PWD/.audit/native/whisper.generated.xcconfig"

The app build includes this generated configuration, explicitly links whisper and
embeds a dynamic framework when required. An absent placeholder does not supply a
native module; native transcription then reports an engine error. Source preparation
never overwrites a divergent existing framework. Use a fresh build output directory
when changing framework versions.

The MLX LM package uses the original official mlx-swift-examples 2.21.2 source at
immutable revision 6ef303b84ec69e2e1e1da68f2059e99ee1dcef4d. The later split repository's
same old tag references directories removed from its history and fails package
resolution; the original package contains them and identical model APIs.
mlx-swift 0.21.2 and swift-transformers 0.1.13 are exact; GRDB retains its existing
major-version requirement.
[MLX API source](https://github.com/ml-explore/mlx-swift-examples/tree/2.21.2) and
[whisper C API](https://github.com/ggml-org/whisper.cpp/blob/v1.8.3/include/whisper.h)
define the adapters.

## Local assets

Choose an existing Whisper ggml-large-v3-q5_0.bin and a local MLX
Meta-Llama-3.1-8B-Instruct-4bit directory in Settings. The Llama directory needs
config.json, tokenizer.json, tokenizer_config.json and non-empty safetensors.
Obtain weights under their applicable licences/access terms; Varta does not
download them automatically. Local directory loading keeps tokenizer/weights offline.

Default paths follow Models/model-manifest.json relative to app companion storage.
An isolated VARTA_DATA_DIRECTORY uses its sibling varta.files root, including Models
and editable Prompts. Missing/empty assets reject inference before replacing content.
Whisper windows are bounded to thirty seconds by the media pipeline; conversion
buffers 4,096 mono frames. Native model memory and hardware performance still need
measurement.

Editable final-summary and calendar-candidates prompts must preserve the JSON
response contracts shown in bundled templates. Existing custom prompts are retained.
Malformed/empty responses and token-limit truncation cannot replace valid content.

## Checks

1. Run python3 Tests/native-framework-tests.py for parser, archive and embedding fixtures.
2. Run native tests using the commands in readiness-and-run-guide.md when host capacity
   permits, with the framework prepared before xcodebuild.
3. Verify import → transcription → reviewed summary → Nepali translation using licensed
   local models and independently labelled English/Nepali/mixed fixtures.
4. Verify live microphone/system capture, pause/resume, crash recovery, sleep/wake,
   playback synchronisation and four-hour memory/disk behaviour on physical hardware.
5. Review a Calendar suggestion and explicitly create one event on an unlocked Mac.

The public-repository native-checks workflow uses standard macos-26 capacity,
bounded timeouts, jobs=2 and serial test execution. Its synthetic fixtures exercise
orchestration, storage, media conversion and Calendar failure paths, not model
accuracy or real permission flows. No model weights are downloaded in CI.
CI also enables mandatory module compile guards: missing Whisper/MLX imports fail
the build instead of exercising an unavailable-engine fallback.

## Recovery and safety

Transcription checkpoints store completed windows and accumulated segments; the
previous transcript remains until atomic completion. Reviewed/locked transcripts
cannot be replaced. Source IDs, language and transcript revision must match on
resume. Completed recording chunks remain registered and recoverable; a crash can
lose the latest unfinished chunk. Capture resumes only after an explicit user action.

Summary regeneration invalidates previous translations. English remains canonical;
translation never back-translates over it. Calendar reservation checks current source
revision and candidate identity. A save whose outcome is uncertain retains its receipt,
blocking automatic duplicates; inspect Calendar manually before any further action.

Distribution signing/notarisation, physical validation and bilingual quality gates
remain separate from compilation/fixture results.
