# Varta — Nepali-Aware, Apple-Silicon-Native AI Meeting Assistant

**Document Type:** Product Requirements Document + Technical Architecture + Build Blueprint (v3)  
**Supersedes:** `Varta-blueprint-v2.md` (v2). v2 is preserved; this document is authoritative.  
**Target Build Agent:** Claude Code / Cowork / OpenAI Codex — any agent capable of reading this blueprint end-to-end and implementing autonomously.  
**Platform:** Native macOS desktop application, Apple Silicon only. Not a web app. Not Electron or Tauri.  
**Primary Owner:** Prabesh Bhetwal (single-user, personal-use).  
**Core Principle:** Native by default. Python only where it wins decisively. Local-first for the MVP. Cloud, sync, semantic search, and advanced assistants are post-MVP layers. Bilingual (English + Nepali + code-switched) is a first-class constraint, not a stretch goal.

---

## 0. Changelog from v2

This document incorporates all agreed refinements made after review of v2, including architecture tightening, MVP scope reduction, diarisation soft-dependency treatment, performance target calibration, and explicit product defaults.

### Major changes from v2

1. **MVP scope is now frozen to the true local core.**  
   Google Drive, Google Calendar sync, semantic search, meeting chat, cloud API adapters, menu bar utility, live-caption HUD, Spotlight, Shortcuts, and other convenience features are explicitly moved out of the MVP and into later phases.

2. **Diarisation is now a soft dependency.**  
   `pyannote.audio` remains the preferred diarisation engine, but diarisation is no longer treated as a load-bearing subsystem. If the Python worker fails, transcription, summaries, transcript review, and calendar suggestion must still complete successfully.

3. **Performance promises are reclassified.**  
   Rigid promises are replaced by three bands:
   - **Minimum acceptable**
   - **Target**
   - **Stretch target**

4. **Resolved defaults are now explicit.**
   - Default local LLM: **Llama 3.1 8B**
   - Live-caption HUD: **Off by default**
   - Calendar event mode: **Review always**
   - Google Drive upload: **Manual trigger by default**
   - Menu bar utility: **Deferred to v2**
   - Icon style: **Minimalist glyph**

5. **ScreenCaptureKit permission friction is now elevated to a first-class onboarding requirement.**  
   The onboarding flow must explain clearly why macOS requires “Screen Recording” permission to capture system audio.

6. **Python worker packaging is explicitly classified as the highest release risk.**  
   The app must remain shippable without diarisation if worker packaging or notarisation becomes unstable.

---

## 1. Executive Summary

Varta is a native macOS application for Apple Silicon that records, transcribes, summarises, translates, and files meetings. It is designed for a bilingual (English + Nepali + mixed) user, runs fully on-device by default, and supports Apple Calendar event suggestion and manual creation as part of the core workflow.

The MVP is intentionally narrow and local:

- Record microphone and/or system audio
- Import audio and video files
- Transcribe with timestamps
- Review and correct the transcript
- Generate local AI summaries, decisions, and action items
- Translate outputs between English and Nepali
- Suggest future calendar events and allow manual Apple Calendar creation
- Store everything locally in SQLite + files
- Gracefully attempt diarisation, without making the app depend on it

The app is designed to handle meeting durations up to **four continuous hours per session**, with disk-streamed capture, resumable processing, and checkpointed summarisation so a crash or lid-close never invalidates the entire job.

The architecture follows three tiers:

| Tier | Path | Role |
|---|---|---|
| Tier 1 — Primary native | SwiftUI + AppKit, ScreenCaptureKit, AVFoundation, whisper.cpp (Metal), MLX Swift LM, EventKit, SQLite/GRDB | Mainline MVP path |
| Tier 2 — Restricted Python fallback | Isolated Python worker, child process over structured JSON/stdio | Optional diarisation, optional NLLB translation |
| Tier 3 — Post-MVP optional adapters | Google Drive, Google Calendar, semantic search, meeting chat, cloud APIs | Later phases only |

The app must ship as a signed, notarised `.app` bundle. No permanent REST service. No Docker. No Electron. No Tauri.

---

## 2. Product Vision

