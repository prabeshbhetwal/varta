# MVP Build Specification — Varta

**Version:** v3 (aligned with Varta-blueprint-v3.md)  
**Status:** Frozen. Do not expand scope without explicit approval.  
**Platform:** macOS 14+, Apple Silicon only.

---

## 1. What MVP means for Varta

The MVP is the smallest functional loop that is genuinely useful as a personal meeting tool:

- Record or import → transcribe → review → summarise → translate → file to calendar

Everything beyond that loop is post-MVP. This spec is the authoritative boundary.

---

## 2. In-scope capabilities

| # | Capability | Acceptance Criteria |
|---|---|---|
| 1 | Import audio/video file | File picker accepts common formats; audio extracted and stored |
| 2 | Native mic recording | Starts within 1.5 s; streams to disk; stops cleanly |
| 3 | Native system audio recording | Requires Screen Recording permission; mixed with mic |
| 4 | whisper.cpp transcription | Produces timestamped segments; Metal backend active |
| 5 | Transcript viewer with seek | Click segment → audio seeks to that timestamp |
| 6 | Transcript correction | Edit segment text; lock corrected segments; raw text preserved |
| 7 | Language mode: EN only | Transcription forced to English |
| 8 | Language mode: NE only | Transcription forced to Nepali |
| 9 | Language mode: mixed/auto | Per-segment language tagging |
| 10 | Glossary table | Terms defined; replacements applied to transcript and outputs |
| 11 | Local AI summary (MLX Swift LM) | Concise + detailed + bullet summary generated on-device |
| 12 | Action items extraction | Structured list extracted from transcript |
| 13 | Decisions extraction | Structured list extracted from transcript |
| 14 | Unresolved questions extraction | Structured list extracted from transcript |
| 15 | Follow-up email generation | Draft email from meeting outputs |
| 16 | EN↔NE translation of outputs | Summaries and structured outputs translatable |
| 17 | SQLite + local file storage | All data in `~/Library/Application Support/Varta/` |
| 18 | FTS keyword search | Search across transcript segments and meeting titles |
| 19 | Apple Calendar event suggestion | Candidates extracted and shown for review |
| 20 | Apple Calendar manual creation | User confirms and EventKit creates the event |
| 21 | 4-hour continuous recording | No crashes; disk-streamed; checkpointed |
| 22 | Hierarchical Map-Reduce summarisation | 10-min windows → 30-min sections → final synthesis |
| 23 | Resumable processing | Crash → relaunch → processing continues from last checkpoint |
| 24 | Optional diarisation (non-blocking) | Worker failure → app still completes all steps above |
| 25 | Onboarding and permission flow | Mic, Screen Recording, Calendar permissions explained and requested |

---

## 3. Out-of-scope (must not build in first pass)

| Capability | Reason deferred |
|---|---|
| Google Drive upload | OAuth + cloud complexity, post-MVP |
| Google Calendar sync | OAuth + event mapping complexity, post-MVP |
| Semantic search / embeddings | Different architecture layer, post-MVP |
| Meeting chat / RAG | Depends on embeddings, post-MVP |
| Cloud API adapters | No cloud in MVP |
| Live-caption HUD | Separate surface, post-MVP |
| Menu bar mini-app | State sync complexity, post-MVP |
| Spotlight indexing | CoreSpotlight integration, post-MVP |
| Shortcuts.app | Intents framework, post-MVP |
| URL scheme | External surface, post-MVP |
| Auto-recording from calendar | Calendar trigger logic, post-MVP |
| Obsidian / Notion / Notes export | External integrations, post-MVP |
| Voice-based speaker labelling | Separate ML problem, post-MVP |

---

## 4. Build phases

### Phase 0 — Skeleton
**Goal:** Working Xcode project. Storage runs. Migrations apply. Permissions requested.

Deliverables:
- Xcode workspace initialised, strict concurrency on
- GRDB set up; all core tables and migrations
- Permission flow for Microphone, Screen Recording, Calendar
- Settings shell (UI navigable, values persisted)
- App launches without crash on clean install

Done when: `xcodebuild build` succeeds; migrations apply on first launch; all three permission dialogs appear correctly.

---

### Phase 1 — Local import proof
**Goal:** Import a file, get a transcript and a summary. The core value loop works.

