# Varta development build

Varta is an unfinished, local macOS meeting recorder. The current code can import
media, store recordings and review existing transcripts. It is not yet the AI
meeting assistant described in the product brief.

## Current boundary

- The whisper.cpp framework is a placeholder; model weights are absent. Production
  transcription returns an explicit unavailable error and preserves existing data.
- Summarisation and translation services contain deterministic text heuristics,
  not MLX inference. They are not exposed as completed features.
- Calendar creation, a search screen, audio playback/seek, full-session recovery
  and the optional diarisation worker remain unfinished.
- Microphone and system audio are recorded into separate files. They are not mixed
  into one recording. Four-hour endurance and hardware permission flows require
  separate verification.

Authoritative scope: [blueprint](https://github.com/prabeshbhetwal/varta/blob/c5d3d66/Varta-blueprint.md),
[MVP specification](https://github.com/prabeshbhetwal/varta/blob/c5d3d66/MVP-build-spec.md) and
[agent guide](https://github.com/prabeshbhetwal/varta/blob/c5d3d66/AGENTS.md).
The local checkout has byte-identical briefs under `Project Brief/`; that existing
relocation is outside this remediation commit. The earlier briefs describe intended
behaviour; an unchecked task list and a compiling build do not establish completion.

## Requirements

Apple Silicon Mac, macOS 14 or later, full Xcode selected with `xcode-select`,
internet access for the pinned GRDB Swift package. No cloud provider, API key,
Docker service or paid account is required for this development build.

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
3. Select a meeting. **Show Audio in Finder** exposes its saved audio. Transcript
   generation currently reports unavailable. Existing transcripts support
   corrections, locking, copying and text export.

Settings are available through the standard app Settings menu. System audio
requires macOS Screen Recording permission; microphone capture requires Microphone
permission. Permission prompts and live capture are not part of automated tests.

Stop a recording before quitting with Command-Q. Varta has no background web
server. Abrupt termination can invalidate the current recording segment; automatic
recovery is not implemented. Do not use this build as the sole copy of important
meeting audio.

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
native inference is not integrated and required end-to-end/hardware checks are
missing. There is no signed or notarised release from this audit.