Varta should feel like a cross between a meeting recorder, an AI notepad, a private bilingual meeting memory, and a meeting-to-calendar workflow tool. It should be calm, fast, Apple-native, and trustworthy.

The product prioritises, in this order:

1. **Correctness** — the transcript, summary, and extracted commitments must reflect what was actually said.
2. **Privacy** — audio, transcripts, summaries, and outputs remain on device by default.
3. **Usability** — the user finds what they need within two clicks of opening a meeting.
4. **Reliability** — a crash, lid close, or worker failure must not destroy the entire workflow.
5. **Speed** — processing should be comfortably usable on a 16 GB Apple Silicon Mac.
6. **Convenience** — sync, cloud, and advanced retrieval come later.

If tradeoffs arise, choose in that order.

---

## 3. The True MVP Boundary

This section is authoritative. A coding agent must not quietly expand past this MVP boundary.

### 3.1 In-MVP (must build)

| Capability | MVP Status |
|---|---|
| Import audio/video file → transcript | ✓ |
| Native recording (mic + system audio) | ✓ |
| whisper.cpp transcription with timestamps | ✓ |
| Transcript viewer with playback seek | ✓ |
| Transcript correction with lock state | ✓ |
| Local AI summary (MLX Swift LM) | ✓ |
| Action items extraction | ✓ |
| Decisions extraction | ✓ |
| Concise + detailed summary | ✓ |
| English-only / Nepali-only / mixed mode | ✓ |
| Glossary table and replacement | ✓ |
| EN↔NE translation of outputs | ✓ |
| SQLite + local file storage | ✓ |
| FTS keyword search | ✓ |
| Apple Calendar event suggestion + manual creation | ✓ |
| 4-hour continuous recording with checkpoints | ✓ |
| Hierarchical Map-Reduce summarisation | ✓ |
| Optional diarisation, non-blocking | ✓ |

### 3.2 Explicitly out of MVP (must not build in the first pass)

| Capability | Status |
|---|---|
| Google Drive upload | Post-MVP |
| Google Calendar sync | Post-MVP |
| Semantic search / embeddings | Post-MVP |
| Meeting chat / RAG | Post-MVP |
| Cloud API adapters | Post-MVP |
| Live caption HUD | Post-MVP |
| Menu bar mini app | Post-MVP |
| Spotlight indexing | Post-MVP |
| Shortcuts.app support | Post-MVP |
| URL scheme | Post-MVP |
| Voice-based speaker auto-labelling | Post-MVP |
| Auto-recording from calendar triggers | Post-MVP |
| Obsidian / Notes / Notion export | Post-MVP |

### 3.3 Why the MVP is frozen this way

Autonomous coding agents degrade badly when asked to build too many cross-domain subsystems simultaneously. The local-first core is the correct foundation:

- native audio capture,
- local storage,
- local transcript,
- local summarisation,
- local translation,
- manual calendar creation,
- graceful optional diarisation.

Everything else is an amplifier, not the foundation.

---

## 4. Non-Goals

Do not build these in the MVP.

- Multi-user cloud collaboration
- Web or browser front end
- SaaS subscription or billing
- Enterprise admin console
- Meeting bots that join calls
- CRM integrations
- Public sharing links
- Always-on passive listening
- Windows or Linux support
- Intel Mac support
- Full Google ecosystem integration in MVP
- Agentic cross-meeting retrieval in MVP

---

## 5. Constraints and Assumptions

### 5.1 Platform
- macOS 14 (Sonoma) or later
- Apple Silicon only
- Minimum 16 GB unified memory
- 32 GB recommended for comfortable long-audio + higher-quality local model operation
- SSD with at least 20 GB free for models, audio, and artifacts

### 5.2 Audio
- Maximum continuous recording duration: **4 hours per session**
- Common scenario: English + Nepali mixed speech
- Import path must accept audio and video files

### 5.3 Personal-use assumption
- Single-user local database
- No app login or account system
- OAuth not required in MVP
- Secrets stored in Keychain when later connectors are added

### 5.4 Core behaviour assumption
- If diarisation fails, the product still succeeds
- If translation fallback fails, the original transcript still remains usable
- If summarisation fails, transcript review still remains usable
- If calendar candidate extraction is weak, manual transcript review remains the source of truth

