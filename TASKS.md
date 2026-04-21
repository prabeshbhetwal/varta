# TASKS.md — Varta Build Checklist

Track every phase here. Mark items `[x]` when done. Do not skip items or mark done prematurely.

---

## Phase 0 — Skeleton

- [ ] Initialise Xcode workspace with macOS 14 target, Apple Silicon only
- [ ] Enable strict Swift concurrency (`-strict-concurrency=complete`)
- [ ] Add GRDB Swift package dependency
- [ ] Create `StorageService` with GRDB connection
- [ ] Write migration 001: create all core tables (`meetings`, `audio_files`, `transcript_segments`, `summaries`, `generated_outputs`, `glossary_terms`, `jobs`, `processing_state`, `settings`, `calendar_links`)
- [ ] Write migration 002: create FTS5 virtual table shadowing `transcript_segments.text` and meetings title
- [ ] Write migration 003: create optional `diarization_segments` table
- [ ] Implement permission flow: Microphone (AVFoundation)
- [ ] Implement permission flow: Screen Recording (ScreenCaptureKit)
- [ ] Implement permission flow: Calendars (EventKit)
- [ ] Build onboarding view with Screen Recording permission explanation
- [ ] Build Settings shell (navigable, values persisted to `settings` table)
- [ ] Confirm `xcodebuild build` exits 0
- [ ] Confirm migrations apply cleanly on fresh install

---

## Phase 1 — Local import proof

- [ ] Build file import sheet (accepts audio and video formats via NSOpenPanel)
- [ ] Extract audio from imported file using AVAsset; write 16 kHz mono WAV
- [ ] Integrate whisper.cpp as xcframework with Metal backend
- [ ] Implement `TranscriptionService`: process WAV in windows, emit `TranscriptSegment` records
- [ ] Persist segments to `transcript_segments` table with timestamps and language tag
- [ ] Build transcript viewer (virtualised list, click-to-seek)
- [ ] Build transcript correction UI (edit field per segment, lock toggle)
- [ ] Implement glossary table UI (add/edit/delete terms)
- [ ] Apply glossary replacements to transcript segments before summarisation
- [ ] Integrate MLX Swift LM (Llama 3.1 8B) via `MemoryManager`
- [ ] Implement `SummariserService` with hierarchical Map-Reduce
- [ ] Generate: concise summary, detailed summary, bullet summary
- [ ] Generate: action items, decisions, unresolved questions
- [ ] Generate: follow-up email draft
- [ ] Generate: calendar event candidates
- [ ] Implement `TranslationService` (EN↔NE via local LLM prompt path)
- [ ] Copy prompt templates to Application Support on first launch
- [ ] Expose prompt files as user-editable in Settings
- [ ] Unit tests: glossary replacement, language tagging, transcript correction locking
- [ ] Integration test: import file → transcript → summary → translation

---

## Phase 2 — Native recording

- [ ] Implement `RecorderCoordinator` actor: start, pause, resume, stop
- [ ] ScreenCaptureKit system audio capture (no video)
- [ ] AVFoundation microphone capture
- [ ] Audio mixing node (combined path)
- [ ] Disk-streamed write via `AVAssetWriter` (M4A/AAC)
- [ ] Cap in-memory audio buffer to a few seconds maximum
- [ ] Recording controls UI (record button, pause, stop, status indicator)
- [ ] Wire transcript checkpointing: commit segments to SQLite every N minutes
- [ ] Implement `JobQueue` and `Checkpointer` actors
- [ ] Persist `ProcessingState` per job for resume capability
- [ ] Subscribe to `ProcessInfo.thermalState`; reduce concurrency on `.serious`; pause heavy processing on `.critical`
- [ ] Subscribe to power state; reduce concurrency on battery
- [ ] Handle sleep / lid-close: flush writer, checkpoint, pause queued jobs
- [ ] Handle wake: resume jobs from last checkpoint
- [ ] Test: 4-hour recording completes without crash or data loss
- [ ] Test: lid-close mid-session → wake → processing resumes
- [ ] Test: thermal critical → heavy processing pauses, recording continues
- [ ] Unit test: checkpoint logic, MemoryManager lifecycle transitions

---

## Phase 3 — Meeting detail completion

- [ ] Meeting detail navigation with tabs: Summary, Transcript, Translation, Outputs, Calendar
- [ ] Summary tab: concise, detailed, bullet, action items, decisions, unresolved questions, follow-up email
- [ ] Transcript tab: virtualised list, seek, correction, language pill, speaker pill
- [ ] Translation tab: EN/NE toggle for all outputs
- [ ] Outputs tab: structured content export view
- [ ] Calendar tab: display extracted event candidates
- [ ] Calendar review sheet: candidate detail, confirm / dismiss
- [ ] EventKit event creation from confirmed candidate
- [ ] Store `calendar_links` record after creation
- [ ] FTS keyword search across `transcript_segments` and meeting titles
- [ ] Search view: results list linking to meeting + segment
- [ ] Integration test: FTS returns correct results
- [ ] Integration test: calendar event created in Apple Calendar from candidate

---

## Phase 4 — Optional diarisation

- [ ] Set up Python 3.11 embedded environment for varta-worker
- [ ] Install pyannote.audio in worker virtual environment
- [ ] Implement worker `worker.py`: reads JSON from stdin, runs diarisation, writes JSON to stdout, exits
- [ ] Define JSON IPC schema (input: audio path; output: list of `{speaker, start, end}` segments)
- [ ] Implement Swift `DiarisationClient`: spawn worker as child process, write JSON, read response, terminate
- [ ] Handle worker launch failure gracefully (log, continue without speaker labels)
- [ ] Handle worker timeout gracefully (kill process, continue)
- [ ] Implement merge logic: overlap-based matching of diarisation to transcript segments
- [ ] Flag ambiguous merges for UI review
- [ ] Persist results to `diarization_segments` table
- [ ] Show speaker pill on transcript segments when available
- [ ] Show "Speaker separation unavailable" indicator when worker failed
- [ ] Integration test: worker runs → segments labelled
- [ ] Integration test: worker crash → transcription + summary still complete
- [ ] Confirm all Phase 0–3 tests still pass

---

## Post-MVP (do not start until all MVP phases are done and reviewed)

- [ ] Google Drive upload
- [ ] Google Calendar sync
- [ ] Semantic search / embeddings
- [ ] Meeting chat (RAG)
- [ ] Live-caption HUD
- [ ] Menu bar mini-app
- [ ] Spotlight indexing
- [ ] Shortcuts.app support
- [ ] URL scheme
- [ ] Auto-recording from calendar triggers
- [ ] Exports (Obsidian, Notion, Apple Notes)
