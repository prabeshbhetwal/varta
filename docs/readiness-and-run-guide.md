# Varta development build

Varta is a local macOS meeting assistant under verification. The code now connects
import/recording, Whisper transcription, transcript review, local MLX generation,
translation and reviewed Calendar creation. Native tests and real model/hardware
checks must establish readiness; implementation alone is not passing evidence.

## Current boundary

- Real whisper.cpp/Metal and MLX Swift LM adapters require valid local assets.
  Missing engines, weights or invalid model responses fail explicitly.
- Media conversion streams 16 kHz mono WAV windows. Processing and playback combine
  all recording chunks and sources on their stored timeline.
- Genuine Silero VAD identifies speech before ASR; quiet windows preserve the
  original timeline. All-quiet completion retains prior content and reports no speech.
- Summary/translation, playback/seek, FTS search and reviewed Calendar controls are
  wired. Generated content commits atomically; transcript edits invalidate stale output.
- Finalised recording chunks and transcription windows have durable checkpoints.
  The latest open AAC chunk may be unrecoverable after abrupt termination. Physical
  capture, timing calibration, four-hour endurance and optional diarisation remain
  external checks or optional work.

Authoritative scope: [blueprint](https://github.com/prabeshbhetwal/varta/blob/c5d3d66/Varta-blueprint.md),
[MVP specification](https://github.com/prabeshbhetwal/varta/blob/c5d3d66/MVP-build-spec.md) and
[agent guide](https://github.com/prabeshbhetwal/varta/blob/c5d3d66/AGENTS.md).
The local checkout has byte-identical briefs under `Project Brief/`; that existing
relocation is outside this remediation commit. The earlier briefs describe intended
behaviour; an unchecked task list and a compiling build do not establish completion.

## Requirements

Apple Silicon Mac, macOS 14 or later, full Xcode selected with `xcode-select`,
internet access for Swift dependencies, prepared whisper.cpp Apple framework and
local model assets. No cloud provider, API key, Docker service or paid account is
required. See [native setup and checks](native-setup-and-checks.md) before building.

Run every command below from:

```text
/Users/prabeshbhetwal/Desktop/Files/Development/Project/Varta
```

Build:

```bash
xcodebuild -workspace Varta.xcworkspace -scheme Varta \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .audit/DerivedData -jobs 2 build
```

Run with isolated demo data, without opening personal Varta records:

```bash
VARTA_DATA_DIRECTORY="$PWD/.audit/demo-data" \
  .audit/DerivedData/Build/Products/Debug/Varta.app/Contents/MacOS/Varta
```

`VARTA_DATA_DIRECTORY` must be an absolute folder path. With this override, the
database is `demo-data/varta.sqlite` and companion media/prompts are under
`demo-data/varta.files/`. Without the override, normal app data remains under
`~/Library/Application Support/Varta/`.

1. Continue onboarding; permissions may be requested when needed.
2. Use **Import** (Command-I) with synthetic audio, or choose **Audio Sources** and
   record a consenting test session. Stop finalises the captured audio.
3. Select a meeting. Choose language, transcribe, review corrections/locks, generate
   content, then translate if needed. Settings requires local Whisper, Silero VAD
   and MLX assets. Playback supports seeking to transcript rows.
   Calendar suggestions require reviewed title, date, duration and explicit creation.

Settings are available through the standard app Settings menu. System audio
requires macOS Screen Recording permission; microphone capture requires Microphone
permission. Permission prompts and live capture are not part of automated tests.

Stop a recording before quitting with Command-Q. Varta has no background web
server. On restart, interrupted jobs become paused; use explicit recovery/resume
controls. Abrupt termination can invalidate the latest open AAC chunk. Retain source
audio until native capture and recovery checks pass.

## Tests

```bash
TEST_RUNNER_VARTA_TESTING=1 xcodebuild -workspace Varta.xcworkspace \
  -scheme VartaTests -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .audit/DerivedData -jobs 2 test
```

The shared test scheme sets `VARTA_TESTING=1` so the app test host does not bootstrap
personal storage. Tests use unique temporary databases; explicit database URLs
also isolate companion media/prompts into a sibling `.files` directory.

The import test uses a real synthetic WAV and an injected transcript fixture. It
checks storage/service wiring, not transcription accuracy. The crash-recovery test
checks checkpoint metadata after reopening SQLite; it does not kill and recover a
live recorder. Synthetic PCM tests exercise the native AAC writer without audio
devices. No English/Nepali model-quality result is implied.

## Data safety and release gate

Reviewed or locked transcripts cannot be regenerated over. Duplicate imports get
unique filenames. Failed recordings are retained for inspection. The internal
meeting-removal service archives audio folders under `_trash/<meeting-id>/<uuid>/`
before removing database rows; it is not exposed in the current UI. Archived audio
is recoverable manually; deleted transcript/database rows have no restore UI.

Generated build/test caches and workstation metadata are ignored for new files.
Existing tracked metadata remains in history; do not rewrite history or remove
existing local work without approval. Never commit personal audio or model weights.

Distribution remains blocked: signing is disabled, no development team is set,
required real inference, end-to-end and hardware checks are
missing. There is no signed or notarised release from this audit.