---

## 6. Architectural Principles

These rules are load-bearing.

1. **Native by default.** Swift / C++ / Metal before Python.
2. **One model family resident at a time.** Whisper, local LLM, diarisation worker, translation worker must not co-reside unnecessarily.
3. **Disk-stream everything long.** No 4-hour in-memory audio buffers.
4. **Every stage is resumable.** Recording, transcription, summarisation.
5. **No permanent local REST service.** Spawn-on-demand worker over JSON/stdin/stdout.
6. **Diarisation is non-blocking.** The app must succeed without it.
7. **Cloud is not part of the MVP.**
8. **Correctness outranks speed.**
9. **Usability outranks feature breadth.**
10. **Performance numbers are guidance bands, not rigid mathematical promises.**

---

## 7. High-Level Architecture

### 7.1 Process model

```text
┌──────────────────────────────────────────────────────────────┐
│  Varta.app  (single signed macOS process)                   │
│                                                              │
│  ┌─────────────────────┐   ┌──────────────────────────────┐  │
│  │ UI (SwiftUI +       │   │ Core Services (Swift)       │  │
│  │ AppKit bridges)     │◄─►│ • RecorderCoordinator       │  │
│  │                     │   │ • TranscriptionService      │  │
│  │                     │   │   (whisper.cpp + Metal)     │  │
│  │                     │   │ • SummariserService         │  │
│  │                     │   │   (MLX Swift LM)            │  │
│  │                     │   │ • TranslationService        │  │
│  │                     │   │ • CalendarService           │  │
│  │                     │   │   (EventKit)                │  │
│  │                     │   │ • MemoryManager             │  │
│  │                     │   │ • JobQueue / Checkpointer   │  │
│  │                     │   │ • StorageService            │  │
│  │                     │   │   (GRDB + SQLite + FTS5)    │  │
│  └──────────▲──────────┘   └──────────────┬───────────────┘  │
└─────────────┼─────────────────────────────┼──────────────────┘
              │                             │ spawn on demand
              │                             ▼
              │          ┌──────────────────────────────────┐
              │          │ varta-worker (Python, embedded)  │
              │          │ • pyannote diarisation           │
              │          │ • optional NLLB translation      │
              │          │ Lifetime: single job, then exit  │
              │          └──────────────────────────────────┘
              │
              ▼
   ┌──────────────────────────────┐
   │ Filesystem + SQLite          │
   │ ~/Library/Application        │
   │ Support/Varta/               │
   └──────────────────────────────┘
```

### 7.2 Runtime split

**Swift / native path**
- UI
- permissions
- recording coordination
- file I/O
- transcription
- local summarisation
- local translation orchestration
- Apple Calendar creation
- storage and FTS search
- job queue and checkpointing

**Python worker**
- diarisation
- optional NLLB translation only if selected later in MVP or in a fallback path

### 7.3 Critical classification

The Python worker is not a peer to the native path.  
It is a **contained impurity**.

If the worker:
- fails to launch,
- crashes,
- cannot be signed,
- or cannot be notarised cleanly,

the app must still be able to ship in a functional MVP configuration with diarisation disabled.

---

## 8. Technology Stack

### 8.1 Core stack

| Layer | Choice | Notes |
|---|---|---|
| UI | SwiftUI primary, AppKit bridges only | Native macOS UX |
| Language | Swift 5.10+ | Strict concurrency mode on |
| Audio capture | ScreenCaptureKit + AVFoundation + AVAssetWriter | System audio + mic |
| Transcription | whisper.cpp | Metal acceleration on Apple Silicon |
| Local LLM | MLX Swift LM | Default model: Llama 3.1 8B |
| Translation | Local LLM prompt path by default | Optional NLLB later if needed |
| Storage | SQLite + GRDB | Local-first |
| Search | SQLite FTS5 | Keyword search only in MVP |
| Calendar | EventKit | Apple Calendar only in MVP |
| Packaging | Xcode, hardened runtime, notarised `.app` | Native delivery |
| Secrets | Security.framework / Keychain | For future connectors |

### 8.2 Python worker stack

