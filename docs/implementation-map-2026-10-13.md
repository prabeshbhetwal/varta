# Varta remaining implementation map — 13 October 2026

The existing brief requires the local loop: import/record → transcribe → review →
summarise → translate → review/create an Apple Calendar event. Implementation
continues on `codex/varta-readiness-2026-10-12`, retaining PR #1 and all
pre-existing local changes. No post-MVP adapter is included.

| Required slice | Owning components and callers | Acceptance evidence |
|---|---|---|
| Native models | Model manifest/config validation; `WhisperCppBridge`; local MLX client; `MemoryManager`; Xcode dependency/framework wiring | Missing/corrupt assets fail explicitly; native bindings use declared engines; no fabricated fallback; exclusive loading and release; native inference checks queued |
| Complete import/transcription | Disk-streamed AVFoundation conversion to 16 kHz mono WAV windows; genuine Silero VAD; original-buffer speech crops; `TranscriptionService`; storage/jobs/checkpoints; meeting detail generation | Silence/speech/mixed VAD fixtures; absolute offsets; model/policy and original-window resume identity; prior content preserved on silence/failure |
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

No local heavy build, model download, inference, Docker process, UI session or
endurance capture will be launched while the reported host capacity constraint
remains. The public standard macOS workflow runs the native fixtures without model
weights. Verification follows the exact pushed commit's check; historical green
builds do not validate later source changes.

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

Follow-up source review adds initial recording-source checkpoints and source-free
resume rejection, shared exactly-once completion notifications, same-selected
meeting media/playback refresh with stable transcript editor identity, and playback
lifecycle guards. Incremental ASR now carries a bounded prompt tail from validated
job checkpoints, detects conservative repetition loops and retries once without
context. Deterministic regressions cover these paths; real speech quality and
rendered editor interaction remain separate acceptance checks.

Silero VAD now precedes ASR through the pinned native framework. Quiet windows skip
Whisper; successful all-quiet jobs retain prior transcript/outputs/audio and complete
with an explicit diagnostic. Speech spans retain original sample positions. VAD
model/policy and Whisper metadata identities are frozen in checkpoints; legacy or
changed identities reject Resume. Prepared windows remain meeting-owned and frame
contiguous, with their actual WAV length/format checked. Completion rechecks source
IDs and transcript revision inside one transaction.

Framework preparation includes 29 Python fixtures. Native XCTest covers synthetic
audio conversion, injected model orchestration, storage/recovery and Calendar
failure paths. CI requires real Whisper/MLX module compilation, explicit Whisper
linking and dynamic framework embedding. A separate runner-only fixture helper has
five offline checks and verifies the small VAD model, speech fixture, model header
and 13 native exports before real VAD tests. Consult PR #1's exact-head check for
executed results. Actual model quality, physical permissions/capture, four-hour
measurements and signed distribution remain explicit external gates.
