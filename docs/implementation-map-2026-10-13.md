# Varta remaining implementation map — 13 October 2026

The existing brief requires the local loop: import/record → transcribe → review →
summarise → translate → review/create an Apple Calendar event. Implementation
continues on `codex/varta-readiness-2026-10-12`, retaining draft PR #1 and all
pre-existing local changes. No post-MVP adapter is included.

| Required slice | Owning components and callers | Acceptance evidence |
|---|---|---|
| Native models | Model manifest/config validation; `WhisperCppBridge`; local MLX client; `MemoryManager`; Xcode dependency/framework wiring | Missing/corrupt assets fail explicitly; native bindings use declared engines; no fabricated fallback; exclusive loading and release; native inference checks queued |
| Complete import/transcription | Disk-streamed AVFoundation conversion to 16 kHz mono WAV windows; `ImportPipelineService`; `TranscriptionService`; storage/jobs/checkpoints; meeting detail generation | Synthetic media conversion tests; all windows included with absolute timestamps; checkpoint resume; reviewed segments preserved on failure |
| Generated meeting content | Prompt templates, `SummariserService`, `TranslationService`, transactional output storage, summary/output/translation tabs | Injected generator verifies 10-minute/30-minute/final orchestration and source context; malformed model output cannot overwrite existing content; real bilingual quality check queued |
| Review and filing | Transcript playback/seek, language mode/glossary/prompt settings, FTS query/results, EventKit candidate review and explicit creation, permissions UI | Focused parsing/search/storage tests; event creation occurs only after user confirmation; live permissions/UI checks queued |
| Recording/recovery | Source/segment timing metadata, combined processing timeline, durable capture chunks, recorder persistence error handling, interrupted-job recovery | Fixture timelines/checkpoints and failure-path tests; physical mixing, sleep/wake and four-hour checks queued |

## Code work versus external prerequisites

Native adapters, dependency declarations, model validation, media processing,
orchestration, storage/checkpoints and the required UI can be implemented now.
Missing engines must not remain permanent throw-only stubs, and model assets must
not be confused with missing application code.

External prerequisites: a valid whisper.cpp Apple framework, local quantised
Whisper/Llama model assets (including tokenizer/configuration), appropriate model
licence/access, host capacity for dependency resolution/builds/inference, unlocked
desktop and granted permissions for native UI/capture/Calendar verification, human
bilingual benchmark labels and signing credentials for distribution.

No build, model download, inference, Docker process, UI session or endurance capture
will be launched while the reported host capacity constraint remains. Tests and
builds authored during this continuation are queued, not passing evidence. Earlier
12 October compilation evidence applies only to commit `4f05ade`, not subsequent
source changes.

## Implemented source and review

The five slices above now have connected source implementations. Real Whisper/MLX
adapters replace synthetic production output. Audio conversion and playback combine
all sources/chunks; transcript completion is atomic and resumable. Summary windows
and sections have durable checkpoints with transcript/prompt/glossary fingerprints.
Generated content and job completion commit together; translations preserve English.
Meeting controls, local asset/prompt/glossary settings, FTS and reviewed EventKit
creation are wired.

Bounded independent reviews found and corrected queued-job cancellation, stale
Calendar reservations, legacy optional recovery flags, structured prompt upgrade
contracts and excessive composition track counts. Recording duration accounting was
also reviewed against PCM sample timing. These are source findings, not physical
capture proof.

Framework preparation has 22 passing Python fixtures. Swift syntax parsing,
project references and whitespace checks pass. Native XCTest fixtures are authored;
their execution and native type/link checks await the public macOS CI run. Actual
model quality, physical permissions/capture, four-hour measurements and signed
distribution remain explicit external gates.