| Layer | Choice |
|---|---|
| Interpreter | Embedded Python 3.11 |
| Diarisation | `pyannote.audio` |
| Translation fallback | Optional NLLB only |
| IPC | JSON over stdin/stdout |
| Packaging | PyInstaller or python-build-standalone |

### 8.3 Defaults resolved

| Decision | Final Default |
|---|---|
| Default local LLM | **Llama 3.1 8B** |
| HUD live-caption | **Off by default** |
| Auto-event mode | **Review always** |
| Google Drive upload | **Manual trigger** (post-MVP) |
| Menu bar app | **Deferred to v2** |
| Icon style | **Minimalist glyph** |

---

## 9. Long-Audio Handling (4-Hour Class Support)

### 9.1 Capture layer
- Audio written to disk in real time via `AVAssetWriter`
- Archive format: AAC or M4A
- Processing path: 16 kHz mono WAV
- In-memory buffer capped tightly
- Recording session actor supports start, pause, resume, stop
- Lunch break or split-session flows are supported as separate linked sessions

### 9.2 Processing layer
- Whisper processes incrementally in bounded windows
- Transcript chunks committed to SQLite every few minutes
- Processing yields between windows to reduce thermal pressure
- App subscribes to thermal state and battery state
- Critical thermal states pause heavy processing, not recording integrity

### 9.3 Summarisation layer
Default summarisation is hierarchical Map-Reduce:
- 10-minute overlapping window summaries
- 30-minute section synthesis
- final meeting synthesis

This keeps the process memory-safe on 16 GB machines.

### 9.4 Recovery
- crash-safe checkpoints
- resumable job queue
- persisted processing state
- audio files never rewritten after finalisation

---

## 10. Memory, Thermal, and Power Discipline

### 10.1 MemoryManager
A Swift actor owns model lifecycle.

Rules:
- only one model family resident at a time
- transitions must explicitly unload the previous family
- worker termination is the release mechanism for Python-resident models
- low available memory produces warnings and can pause later stages

### 10.2 Thermal hooks
The app must respond to:
- `.fair`
- `.serious`
- `.critical`

Behaviour:
- reduce concurrency on heat rise
- increase yields between chunks
- pause on critical thermal pressure

### 10.3 Power hooks
On battery:
- reduce concurrency
- prioritise correctness over speed
- avoid optional heavy post-processing until on AC if necessary

### 10.4 Lid / sleep
On sleep or lid close:
- flush current recording writer
- checkpoint processing state
- pause queued heavy jobs
- resume safely on wake

---

## 11. Audio Capture Specification

### 11.1 Sources

| Source | Framework | Notes |
|---|---|---|
| System audio | ScreenCaptureKit | Requires Screen Recording permission |
| Microphone | AVFoundation | Requires microphone permission |
| Mixed | Audio mixing node | Combined recording path |
| File import | AVAsset extraction | Audio/video input support |

### 11.2 Output format
- archive: AAC/M4A
- processing: 16 kHz mono WAV

### 11.3 Important onboarding friction
macOS requires **Screen Recording** permission to capture system audio even when no video is saved.

This must be explained explicitly in onboarding and settings.

Recommended wording:

> “macOS requires Screen Recording permission to capture system audio. Varta uses this permission only to extract audio unless you explicitly choose to capture video in a future version.”

### 11.4 Failure modes
- partial recordings are always preserved
- permission denial disables specific modes, not the whole app
- recording failures surface clearly and never silently discard captured audio

---

## 12. Transcription Specification

### 12.1 Engine
- `whisper.cpp`
- Metal backend
- default model: `large-v3` quantised profile appropriate for Apple Silicon
- lower-memory profile available

### 12.2 Language handling
Modes:
- English only
- Nepali only
- Mixed / auto-detect

Each transcript segment stores:
- text
- corrected text
- language tag
- timestamps
- optional speaker label
- lock state

### 12.3 Hallucination mitigations
- VAD pre-filter
- low temperature
- repetition loop detection
- rolling prompt context between windows
- retranscription of obvious bad windows

### 12.4 Output shape
Every transcript segment is persisted and correction-friendly.  
Corrections never overwrite raw output destructively.

---

## 13. Speaker Diarisation Specification

