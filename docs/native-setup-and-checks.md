# Native setup and verification

Varta targets Apple Silicon/macOS 14+. The source uses whisper.cpp/Metal for speech
and local MLX Llama 3.1 8B Instruct 4-bit for generation/translation. Silero VAD
through the same pinned Whisper framework filters speech before transcription. Model weights
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
embeds a dynamic framework when required. Preparation also generates exact input/
output file lists for Xcode's script sandbox; keep them beside the configuration.
Sandbox/signing settings remain intact. An absent placeholder does not supply a
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

Choose an existing Whisper ggml-large-v3-q5_0.bin, the pinned Silero v6.2.0 VAD file and a local MLX
Meta-Llama-3.1-8B-Instruct-4bit directory in Settings. The Llama directory needs
config.json, tokenizer.json, tokenizer_config.json and non-empty safetensors.
Obtain weights under their applicable licences/access terms; Varta does not
download them automatically. Local directory loading keeps tokenizer/weights offline.
VAD requires exactly 885,098 bytes with SHA-256
2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987;
Settings validates that checksum. Default VAD location is
Models/vad/ggml-silero-v6.2.0.bin. [VAD stage and asset provenance](voice-activity-stage-and-assets.md)
describes the MIT model and immutable publisher revision.

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
   Run python3 Native/prepare-vad-fixtures.py --self-test for bounded fixture preparation checks.
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
accuracy or real permission flows. CI downloads only the small pinned MIT Silero
model and official pinned speech fixture, verifies checksums/model headers/native
exports, and executes real VAD silence/speech/mixed cases. It downloads no Whisper
ASR or MLX Llama weights. VAD fixture preparation refuses downloads outside CI.
CI also enables mandatory module compile guards: missing Whisper/MLX imports fail
the build instead of exercising an unavailable-engine fallback.

## Recovery and safety

Transcription checkpoints store completed windows and accumulated segments; the
previous transcript remains until atomic completion. Reviewed/locked transcripts
cannot be replaced. Source IDs, language and transcript revision must match on
resume. VAD model/policy and Whisper metadata identity must also match; older
checkpoints without those identities require a fresh job. Prepared WAVs must belong
to the meeting and retain their contiguous original frame timeline. Completed recording chunks remain registered and recoverable; a crash can
lose the latest unfinished chunk. Capture resumes only after an explicit user action.
Source choices are checkpointed before capture starts. A recovered legacy session
with unknown sources stays paused until at least one source is selected. Successful
manual and duration-limit stops publish the saved meeting once to Home; the selected
detail refreshes appended media without replacing its transcript editor state.

Incremental ASR derives rolling prompt text from the current job's validated
checkpoint. Its Unicode-normalised tail is bounded to 1,024 characters / 4,096
UTF-8 bytes; the native decoder limits carried text context to 224 tokens and uses
temperature zero. Four consecutive cycles of a 3–32-word phrase trigger one clean
retry without prompt context. A persistent loop or invalid retry fails before
advancing the window checkpoint; previous transcript and completed windows remain.
These deterministic safeguards require bilingual/noisy-speech quality calibration.
Genuine Silero detection precedes ASR. Quiet windows advance without Whisper
decoding; an all-quiet job completes while preserving prior transcript/outputs and
original audio. Speech spans decode directly from original-buffer ranges and retain
original offsets. Native probability coverage must be complete before silence is
accepted. Cancellation is checked between native VAD calls; the pinned VAD API has
no mid-call abort callback. Speech/noise/code-switching calibration remains separate
from fixture execution.

Summary regeneration invalidates previous translations. English remains canonical;
translation never back-translates over it. Calendar reservation checks current source
revision and candidate identity. A save whose outcome is uncertain retains its receipt,
blocking automatic duplicates; inspect Calendar manually before any further action.

Distribution signing/notarisation, physical validation and bilingual quality gates
remain separate from compilation/fixture results.