Deliverables:
- File import sheet (audio + video)
- whisper.cpp integration (Metal backend, large-v3 quantised)
- Transcript segment storage and viewer
- Transcript correction and lock UI
- MLX Swift LM integration (Llama 3.1 8B)
- Local summarisation (concise, detailed, bullet, action items, decisions)
- Glossary table and replacement logic
- Translation of outputs (EN↔NE via local LLM)
- Editable prompt templates under `Resources/Prompts/`

Done when: import an audio file → transcript appears → summary and action items generated → translation works.

---

### Phase 2 — Native recording
**Goal:** Record mic and system audio reliably for up to 4 hours.

Deliverables:
- RecorderCoordinator actor (start, pause, resume, stop)
- ScreenCaptureKit system audio capture
- AVFoundation microphone capture
- Audio mixing node
- Disk-streamed write via AVAssetWriter (M4A archive)
- In-memory buffer tightly capped
- 4-hour session with no crash or data loss
- Checkpoint every N minutes of transcription
- Thermal state hooks (fair / serious / critical)
- Power state hooks (battery vs AC)
- Sleep / lid-close flush and resume

Done when: 4-hour recording completes without crash; lid-close mid-session resumes cleanly on wake; thermal test shows concurrency reduction on critical state.

---

### Phase 3 — Meeting detail completion
**Goal:** Full meeting detail UI. Calendar and search working.

Deliverables:
- Meeting detail tabs: Summary, Transcript, Translation, Outputs, Calendar
- Follow-up email output
- Unresolved questions output
- Apple Calendar candidate extraction
- Calendar review sheet (candidates displayed for confirmation)
- EventKit event creation and local link stored
- FTS keyword search across meetings
- Search view (results link to meeting + segment)

Done when: search finds a transcript segment; calendar event created in Apple Calendar from a candidate; outputs tab shows all structured content.

---

### Phase 4 — Optional diarisation
**Goal:** Speaker separation layer added without breaking anything.

Deliverables:
- varta-worker Python package (pyannote.audio)
- JSON-over-stdio IPC protocol
- Swift caller that spawns worker, reads result, exits worker
- Merge logic: diarisation segments overlaid on transcript segments
- Graceful failure path: if worker fails, app continues without speaker labels
- UI indicator when speaker separation is unavailable

Done when: diarisation worker runs and labels segments; worker crash does not block transcription or summarisation; all Phase 0–3 tests still pass.

---

## 5. Performance bands

| Scenario | Minimum Acceptable | Target | Stretch |
|---|---:|---:|---:|
| Cold app launch | < 3.0 s | < 1.5 s | < 1.0 s |
| Recording start | < 1.5 s | < 0.8 s | < 0.5 s |
| 30-min English → transcript + summary | < 12 min | < 5 min | < 3 min |
| 30-min mixed NE-EN → transcript + summary | < 18 min | < 8 min | < 5 min |
| 4-hour class session → full processing | < 120 min | < 60 min | < 45 min |
| FTS search latency | < 300 ms | < 100 ms | < 50 ms |

These are guidance bands, not hard mathematical promises. An agent may stop once the system is within the minimum acceptable band and functionally correct.

---

## 6. Required database tables

| Table | Notes |
|---|---|
| `meetings` | Core meeting record |
| `audio_files` | Path, format, duration |
| `transcript_segments` | Text, corrected text, language tag, timestamps, speaker label, lock state |
| `summaries` | Concise, detailed, bullet |
| `generated_outputs` | Action items, decisions, questions, email, calendar candidates |
| `glossary_terms` | Term, replacement, language |
| `jobs` | Queue entries with status |
| `processing_state` | Checkpoint data per job |
| `settings` | Key-value app settings |
| `calendar_links` | Meeting UUID → EventKit event identifier |
| `diarization_segments` | Optional; populated only if worker succeeds |

FTS5 virtual table must shadow `transcript_segments.text` and `meetings.title`.

---

## 7. Hard constraints for coding agents

1. Build phases in order. Do not implement Phase 2 before Phase 1 is done.
2. Do not build anything from the out-of-scope list.
3. Do not bypass the MemoryManager — only one model family resident at a time.
4. Audio files are write-once. Never overwrite after finalisation.
5. Prompt strings must come from template files, not hardcoded Swift strings.
6. If diarisation fails, everything else must still work.
7. Stop and report any blocker instead of guessing or expanding scope.