### 13.1 Status
Diarisation is **MVP-compatible but non-blocking**.

### 13.2 Hard rule
If diarisation fails, the following must still succeed:
- transcription
- summary generation
- action item extraction
- decisions extraction
- transcript review
- Apple Calendar suggestion flow

### 13.3 Behaviour
- default may remain available in settings, but failure must degrade gracefully
- the UI must clearly show when speaker separation is unavailable
- fallback transcript is single-speaker or unlabeled-speaker friendly

### 13.4 Merge logic
If available:
- overlap-based matching of diarisation segments to transcript segments
- ambiguous merges flagged for review
- raw diarisation output preserved separately

### 13.5 Release-critical note
If packaging or notarisation of the Python worker becomes unstable, the app must ship with diarisation disabled rather than block release.

---

## 14. Multilingual Strategy (English + Nepali + Code-Switched)

### 14.1 First-class scenario
The product is graded on mixed Nepali-English audio, not just English-only audio.

### 14.2 Pipeline rules
- VAD before transcription
- conservative decode settings
- per-window language tagging
- user override modes
- rolling context to stabilise code-switched segments

### 14.3 Nepali-specific mitigations
- Unicode normalisation
- glossary-based replacements
- Devanagari-aware cleanup
- domain vocabulary support

### 14.4 Translation strategy
For the MVP:
- prioritise translation of **summaries and structured outputs**
- raw full-transcript translation is secondary
- default path is local LLM-based translation
- optional NLLB fallback may exist but should not complicate the first usable build

### 14.5 Bilingual UX
Views can show:
- original
- translated
- bilingual side-by-side

At minimum, summaries and key outputs must support this.

---

## 15. Summarisation and Content Generation

### 15.1 Engine
- MLX Swift LM
- default model: **Llama 3.1 8B**

### 15.2 Required outputs
- concise summary
- detailed summary
- bullet summary
- action items
- decisions
- unresolved questions
- follow-up email
- calendar candidates

### 15.3 Prompt templates
Prompt files must be external and editable:
- window summary
- section synthesis
- final summary
- action items
- decisions
- unresolved questions
- follow-up email
- calendar candidates
- translation

### 15.4 Regeneration
Any output can be regenerated independently from:
- raw transcript
- corrected transcript
- corrected transcript + glossary

---

## 16. Calendar Integration (MVP)

### 16.1 Scope
Only **Apple Calendar** is part of the MVP.

### 16.2 Framework
- `EventKit`

### 16.3 Behaviour
- summariser emits calendar candidates
- user reviews candidates in the meeting view
- user can manually create an Apple Calendar event
- created events are linked back to the meeting locally

### 16.4 Default posture
**Review always** is the default.  
Auto-create is not part of the MVP default path.

### 16.5 Why
Calendar integrity matters more than automation cleverness.

---

## 17. Storage, Search, and Data Model

### 17.1 Location
- database: `~/Library/Application Support/Varta/varta.sqlite`
- meeting artifacts: `~/Library/Application Support/Varta/meetings/{meeting_uuid}/`
- models: `~/Library/Application Support/Varta/models/`
- logs: `~/Library/Logs/Varta/`

### 17.2 Core tables
At minimum:
- `meetings`
- `audio_files`
- `transcript_segments`
- `summaries`
- `generated_outputs`
- `glossary_terms`
- `jobs`
- `processing_state`
- `settings`
- `calendar_links`

Optional MVP table:
- `diarization_segments`

### 17.3 Search
Only **FTS keyword search** is in the MVP.

No embeddings. No semantic retrieval. No RAG in the MVP.

---

## 18. UI / UX Specification

### 18.1 Surfaces in MVP
- Main window — Home
- Main window — Meeting Detail
- Main window — Search
- Main window — Settings
- Import sheet
- Recording controls
- Calendar review sheet
- Onboarding

### 18.2 Not in MVP
- live-caption HUD default workflow
- menu bar mini-app
- semantic search chat
- Spotlight surface
- Shortcuts integration

### 18.3 Meeting detail tabs
At minimum:
- Summary
- Transcript
- Translation
- Outputs
- Calendar

### 18.4 Transcript tab
- virtualised list
- click-to-seek timestamps
- correction UI
- language and speaker pill display
- filtering and search within transcript

### 18.5 Summary tab
Must expose:
- concise
- detailed
- bullet
- action items
- decisions
- unresolved questions
- follow-up email

### 18.6 Calendar tab
Shows extracted event candidates for manual review and Apple Calendar creation.

---

## 19. Security and Privacy

- all data local by default
- no telemetry in MVP
- no cloud egress in MVP
- permissions requested only when needed
- Keychain used for future secrets
- delete flows must truly remove local content
- Spotlight indexing not part of MVP

---

## 20. Performance Bands

These are bands, not rigid promises.

| Scenario | Minimum Acceptable | Target | Stretch Target |
|---|---:|---:|---:|
| Cold app launch | < 3.0 s | < 1.5 s | < 1.0 s |
| Recording start | < 1.5 s | < 0.8 s | < 0.5 s |
| 30-min English meeting → transcript + summary | < 12 min | < 5 min | < 3 min |
| 30-min mixed NE-EN meeting → transcript + summary | < 18 min | < 8 min | < 5 min |
| 4-hour class meeting → full processing | < 120 min | < 60 min | < 45 min |
| FTS search latency | < 300 ms | < 100 ms | < 50 ms |

### Why this matters
A coding agent must be allowed to stop once the system is functionally correct and within an acceptable band. Hard mathematical promises encourage destructive optimisation loops.

---

## 21. Testing Strategy

### 21.1 Unit tests
- glossary replacement
- language tagging behaviour
- transcript correction locking
- calendar candidate extraction
- checkpoint logic
- MemoryManager lifecycle transitions

### 21.2 Integration tests
- import → transcribe → summarise
- record → transcribe → summarise
- crash → relaunch → resume
- EventKit event creation
- diarisation worker fail → core app still succeeds

### 21.3 Benchmark corpus
Must include:
- English-only
- Nepali-only
- mixed English-Nepali
- overlapping speech
- noisy clip
- low-volume clip
- technical vocabulary clip
- long class session

---

## 22. Packaging, Signing, and Notarisation

- signed, hardened, notarised `.app`
- model files downloaded after install with consent
- no bloated bundled models unless necessary
- embedded Python worker carefully signed only if retained
- all embedded dylibs inside the worker must be signed correctly

### Highest release risk
The Python worker remains the highest packaging and Gatekeeper risk.

The app must remain shippable without it.

---

## 23. Development Roadmap

### Phase 0 — Skeleton
- project scaffolding
- storage layer
- migrations
- permission flows
- settings shell

### Phase 1 — Local import proof
- import audio/video
- transcription
- local summarisation
- transcript viewer
- transcript correction
- glossary
- translation of outputs

### Phase 2 — Native recording
- microphone + system audio recording
- disk-streamed write
- checkpoints
- 4-hour path
- thermal and power handling

### Phase 3 — Meeting detail completion
- outputs view
- Apple Calendar suggestions + manual creation
- FTS search
- strong local UX loop

### Phase 4 — Optional diarisation
- Python worker
- pyannote integration
- graceful fallback behaviour

### Post-MVP phases
- Google Drive
- Google Calendar
- semantic search
- meeting chat
- cloud adapters
- live-caption HUD
- menu bar app
- Shortcuts
- Spotlight
- URL scheme
- exports

---

## 24. Project Structure

```text
Varta/
├── Varta.xcworkspace
├── App/
├── Features/
│   ├── Home/
│   ├── Recording/
│   ├── MeetingDetail/
│   │   ├── Summary/
│   │   ├── Transcript/
│   │   ├── Translation/
│   │   ├── Outputs/
│   │   └── Calendar/
│   ├── Search/
│   └── Settings/
├── Services/
│   ├── Recording/
│   ├── Transcription/
│   ├── Summarisation/
│   ├── Translation/
│   ├── Calendar/
│   ├── Storage/
│   ├── Jobs/
│   ├── Memory/
│   └── System/
├── Worker/
│   └── varta-worker/
├── Native/
│   └── whisper-cpp.xcframework
├── Models/
├── Resources/
│   └── Prompts/
├── Tests/
└── docs/
```

Post-MVP folders for cloud, embeddings, chat, Drive, Google Calendar, HUD, and menu bar utility should not distract the MVP repo layout.

---

## 25. Prompt Templates (defaults)

The app must ship editable prompt files for:
- window summary
- section synthesis
- final summary
- action items
- decisions
- unresolved questions
- follow-up email
- calendar candidates
- translation

These prompt files should be copied to Application Support on first launch and remain user-editable.

---

## 26. Build Instructions for the Coding Agent

The coding agent must follow this order:

1. Initialise the Xcode project and strict concurrency.
2. Build the storage layer first.
3. Implement permissions and onboarding.
4. Integrate whisper.cpp.
5. Implement MLX Swift LM summarisation.
6. Build the import path end to end.
7. Build transcript review and correction.
8. Build native recording path.
9. Build 4-hour checkpoint and resume handling.
10. Build Apple Calendar suggestion + manual create.
11. Build FTS keyword search.
12. Only then attempt optional diarisation worker.
13. Stop. Do not build post-MVP features in the first autonomous pass.

### Hard instruction
The agent must not jump to Google integrations, semantic search, chat, or cloud APIs before the local loop is stable.

---

## 27. Decisions Log (v3)

| # | Decision | Rationale |
|---|---|---|
| D1 | Native Swift/SwiftUI/AppKit | Correct for Apple Silicon macOS app |
| D2 | whisper.cpp over Python ASR | Native Metal path, less packaging burden |
| D3 | MLX Swift LM with Llama 3.1 8B default | Strong local reasoning-to-RAM balance |
| D4 | Deniable Python surface | Keep Python isolated and optional |
| D5 | Diarisation is a soft dependency | Worker failure must not poison the whole app |
| D6 | Hierarchical Map-Reduce by default | Memory-safe and resumable |
| D7 | Apple Calendar only in MVP | Stronger focus, less OAuth complexity |
| D8 | Google integrations moved post-MVP | Prevent cross-domain scope drift |
| D9 | Keyword FTS only in MVP | Semantic retrieval is later |
| D10 | HUD off by default | Reduce clutter and complexity |
| D11 | Review always for event creation | Protect calendar integrity |
| D12 | Manual Drive upload default | Intentional archiving, not automatic leakage |
| D13 | Menu bar app deferred | Avoid state-sync complexity in MVP |
| D14 | Performance uses bands | Prevent destructive optimisation loops |
| D15 | ScreenCaptureKit permission must be explained | Product trust requirement |

---

## 28. Known Risks and Mitigations (v3)

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| ScreenCaptureKit permission feels invasive | High | Medium | Explain clearly in onboarding and settings |
| Python worker packaging breaks notarisation | Medium | High | Ship MVP without diarisation if needed |
| Mixed Nepali-English ASR quality is weaker than expected | High | Medium | Use glossary, correction UI, conservative decoding |
| Long-audio processing overheats the machine | High | Medium | Yielding, phase separation, thermal hooks |
| Agent scope drift into post-MVP features | High | High | Freeze MVP boundary explicitly |
| Calendar candidate extraction can be wrong | Medium | Medium | Review always |
| Over-optimisation loops from hard benchmarks | Medium | High | Use minimum/target/stretch bands |

---

## 29. Open Questions Resolved

These are now closed for v3.

| Decision | Final Answer |
|---|---|
| Default local LLM | **Llama 3.1 8B** |
| HUD default | **Off** |
| Auto-event mode | **Review always** |
| Drive upload default | **Manual trigger** |
| Menu bar app | **Defer to v2/post-MVP** |
| Icon style | **Minimalist glyph** |

---

## 30. Final Notes

This is a serious personal productivity tool, not a demo. It must feel native, trustworthy, and calm.

The mainline path must work perfectly with:
- all cloud providers absent,
- all connectors absent,
- and diarisation unavailable.

The 4-hour class scenario remains a first-class test case, but the app is no longer forced into unrealistic benchmark absolutism.

If tradeoffs surface during implementation, choose in this order:

1. correctness  
2. privacy  
3. usability  
4. reliability  
5. speed  
6. convenience  

**End of document.**
