# Varta — Nepali-Aware, Apple-Silicon-Native AI Meeting Assistant

**Document Type:** Product Requirements Document + Technical Architecture + Build Blueprint (v2)
**Supersedes:** `Varta-blueprint.md` (v1). v1 is preserved; this document is authoritative.
**Target Build Agent:** Claude Code / Cowork / OpenAI Codex — any agent capable of reading this blueprint end-to-end and implementing autonomously.
**Platform:** Native macOS desktop application, Apple Silicon only. Not a web app. Not Electron or Tauri.
**Primary Owner:** Prabesh Bhetwal (single-user, personal-use).
**Core Principle:** Native by default. Python only where it wins decisively. Free and local-first for the MVP, with a clean optional adapter for top-tier cloud APIs. Bilingual (English + Nepali + code-switched) is a first-class constraint, not a stretch goal.

---

## 0. Changelog from v1

This document folds in the Gemini Pro strategic risk analysis, the ChatGPT architecture refinement, and the 4-hour long-audio requirement. Major changes from v1:

1. Architecture pivoted from "Python-heavy ML prototype wrapped in a Mac shell" to "real Mac app with native Apple Silicon acceleration and selective fallback workers." Python is now a restricted, optional fallback (diarisation, NLLB translation only) rather than the primary ML runtime.
2. Transcription moves from `faster-whisper` (Python) to **whisper.cpp** with Swift bindings, running directly on the Metal GPU.
3. Local LLM moves from generic MLX/MLX-LM (Python) to **MLX Swift / MLX Swift LM**, embedded directly in the Swift process.
4. Alignment moves from `WhisperX` to `whisper.cpp` word-level timestamps, eliminating a dependency entirely.
5. New long-audio handling: disk-streaming audio capture via `AVAssetWriter`, chunked processing with SQLite checkpoints, and hierarchical Map-Reduce summarisation.
6. New thermal and memory discipline: strict one-model-family-at-a-time phase separation, MemoryManager singleton, thermal throttling hooks.
7. New cloud sync layer: Google Drive upload, Google Calendar bidirectional sync, Apple Calendar via EventKit.
8. New optional Cloud API adapter layer supporting Anthropic (Claude Sonnet/Opus 4.6), OpenAI (GPT-4o/5), and Google (Gemini 2.5 Pro) for users who choose to enable paid top-tier models.
9. New live-caption HUD, URL scheme, Shortcuts.app support, and Spotlight integration.

---

## 1. Executive Summary

Varta is a native macOS application for Apple Silicon that records, transcribes, diarises, summarises, translates, and files meetings. It is built for a bilingual (English + Nepali + mixed) user, runs fully on-device by default, and exposes optional integrations with Google Drive, Google Calendar, and Apple Calendar. It is designed to handle meeting durations up to four continuous hours (class-meeting baseline), with robust disk-streamed capture and checkpointed processing so a crash or lid-close never loses data.

The app follows a three-tier stack:

| Tier | Path | Components |
|---|---|---|
| Tier 1 — Primary native | SwiftUI + AppKit, ScreenCaptureKit, AVFoundation, whisper.cpp (Metal), MLX Swift LM, EventKit, SQLite/GRDB | Everything on the mainline path |
| Tier 2 — Restricted Python fallback | Isolated Python worker, child process over structured JSON/stdio | Pyannote diarisation, optional NLLB translation |
| Tier 3 — Optional cloud adapter | Bring-your-own-key to Anthropic, OpenAI, Google | User-configurable; off by default |

The app must ship as a signed, notarised `.app` bundle. No permanent REST service. No Docker. No background daemons beyond what macOS permits via `LaunchAgents` for scheduled recording triggers.

---

## 2. Product Vision

Varta should feel like a cross between a meeting recorder, an AI notepad, a private meeting memory, and a meeting-to-calendar workflow engine. It should be calm, fast, Apple-native, and trustworthy.

The product prioritises, in this order:

1. **Correctness** — the transcript, summary, and extracted commitments must reflect what was actually said.
2. **Privacy** — audio, transcripts, summaries, embeddings, and outputs stay on device by default.
3. **Usability** — the user finds the output they need within two clicks of opening a meeting.
4. **Speed** — recording starts in under one second; a 30-minute meeting produces a usable transcript within five minutes on the baseline machine.
5. **Convenience** — cloud sync and calendar creation smooth the workflow but are never required.

If tradeoffs arise, choose in that order.

---

## 3. Feature Matrix

Phases are additive. Earlier phases must ship before later ones are attempted.

| Feature | MVP (P0) | v1 (P1) | v2 (P2) | v3 (P3) |
|---|---|---|---|---|
| Import audio file → transcript | ✓ | | | |
| Native recording (mic + system audio) | ✓ | | | |
| whisper.cpp transcription with word timestamps | ✓ | | | |
| Basic speaker diarisation (pyannote worker) | ✓ | | | |
| Meeting detail view with playback seek | ✓ | | | |
| Local LLM summary (MLX Swift LM) | ✓ | | | |
| Action items + decisions extraction | ✓ | | | |
| Transcript correction with locking | ✓ | | | |
| Nepali-only, English-only, mixed mode | ✓ | | | |
| Glossary table and replacement | ✓ | | | |
| NLLB or LLM-based translation (EN↔NE) | ✓ | | | |
| SQLite + FTS keyword search | ✓ | | | |
| Apple Calendar event creation (EventKit) | ✓ | | | |
| 4-hour continuous recording with checkpoints | ✓ | | | |
| Hierarchical Map-Reduce summariser | ✓ | | | |
| Google Drive upload of recordings | | ✓ | | |
| Google Calendar bidirectional sync | | ✓ | | |
| Live caption HUD overlay | | ✓ | | |
| Semantic search with local embeddings | | ✓ | | |
| Meeting chat (RAG over transcripts) | | ✓ | | |
| Optional cloud API adapter (Claude/GPT/Gemini) | | ✓ | | |
| Speaker voice-embedding auto-labelling | | | ✓ | |
| Calendar-triggered auto-recording | | | ✓ | |
| Shortcuts.app actions + URL scheme | | | ✓ | |
| Spotlight indexing of meetings | | | ✓ | |
| Meeting tags, folders, and smart collections | | | ✓ | |
| Pre-meeting briefing from history | | | | ✓ |
| Apple Notes / Obsidian / Notion export | | | | ✓ |
| Redaction and selective deletion | | | | ✓ |
| Encrypted local archive export | | | | ✓ |

---

## 4. Non-Goals

Do not build these. They would distort the architecture and delay the core product.

- Multi-user cloud collaboration.
- Web or browser front end.
- SaaS subscription or billing.
- Enterprise admin console.
- Bot that joins Zoom / Meet / Teams calls as a participant.
- CRM integrations.
- Public sharing links or invite flows.
- Background daemon for always-on passive listening.
- Windows or Linux support.
- Intel Mac support.

---

## 5. Constraints and Assumptions

### 5.1 Platform
- macOS 14 (Sonoma) or later, targeting the latest two major releases at any time.
- Apple Silicon only. No universal binary.
- Minimum 16 GB unified memory; 32 GB recommended for the 4-hour path with high-accuracy model profile.
- SSD with at least 20 GB of free space reserved for local models, recordings, and derived artifacts.

### 5.2 Audio
- Maximum continuous recording duration: **4 hours per session**. Typical session is 30-60 minutes.
- Class-meeting scenario: up to 4 hours before lunch, then a separate 4-hour session after. Each 4-hour session is processed independently.
- Mixed English + Nepali is the common case. Pure Nepali and pure English are both supported.

### 5.3 Hardware budgeting
- 4 hours of 16 kHz mono WAV ≈ 460 MB on disk. 4 hours of 48 kHz stereo AAC ≈ 115 MB.
- Single-model residency: Whisper large-v3 Q5_0 ≈ 1.1 GB; MLX Llama 3.1 8B Q4 ≈ 5 GB; NLLB-200 distilled-600M Q4 ≈ 800 MB; pyannote 3.1 ≈ 400 MB. Never resident simultaneously.

### 5.4 Personal-use assumption
- Single-user local database.
- No identity / authentication required for the app itself.
- OAuth tokens for Google are stored in Keychain, never in SQLite or plaintext files.

---

## 6. Architectural Principles

These are load-bearing rules. The coding agent must not violate them without escalation.

1. **Native by default.** Every subsystem attempts a Swift / C++ / Metal implementation before falling back to Python.
2. **One model family resident at a time.** Whisper, pyannote, LLM, and NLLB must not co-reside in memory. Phase separation is mandatory.
3. **Disk-stream everything long.** Audio is written to disk as it is captured. Transcripts are committed to SQLite every 5 minutes of processed audio. No long-running in-memory buffers above 200 MB.
4. **Every pipeline stage is resumable.** If the app crashes or the lid closes mid-process, the next launch resumes from the last committed checkpoint.
5. **No permanent local REST service.** IPC with the Python worker is a spawn-on-demand child process over structured JSON on stdio. The worker terminates when the job completes.
6. **Explicit user consent for every permission.** Microphone, system audio, calendar, automation, and each external account connector.
7. **Cloud is strictly opt-in and strictly adapter-based.** The core pipeline must remain fully functional with all cloud providers disabled.
8. **Reliability outranks speed; correctness outranks convenience.** See §2.

---

## 7. High-Level Architecture

### 7.1 Process model

```
┌──────────────────────────────────────────────────────────────┐
│  Varta.app  (single signed macOS process)                    │
│                                                              │
│  ┌─────────────────────┐   ┌──────────────────────────────┐  │
│  │   UI (SwiftUI +     │   │   Core Services (Swift)      │  │
│  │   AppKit bridges)   │◄─►│   • RecorderCoordinator      │  │
│  │                     │   │   • TranscriptionService     │  │
│  └──────────▲──────────┘   │     (whisper.cpp + Metal)    │  │
│             │              │   • SummariserService        │  │
│             │              │     (MLX Swift LM)           │  │
│             │              │   • TranslationService       │  │
│             │              │   • CalendarService (EventKit)│ │
│             │              │   • DriveService (Google)    │  │
│             │              │   • MemoryManager            │  │
│             │              │   • JobQueue / Checkpointer  │  │
│             │              │   • StorageService           │  │
│             │              │     (GRDB + SQLite + FTS5)   │  │
│             │              └──────────────┬───────────────┘  │
└─────────────┼─────────────────────────────┼──────────────────┘
              │                             │ spawn on demand
              │                             ▼
              │          ┌──────────────────────────────────┐
              │          │  varta-worker (Python, embedded) │
              │          │  • pyannote 3.1 diarisation      │
              │          │  • NLLB-200 translation (opt.)   │
              │          │  Lifetime: single job, then exit │
              │          └──────────────────────────────────┘
              │
              ▼
   ┌──────────────────────────────┐
   │  Filesystem + SQLite         │
   │  ~/Library/Application       │
   │  Support/Varta/              │
   └──────────────────────────────┘
```

### 7.2 Runtime split

**Swift / native path (always-on, mainline):**
- UI, permissions, recording coordination, file I/O.
- Transcription (whisper.cpp via Swift bridging).
- Summarisation and content generation (MLX Swift LM).
- Local embeddings (MLX Swift sentence-transformer-style model).
- Apple Calendar integration (EventKit).
- Google Drive and Google Calendar (Swift HTTPS client against REST APIs).
- Storage, search, FTS5, vector index.
- Job queue, checkpointing, crash recovery.

**Python worker (spawned on demand):**
- Pyannote 3.1 speaker diarisation.
- NLLB-200 translation (only if the user opts out of LLM-based translation).
- The worker is a `PyInstaller`-frozen or `python-build-standalone` interpreter bundled inside `Varta.app/Contents/Resources/varta-worker/`. It reads a JSON job descriptor on stdin, writes JSON results on stdout, and exits.

### 7.3 Why not a permanent FastAPI service

Gemini suggested a localhost FastAPI wrapper. For a single-user offline desktop app, a permanent HTTP service is an unnecessary attack surface and a packaging burden. Spawn-on-demand child processes with structured JSON over stdio are cleaner, cheaper, and exit when done. A FastAPI layer is only warranted if the Python worker grows past four concurrent model types, which this product will not.

---

## 8. Technology Stack

### 8.1 Core stack

| Layer | Choice | Notes |
|---|---|---|
| UI | SwiftUI (primary), AppKit (bridges only) | Menu bar + main window + HUD. Minimum target macOS 14. |
| Language | Swift 5.10+ | Strict concurrency mode on. |
| Audio capture | ScreenCaptureKit (system audio), AVFoundation (mic), AVAssetWriter (disk) | ScreenCaptureKit is the modern path; avoid CoreAudio taps. |
| Transcription | whisper.cpp + WhisperKit Swift bindings OR custom Swift bridging | Metal GPU acceleration. Model: `ggml-large-v3-q5_0` default; `medium-q5_0` low-memory. |
| Word alignment | whisper.cpp `--output-json-full` with token timestamps | No WhisperX dependency. |
| Speaker diarisation | pyannote.audio 3.1 in Python worker | Set `PYTORCH_ENABLE_MPS_FALLBACK=1`. Expect CPU fallback until pyannote ships clean MPS support. |
| Local LLM | MLX Swift LM | Default model: `mlx-community/Llama-3.1-8B-Instruct-4bit`. Long-context model: `mlx-community/Phi-3.5-mini-instruct-4bit` (128k context). |
| Local embeddings | MLX Swift with `sentence-transformers/all-MiniLM-L6-v2` converted to MLX | 384-dim vectors. |
| Translation (local) | LLM-based (Llama 3.1 with translation prompt) OR NLLB-200 via Python worker | LLM-based is default; NLLB is the fallback for purely offline low-resource operation. |
| VAD | Silero VAD compiled for Apple Silicon, invoked via whisper.cpp's built-in VAD support | Pre-filter before Whisper to suppress hallucinations. |
| Database | SQLite 3.44+ with FTS5 | Access via GRDB.swift 6.x. |
| Vector index | Flat index in SQLite (stored as BLOB) for MVP; upgrade to usearch-swift in v1 | Personal-use scale makes a flat index viable up to ~50k chunks. |
| Calendar | EventKit (Apple); Google Calendar REST v3 | OAuth via ASWebAuthenticationSession. |
| Cloud file sync | Google Drive REST v3 | Resumable uploads for recordings >5 MB. |
| Packaging | Xcode project, hardened runtime, notarised `.app` | No Sparkle in MVP; manual update download. |
| Secrets | macOS Keychain via `Security.framework` | Never in SQLite. |

### 8.2 Python worker stack (Tier 2)

| Layer | Choice |
|---|---|
| Interpreter | Python 3.11 via `python-build-standalone`, bundled inside app |
| Diarisation | `pyannote.audio==3.1.1`, `torch>=2.4` with MPS backend |
| Translation (optional) | `transformers` with `facebook/nllb-200-distilled-600M` |
| IPC | stdin: JSON job descriptor; stdout: JSON result or progress events; stderr: logs |
| Packaging | PyInstaller one-folder build, code-signed, entitlement for embedded Python |

### 8.3 Optional cloud adapters (Tier 3)

Each adapter is a Swift protocol implementation. None are active until the user provides a key via Settings. Keys live in Keychain.

| Provider | Models | Use cases |
|---|---|---|
| Anthropic | `claude-opus-4-6`, `claude-sonnet-4-6` | Best-in-class summarisation, bilingual reasoning, meeting chat |
| OpenAI | `gpt-5` family, `whisper-1`, `gpt-4o-transcribe` | Fast cloud transcription, alternative summariser |
| Google | `gemini-2.5-pro`, `gemini-2.5-flash` | Long-context single-pass summarisation, translation |
| Groq | `whisper-large-v3-turbo` | Very fast cloud transcription fallback |
| Deepgram | `nova-3` | Alternative transcription with strong diarisation |

The adapter layer exposes three protocols: `TranscriptionProvider`, `SummarisationProvider`, `TranslationProvider`. The rest of the app talks only to the protocol; swapping local for cloud is a settings toggle.

---

## 9. Long-Audio Handling (4-Hour Class Support)

This section addresses the class-meeting scenario explicitly.

### 9.1 Capture layer

- Audio is written to disk in real time via `AVAssetWriter` configured with AAC at 48 kHz stereo. Raw PCM WAV at 16 kHz mono is written in parallel into the `audio/normalised.wav` path, downsampled on the fly via an `AVAudioConverter`.
- In-memory audio buffer is capped at 10 seconds. Anything older is flushed to disk.
- The writer is wrapped in a `RecordingSession` actor that exposes `start`, `pause`, `resume`, `stop`, and auto-splits into a new file if duration exceeds 4 hours (configurable).
- Pause on lunch break is supported: the writer finalises the current segment and the next `start` creates a new audio file linked to the same `meeting` row.

### 9.2 Processing layer

Whisper processes audio in 30-second windows. 4 hours = 480 windows. This is memory-safe but thermally hostile.

- The `TranscriptionService` emits a `TranscriptChunkCompleted` event after each 30-second window.
- The `Checkpointer` commits transcript segments to SQLite in batches of every 10 windows (5 minutes of audio).
- Between windows, the service yields for 50 ms (configurable) to allow macOS scheduling and thermal management breathing room.
- The service subscribes to `ProcessInfo.thermalState`. On `.serious`, it doubles the inter-window yield. On `.critical`, it pauses and notifies the UI with an option to resume automatically when thermals recover.
- The service subscribes to power-source changes. On battery with less than 30% remaining, it pauses processing and offers to resume on AC.

### 9.3 Summarisation layer — Hierarchical Map-Reduce

This is the default summariser. It is memory-safe on 16 GB and produces cohesive output.

```
Raw transcript (4 hours, ~35,000 words)
        │
        ▼  Map phase — 10-minute windows with 1-minute overlap
        │  For each window, run an 8k-context LLM with the "window summary" prompt.
        │  Output: bullet points, action items, decisions, open questions, notable quotes.
        │
        ▼  Reduce L1 — 30-minute section summaries
        │  Combine every 3 consecutive window summaries into a section summary
        │  using a "section synthesis" prompt.
        │
        ▼  Reduce L2 — Final meeting summary
        │  Combine all section summaries into the final deliverables:
        │  concise, detailed, action items, decisions, follow-up email, etc.
        │  This step can optionally run on a 128k-context model for max cohesion.
        │
        ▼  Per-output language branching
        │  English final, Nepali final, bilingual side-by-side.
```

- Each phase is a discrete job in the job queue with its own checkpoint.
- Partial output is made available progressively: once the first 30-minute section is reduced, the user can read that section's summary while the rest processes.
- User can rerun any single window, section, or final Reduce without redoing the rest.

### 9.4 Configurable summarisation mode

A user preference controls the pipeline:

| Mode | Map model | Reduce L1 model | Reduce L2 model | When |
|---|---|---|---|---|
| Fast | Llama 3.1 8B Q4 | Llama 3.1 8B Q4 | Llama 3.1 8B Q4 | Default, 16 GB |
| Balanced | Llama 3.1 8B Q4 | Llama 3.1 8B Q4 | Phi-3.5-mini 128k Q4 | 16 GB, slightly slower final Reduce |
| Quality | Llama 3.1 8B Q4 | Qwen 2.5 14B Q4 | Qwen 2.5 14B Q4 | 32 GB+ |
| Cloud-assisted | Local Map | Local Reduce L1 | Claude Sonnet 4.6 cloud | Requires API key |

The Quality tier is only offered if system memory ≥ 24 GB at runtime.

### 9.5 State preservation

- Every processed window, section, and reduction commits to SQLite with a `processing_state` row tracking `(meeting_id, stage, last_completed_window_index, last_completed_section_index, last_completed_reduction_level, updated_at)`.
- On app launch, the `JobQueue` queries for meetings with `status IN ('processing', 'paused')` and resumes from the last checkpoint.
- Audio files are never rewritten after finalisation. Derived artifacts are idempotent.

---

## 10. Memory and Thermal Discipline

### 10.1 MemoryManager singleton

A Swift actor that owns model lifecycle. The rules are simple and strict.

- Only one model family is resident at a time. Families are: `whisper`, `mlxLM`, `mlxEmbedding`, `pyannote` (in worker), `nllb` (in worker).
- Acquiring a model family implicitly releases any currently resident family. Release triggers `mlx.core.clear_cache()` equivalent for MLX Swift, `whisper_free_context` for whisper.cpp, and worker termination for Python-resident models.
- Each acquisition is async and awaited by the caller; the MemoryManager serialises transitions.
- The manager exposes `memoryPressure()` queried against `os_proc_available_memory()` and surfaces a warning to the UI if available memory falls below 2 GB during processing.

### 10.2 Thermal hooks

- Subscribe to `ProcessInfo.thermalStateDidChangeNotification`.
- On `.fair`: no change.
- On `.serious`: double the inter-chunk yield; reduce the whisper.cpp `-t` (threads) from `performanceCoreCount` to `performanceCoreCount - 2`.
- On `.critical`: pause all processing. Surface a non-modal banner to the user. Resume automatically when state returns to `.fair` or lower, or on user tap.

### 10.3 Power hooks

- Subscribe to `NSProcessInfo.processInfoDidChangeNotification` and `IOPSNotificationCreateRunLoopSource` for power source.
- On battery: reduce concurrency to 1, disable the 128k-context Reduce, and use the "Fast" summarisation mode regardless of user preference.
- On AC: restore user preference.

### 10.4 Lid and sleep

- On `NSWorkspace.willSleepNotification`: finalise the current chunk's SQLite commit, pause the job queue, ensure the audio writer flushes.
- On `NSWorkspace.didWakeNotification`: resume the job queue.
- If a recording is live when the lid closes on battery, honour the user's preference: `Continue`, `Pause and resume on wake`, or `Stop and save`.

---

## 11. Audio Capture Specification

### 11.1 Sources

| Source | Framework | Notes |
|---|---|---|
| System audio | ScreenCaptureKit (`SCStreamConfiguration.capturesAudio = true`) | macOS 13+. Requires screen-recording permission even when only audio is captured. |
| Microphone | AVFoundation (`AVCaptureDevice`, `AVAudioEngine`) | Requires mic permission. |
| Mixed | Two inputs into a single `AVAudioMixerNode`; combined stream goes to both AAC and 16 kHz mono WAV writers. | Clock-sync the two inputs; SCK buffers arrive with `CMSampleBuffer` timestamps. |
| File import | User selects an audio or video file; we extract the audio track with AVAsset. | Supported: wav, mp3, m4a, mp4, mov, flac, aac. |

### 11.2 Output format

- **Archive:** AAC-LC 48 kHz stereo 128 kbps in `.m4a`. Acceptable fidelity, small file.
- **Processing:** PCM 16 kHz mono in `.wav`. Required by whisper.cpp and pyannote.
- **Live HUD stream:** 16 kHz mono frames tapped from the processing path; 5-second sliding window fed to whisper.cpp streaming mode for live captions.

### 11.3 Failure modes

- If screen-recording permission is denied: disable system-audio option, explain why, offer the `System Settings` deeplink.
- If mic permission is denied: same pattern.
- If the audio writer fails mid-recording: finalise whatever is on disk, write a `meeting.recording_interrupted = true` flag, surface an error to the user.
- Never silently lose audio. Any partial recording is kept and processable.

### 11.4 Privacy indicator

- Menu bar icon changes to a recording-red state during capture.
- A red dot in the Dock badge.
- `os_log` a recording event for transparency.

---

## 12. Transcription Specification

### 12.1 Engine

- whisper.cpp, Metal backend, `ggml-large-v3-q5_0` as default model.
- Integrate via WhisperKit (if its API surface suffices) or a custom Swift bridging layer wrapping `whisper.h`. Custom bridging is preferred for long-term control; WhisperKit is acceptable if it exposes VAD, word timestamps, and language tagging.
- Model files live in `~/Library/Application Support/Varta/models/whisper/`.
- Model download occurs on first use with explicit user consent and a progress indicator. Source: Hugging Face `ggerganov/whisper.cpp`.

### 12.2 Options

```
whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
params.print_progress      = false;
params.print_realtime      = false;
params.print_timestamps    = true;
params.token_timestamps    = true;
params.split_on_word       = true;
params.language            = "auto";   // or "en" / "ne" per user preference
params.temperature         = 0.0f;
params.temperature_inc     = 0.2f;
params.entropy_thold       = 2.4f;
params.logprob_thold       = -1.0f;
params.no_speech_thold     = 0.6f;
params.suppress_blank      = true;
params.suppress_non_speech_tokens = true;
params.vad                 = true;
params.vad_model_path      = "<silero-ggml-path>";
params.vad_threshold       = 0.5f;
params.vad_min_speech_duration_ms  = 250;
params.vad_min_silence_duration_ms = 100;
params.n_threads           = perfCoreCount;
params.n_processors        = 1;
params.max_len             = 0;
params.max_tokens          = 0;
```

### 12.3 Language handling

- Default: `language = "auto"` for mixed-language meetings. Whisper detects per window.
- User override: `English only`, `Nepali only`, `Mixed (auto-detect)`.
- Each segment persists its detected language.
- If a window produces output with a detected language the user has forbidden, that window is retranscribed with the user's target language forced. This mitigates the Whisper failure mode where a code-switched phrase drags the next window into the wrong language.

### 12.4 Hallucination mitigations

- VAD pre-filter via Silero — Whisper never sees silence.
- `temperature = 0.0` (greedy), increment only on decode failures.
- `no_speech_thold = 0.6` to aggressively reject low-confidence windows.
- Detect repetition loops: if the last 5 tokens equal the 5 before them, abort the window and retranscribe with `temperature = 0.2` and a shortened context.
- Maintain a rolling "prompt context" of the last 128 tokens from the previous window, passed via `--prompt` to Whisper. This stabilises decoding across code switches.

### 12.5 Output shape

Each segment stored in `transcript_segments`:

```
segment_id              UUID
meeting_id              UUID
audio_file_id           UUID
segment_index           INTEGER
start_seconds           REAL
end_seconds             REAL
text                    TEXT           -- raw whisper output
text_corrected          TEXT NULLABLE
text_locked             BOOLEAN
detected_language       TEXT           -- ISO 639-1
confidence              REAL NULLABLE
speaker_id              UUID NULLABLE  -- filled after diarisation merge
word_timestamps_json    TEXT           -- array of {word, start, end, confidence}
created_at              TIMESTAMP
updated_at              TIMESTAMP
```

---

## 13. Speaker Diarisation Specification

### 13.1 Engine

- pyannote.audio 3.1, pipeline `pyannote/speaker-diarization-3.1`, via the Python worker.
- Hugging Face access token stored in Keychain; user supplies it once in Settings.
- The worker is spawned with `PYTORCH_ENABLE_MPS_FALLBACK=1`. MPS support for pyannote is incomplete, so performance will be CPU-bound; this is acceptable given diarisation runs after transcription completes.

### 13.2 Treatment as optional

Diarisation is a known-unstable subsystem on Apple Silicon. The product treats it as:

- Default ON for MVP, with clear UI that flags it as "beta".
- User can disable it globally in Settings.
- If the worker crashes, the meeting falls back to a single unnamed-speaker transcript rather than blocking the rest of the pipeline.
- A feature flag `diarisation.auto_recover` controls whether the app retries with smaller audio chunks on failure.

### 13.3 Merge logic

After transcription and diarisation both complete:

1. Build an interval tree over diarisation segments.
2. For each transcript segment, find the diarisation segment with maximum temporal overlap.
3. If overlap ≥ 60% of the transcript segment duration, assign the speaker confidently.
4. If overlap is ambiguous (two speakers each < 60%), mark the segment as `speaker_ambiguous = true` and surface it in the UI for manual resolution.
5. Persist both the raw diarisation output and the merged result; never destroy the raw data.

### 13.4 Speaker naming

- MVP: auto-labels as `Speaker 1`, `Speaker 2`, etc.
- Post-MVP: user renames speakers and the system offers to propagate aliases across meetings using voice-embedding similarity (cosine similarity ≥ 0.82 suggests the same speaker).

---

## 14. Multilingual Strategy (English + Nepali + Code-Switched)

### 14.1 First-class constraint

Mixed Nepali-English is the primary test case. The product is graded on this scenario, not on English-only benchmarks.

### 14.2 Pipeline rules

1. VAD pre-filter before Whisper — always.
2. `temperature = 0.0` with fallback increment to 0.2 on decode failure — always.
3. Rolling prompt context across windows — always.
4. Per-window language tagging — persisted in `transcript_segments.detected_language`.
5. The user can set a meeting's `language_mode` to `auto` (default), `en`, `ne`, or `mixed`. `auto` allows Whisper to pick per window; `mixed` forces auto but additionally tags each segment with heuristics.

### 14.3 Nepali-specific mitigations

- Unicode normalisation (NFC) on all output text.
- Devanagari-aware word-boundary heuristics before sending to the LLM (Nepali Whisper output can have spurious spaces).
- Glossary replacement runs as a post-transcription pass:
  - `glossary_terms` table stores `{term, canonical_form, language, alternate_forms[], priority}`.
  - A glossary match replaces the token and marks the segment as `glossary_applied = true`.
  - User can disable per-segment.
- Domain vocabulary per user: "dental", "Sydney Dental Hospital", "Harbour Net", "MERN", people's names.

### 14.4 Translation strategy

Two paths, user-selectable:

| Path | Engine | Latency | Quality on Nepali |
|---|---|---|---|
| LLM-based | Llama 3.1 8B with translation prompt | Fast (~500 ms / 200 words) | Good for summary-level text; variable on long raw transcripts |
| NLLB-200 | `facebook/nllb-200-distilled-600M` in Python worker | Moderate | Strong for sentence-level, especially Nepali |

- MVP default: LLM-based (avoids spawning the Python worker for translation).
- Fallback: NLLB for documents longer than 5000 words or when the user explicitly selects it.
- Glossary entries feed into the translation prompt as a system-level term map.

### 14.5 Bilingual UX

- Transcript view: toggle between `Original`, `Translated`, `Bilingual (side-by-side)`.
- Summary view: same toggle.
- Exported Markdown can include both languages in a single document with anchors.

---

## 15. Summarisation and Content Generation

### 15.1 Engine

- MLX Swift LM, embedded in the Swift process.
- Default model: `mlx-community/Llama-3.1-8B-Instruct-4bit`. Size ≈ 5 GB resident.
- Long-context Reduce model (optional): `mlx-community/Phi-3.5-mini-instruct-4bit` with 128k context window. Size ≈ 3 GB resident.
- Models live in `~/Library/Application Support/Varta/models/mlx/` and are downloaded on first use with user consent.

### 15.2 Prompt templates

All prompts are external Markdown files in `~/Library/Application Support/Varta/prompts/`. Users can edit them. The app ships defaults that are copied on first launch.

Required default templates:

| Template | Filename | Purpose |
|---|---|---|
| Window summary | `window_summary.md` | Map phase — per 10-minute window |
| Section synthesis | `section_synthesis.md` | Reduce L1 — per 30-minute section |
| Final summary | `final_summary.md` | Reduce L2 — whole meeting |
| Action items | `action_items.md` | Extract actions with owner + due date |
| Decisions | `decisions.md` | Extract decisions with rationale |
| Unresolved questions | `unresolved.md` | Extract open questions |
| Follow-up email | `followup_email.md` | Compose an email from the summary |
| Calendar candidates | `calendar_candidates.md` | Extract future commitments as event candidates |
| Translation | `translation.md` | System prompt + glossary injection |
| Meeting chat | `meeting_chat.md` | RAG question answering over transcript |
| Standup, interview, 1:1, brainstorm, client call, project planning | various | User-switchable meeting types |

### 15.3 Output types

| Output | Description |
|---|---|
| Concise summary | 3-5 sentence paragraph |
| Detailed summary | Full prose, up to 800 words |
| Bullet summary | 8-15 bullet points |
| Action items | `[{task, owner, due_date, confidence, source_segment_id}]` |
| Decisions | `[{decision, rationale, confidence, source_segment_id}]` |
| Unresolved questions | `[{question, who_raised, confidence, source_segment_id}]` |
| Follow-up email | Subject + body, in user's tone |
| Slack update | Short team-channel-ready update |
| Calendar candidates | `[{title, start, end, notes, confidence, source_segment_id}]` |
| Bilingual versions of the above | EN + NE variants |

### 15.4 Regeneration rules

- User can regenerate any output from raw transcript, corrected transcript, or corrected transcript + glossary.
- Regenerating an output does not invalidate other outputs.
- All generated outputs store `{model_name, prompt_version, generated_from_corrected, created_at}` so the user can tell when a view is stale relative to corrections.

---

## 16. Calendar Integration

### 16.1 Apple Calendar (EventKit)

- Framework: `EventKit`.
- Permission: `EKEventStore.requestFullAccessToEvents`.
- Default calendar: user-selectable in Settings; falls back to the user's default writeable calendar.
- Event creation flow:
  1. Summariser emits calendar candidates with confidence.
  2. Candidates above threshold (default 0.75) appear in the meeting's Calendar tab.
  3. User reviews, edits title / start / end / notes / attendees, clicks `Create`.
  4. `EKEvent` is created, linked to the meeting via `calendar_links` table.
  5. Meeting summary is attached to the event's `notes` with a truncation limit.
- Optional: app reads today's calendar to infer the current meeting's title from the nearest scheduled event (±30 minutes window).

### 16.2 Google Calendar

- API: Google Calendar REST v3.
- OAuth: `ASWebAuthenticationSession` with PKCE. Scopes: `https://www.googleapis.com/auth/calendar.events`, `https://www.googleapis.com/auth/calendar.readonly`.
- Tokens in Keychain, never in SQLite.
- Bidirectional sync:
  - **Read:** fetch events in a ±7 day window; cache in SQLite for inference and context.
  - **Write:** create events from calendar candidates; same UX as Apple flow.
- User selects a primary Google calendar for writes.
- Sync is pull-only on launch and push-on-create. No continuous background sync in MVP.

### 16.3 Auto-event default posture

- Default: `Always review before creating`.
- Options: `Always review`, `Auto-create high-confidence events`, `Draft only (don't write to calendar)`.
- Confidence threshold for auto-create: user-configurable, default 0.90.
- Auto-created events are tagged in their description as `Created by Varta from <meeting_title>`.

---

## 17. Google Drive Integration

### 17.1 Scope

- API: Google Drive REST v3.
- OAuth scope: `https://www.googleapis.com/auth/drive.file` (per-file scope — the app can only see and modify files it creates).
- User can disable Drive upload globally or per-meeting.

### 17.2 Folder structure

```
My Drive/
└── Varta/
    ├── {YYYY}/
    │   └── {YYYY-MM-DD_HHmm}_Recording_{meeting_title_slug}/
    │       ├── recording.m4a
    │       ├── transcript.json
    │       ├── summary_en.md
    │       ├── summary_ne.md
    │       ├── action_items.json
    │       ├── decisions.json
    │       └── meeting.json
```

- If `meeting_title` is set, the folder is named `{YYYY-MM-DD_HHmm}_Recording_{slug}`.
- If unset, the folder is named `{YYYY-MM-DD_HHmm}_Recording`.
- Slug is ASCII-safe, lowercase, with spaces replaced by hyphens and special characters stripped.

### 17.3 Upload behaviour

- Uploads happen after post-processing is complete, not during recording.
- Resumable uploads for files > 5 MB via the Drive resumable upload protocol.
- Retry with exponential backoff; surface failures in the UI without blocking.
- User can trigger re-upload manually from the meeting detail view.
- User preference: `Upload audio only`, `Upload all artifacts`, `Do not upload`.

### 17.4 Privacy

- Upload is opt-in per account connection and can be overridden per meeting.
- Files are never made public or shared by the app. The user must share manually via Drive.
- Nothing goes to Drive until the user explicitly connects the account and enables upload.

---

## 18. Storage, Search, and Data Model

### 18.1 Location

- Database: `~/Library/Application Support/Varta/varta.sqlite`.
- Audio and artifacts: `~/Library/Application Support/Varta/meetings/{meeting_uuid}/`.
- Models: `~/Library/Application Support/Varta/models/{whisper,mlx,pyannote,nllb}/`.
- Logs: `~/Library/Logs/Varta/`.

### 18.2 Schema (SQLite via GRDB)

All tables carry `id TEXT PRIMARY KEY` (UUID string), `created_at`, `updated_at`.

**Core tables:**

`meetings`
- `title TEXT`
- `start_time TIMESTAMP`
- `end_time TIMESTAMP NULLABLE`
- `duration_seconds REAL`
- `language_mode TEXT`  — `auto | en | ne | mixed`
- `source_type TEXT`    — `recorded | imported`
- `recording_mode TEXT` — `mic | system | mixed | import`
- `status TEXT`         — `recording | queued | processing | complete | failed | paused`
- `notes_raw TEXT`
- `tags_json TEXT`
- `drive_folder_id TEXT NULLABLE`
- `google_event_id TEXT NULLABLE`
- `apple_event_identifier TEXT NULLABLE`

`audio_files`
- `meeting_id REFERENCES meetings`
- `kind TEXT` — `archive | normalised | segment`
- `path TEXT`
- `sample_rate INTEGER`
- `channels INTEGER`
- `duration_seconds REAL`
- `bytes INTEGER`
- `started_at TIMESTAMP`
- `ended_at TIMESTAMP`

`transcript_segments` — see §12.5.

`diarization_segments`
- `meeting_id`
- `start_seconds REAL`
- `end_seconds REAL`
- `raw_speaker_label TEXT`
- `confidence REAL`

`speakers`
- `meeting_id`
- `raw_label TEXT`
- `alias TEXT NULLABLE`
- `voice_embedding_blob BLOB NULLABLE`
- `color TEXT`

`translations`
- `meeting_id`
- `source_language TEXT`
- `target_language TEXT`
- `content_type TEXT` — `transcript_segment | summary | action_items | ...`
- `source_ref TEXT` — JSON reference to the source row
- `translated_text TEXT`

`summaries`
- `meeting_id`
- `template_name TEXT`
- `language TEXT`
- `summary_type TEXT` — `concise | detailed | bullet | window | section`
- `content TEXT`
- `model_name TEXT`
- `prompt_version TEXT`
- `generated_from_corrected BOOLEAN`
- `stage TEXT` — `map | reduce_l1 | reduce_l2`
- `window_index INTEGER NULLABLE`
- `section_index INTEGER NULLABLE`

`generated_outputs`
- `meeting_id`
- `output_type TEXT` — `action_items | decisions | email | slack | ...`
- `language TEXT`
- `content TEXT`
- `metadata_json TEXT`

`embeddings`
- `meeting_id`
- `segment_id NULLABLE`
- `chunk_index INTEGER`
- `chunk_text TEXT`
- `vector BLOB`  — Float32[384] little-endian
- `vector_dim INTEGER`

`calendar_links`
- `meeting_id`
- `provider TEXT` — `apple | google`
- `event_identifier TEXT`
- `calendar_title TEXT`
- `linked_at TIMESTAMP`

`glossary_terms`
- `term TEXT`
- `canonical_form TEXT`
- `language TEXT`
- `alternate_forms_json TEXT`
- `priority INTEGER`
- `active BOOLEAN`

`jobs`
- `meeting_id NULLABLE`
- `job_type TEXT`
- `status TEXT` — `pending | running | paused | complete | failed`
- `progress REAL`
- `payload_json TEXT`
- `error_message TEXT NULLABLE`
- `attempt_count INTEGER`

`processing_state`
- `meeting_id`
- `stage TEXT`
- `last_completed_window_index INTEGER`
- `last_completed_section_index INTEGER`
- `last_completed_reduction_level INTEGER`
- `checkpoint_json TEXT`

`settings`
- `key TEXT PRIMARY KEY`
- `value_json TEXT`

`tags`
- `name TEXT UNIQUE`
- `color TEXT`

`meeting_tags` — join table.

### 18.3 Indices

- FTS5 virtual table `transcript_segments_fts` on `text_corrected, text`.
- FTS5 virtual table `summaries_fts` on `content`.
- B-tree indices on `meetings.start_time`, `transcript_segments.meeting_id`, `transcript_segments.start_seconds`, `jobs.status`.

### 18.4 Search modes

| Mode | Backing |
|---|---|
| Keyword | FTS5 over transcripts and summaries |
| Full-text | FTS5 with ranking by BM25 |
| Semantic | Flat cosine search over `embeddings.vector`; upgrade to `usearch-swift` when n_chunks > 20k |
| Filtered | SQL composition over tags, date range, language, speaker, meeting type |

---

## 19. UI / UX Specification

### 19.1 Surfaces

| Surface | Purpose |
|---|---|
| Main window — Home | Recent meetings, search bar, start-recording button, job queue |
| Main window — Meeting Detail | Summary / Transcript / Translation / Outputs / Chat / Calendar tabs |
| Main window — Search | Cross-meeting keyword + semantic search |
| Main window — Settings | Models, languages, permissions, connectors, prompts, glossary |
| Menu bar | Quick record, pause, resume, stop; open window |
| Recording HUD | Small always-on-top window with live captions, timer, level meter, stop button |
| Calendar sheet | Proposed event review and confirm |
| Import sheet | File picker with auto-meeting-title from filename |
| Onboarding | Permissions walkthrough + connector offer |

### 19.2 Recording HUD

- 400×80 floating window, semi-transparent, draggable.
- Shows: timer, VU meter, language-detected-badge, live caption (last 2 lines), pause / stop.
- Live caption uses whisper.cpp streaming mode with a 5-second window and 1-second stride.
- Toggle on/off in Settings. Off by default.

### 19.3 Meeting Detail — Transcript tab

- Virtualised list (GRDB-powered DiffableDataSource) scaling to 10k+ segments.
- Each row: timestamp click → seek audio; speaker pill (editable); language pill; text; edit pencil.
- Editing locks the `text_corrected` field and sets `text_locked = true`.
- Top bar: search within transcript, filter by speaker, filter by language, jump to next low-confidence segment.
- Audio player docks at the bottom; keyboard shortcuts for 5s back / forward, 1x / 1.5x / 2x playback speed.

### 19.4 Meeting Detail — Summary tab

- Tabs within the tab: Concise / Detailed / Bullet / Action Items / Decisions / Questions / Email / Slack.
- Language toggle: EN / NE / Bilingual.
- Each section has a regenerate button showing time-since-last-generation and a small "from corrected transcript" indicator.

### 19.5 Meeting Detail — Calendar tab

- Candidate events sorted by start time.
- Each card: editable title / start / end / notes, confidence bar, source transcript quote with timestamp link.
- Create in Apple Calendar or Google Calendar (if connected).

### 19.6 Meeting Detail — Chat tab

- Free-form question box over the meeting.
- Answers include source citations with timestamp links.
- History persists in the meeting row.

### 19.7 Settings

Sections:
- **General** — launch at login, recording HUD, theme.
- **Audio** — default recording mode, sample rate, HUD toggle.
- **Transcription** — model choice, language default, VAD sensitivity, hallucination guard.
- **Diarisation** — enable/disable, Hugging Face token.
- **Summarisation** — Fast / Balanced / Quality / Cloud-assisted, default prompts to edit.
- **Translation** — LLM vs NLLB, glossary editor.
- **Calendar** — Apple calendar picker, Google connect button, auto-event mode, confidence threshold.
- **Google Drive** — connect, folder structure preview, upload rules.
- **Cloud APIs** — Anthropic / OpenAI / Google keys, model choices per provider.
- **Privacy** — delete rules, Spotlight indexing toggle, analytics off-by-default.
- **Shortcuts** — global hotkey for start / stop.

### 19.8 Keyboard shortcuts (defaults)

| Shortcut | Action |
|---|---|
| ⌘ + Shift + R | Start / stop recording |
| ⌘ + K | Command palette |
| ⌘ + F | Search |
| ⌘ + N | New meeting (import audio) |
| Space | Play / pause current segment |
| ⌘ + ← / → | ±5 seconds |
| ⌘ + L | Lock corrected segment |

---

## 20. Optional Cloud API Adapter Layer

### 20.1 Protocols

```swift
protocol TranscriptionProvider {
    func transcribe(audioURL: URL,
                    language: Language?,
                    progress: (@Sendable (Double) -> Void)?) async throws -> Transcript
}

protocol SummarisationProvider {
    func summarise(prompt: String,
                   context: String,
                   maxTokens: Int,
                   temperature: Double) async throws -> String
}

protocol TranslationProvider {
    func translate(text: String,
                   from: Language,
                   to: Language,
                   glossary: [GlossaryTerm]) async throws -> String
}
```

### 20.2 Providers

| Provider | Models wired | Transcription | Summarisation | Translation |
|---|---|---|---|---|
| Local (Whisper + MLX) | whisper.cpp, Llama 3.1 8B, Phi-3.5 mini | ✓ | ✓ | ✓ |
| Anthropic | claude-opus-4-6, claude-sonnet-4-6 | — | ✓ | ✓ |
| OpenAI | gpt-5, gpt-4o-transcribe, whisper-1 | ✓ | ✓ | ✓ |
| Google | gemini-2.5-pro, gemini-2.5-flash | — | ✓ | ✓ |
| Groq | whisper-large-v3-turbo | ✓ | — | — |
| Deepgram | nova-3 | ✓ | — | — |

### 20.3 Configuration

- Each provider slot is selectable per task type: `{ transcription, summarisation, translation, meeting_chat }`.
- Default is `local` for all.
- Keys are stored in Keychain with items keyed by `com.varta.apikey.<provider>`.
- The app must treat the cloud path as strictly opt-in and must not leak transcript data to a cloud provider unless the user has explicitly set that provider for the given task type.

### 20.4 Cost guard

- For each cloud call, show an estimated-cost indicator derived from published per-token pricing.
- A monthly spend cap per provider is configurable. Exceeding the cap disables the provider until the user acknowledges.

---

## 21. Security and Privacy

### 21.1 Data locality

- All meeting data, including audio, transcripts, summaries, embeddings, and generated content, is local by default.
- Cloud egress occurs only when:
  - the user uploads a meeting to Google Drive, or
  - the user enables a cloud API provider for a given task and that task runs.

### 21.2 Permissions

The app requests only what it needs, in this order, on first use:

1. Microphone (AVCaptureDevice.requestAccess).
2. Screen recording (SCShareableContent.excludingDesktopWindows).
3. Calendar (EKEventStore.requestFullAccessToEvents).
4. Google account (ASWebAuthenticationSession — separate flow per connector).

### 21.3 Keychain use

- Google OAuth refresh tokens: `kSecClassGenericPassword`, account = `com.varta.google.<email>`.
- Anthropic, OpenAI, Google AI, Groq, Deepgram, Hugging Face API keys: same pattern.

### 21.4 Delete flows

- Delete meeting: removes `meetings` row, cascade to all dependent tables, deletes the meeting folder on disk.
- Delete audio only: retains transcripts and summaries.
- Redact segment: zeroes `text` and `text_corrected`, tombstones timestamps, removes from FTS and embeddings.

### 21.5 Spotlight

- Off by default.
- When on: only summaries and titles are indexed; transcripts are not published to Spotlight to reduce leakage risk.

### 21.6 Analytics

- None in MVP. No telemetry, no crash reporting SaaS.
- On crash, a local log is written. The user can manually attach it if they report an issue.

---

## 22. Performance Targets

Measured on baseline hardware (M-series MacBook Pro, 16 GB, on AC, no other heavy processes).

| Scenario | Target |
|---|---|
| Cold app launch | < 1.5 s to main window interactive |
| Recording start | < 800 ms from button press to first bytes on disk |
| Transcription throughput | ≥ 4× realtime for 30-min English audio (medium model); ≥ 2× for large-v3 |
| 30-minute English meeting — end-to-end to summary | < 5 minutes |
| 30-minute mixed NE-EN meeting — end-to-end | < 8 minutes |
| 4-hour class meeting — end-to-end | < 45 minutes |
| Search latency (FTS) | < 100 ms for 200-meeting corpus |
| Semantic search latency | < 500 ms for 10k-chunk corpus |
| UI main thread stalls during processing | < 16 ms (60 fps) |

---

## 23. Testing Strategy

### 23.1 Unit tests

- Glossary replacement correctness on Devanagari and Latin scripts.
- Transcript-to-diarisation merge under overlap-tied conditions.
- Window segmentation edge cases (silence at window boundary, code switch at boundary).
- Calendar candidate extraction (date parsing in English and Nepali).
- Checkpoint and resume determinism.
- Memory manager transition rules (reject overlapping acquisitions, release on transition).

### 23.2 Integration tests

- Record → transcribe → summarise happy path.
- Import → transcribe → translate happy path.
- Mid-pipeline kill → relaunch → resume path.
- Apple Calendar event creation round-trip.
- Google Calendar event creation round-trip with mock OAuth.
- Google Drive upload with mock server.

### 23.3 Benchmark corpus

Keep a local test corpus under `test-audio/` (git-ignored, large) covering:

- 5-minute English-only meeting.
- 5-minute Nepali-only conversation.
- 30-minute mixed English-Nepali meeting.
- 4-hour continuous class lecture.
- Overlapping speech stress clip.
- Noisy environment clip.
- Low-volume microphone clip.
- Technical / code-switched clip (MERN, dental terminology).

Each clip has a hand-transcribed gold reference for WER / CER measurement. The CI-equivalent benchmark suite runs on the developer's machine and fails if WER regresses > 5% for any clip.

### 23.4 Acceptance for MVP

The MVP is shippable when all of these hold on the 30-minute mixed clip:

- Transcription produces a readable transcript with segment timestamps.
- Diarisation produces at least two distinct speakers with overlap-based merge.
- Hierarchical Map-Reduce produces a coherent summary, action items list, and decisions list.
- Translation between EN and NE completes on transcript and summary.
- EventKit creates a correctly formatted follow-up event from a scripted line in the audio.
- Nothing leaves the machine unless the user explicitly enabled a connector.

---

## 24. Packaging, Signing, Notarisation

- Xcode build produces a universal `Varta.app` for Apple Silicon only.
- Hardened runtime: enabled.
- Entitlements: microphone, screen-recording, calendar, network-client, network-server (for OAuth redirect loopback), com.apple.security.files.user-selected.read-write.
- App Sandbox: enabled for MVP. The embedded Python worker is code-signed with the same team ID.
- Notarisation: required before distribution. `notarytool submit --wait`.
- Model files are not bundled in `.app`; they download to Application Support on first use with user consent. This keeps the `.app` under 200 MB.
- Python worker runtime is bundled under `Contents/Resources/varta-worker/`. This increases the `.app` by ~200-300 MB but is necessary for the privacy guarantee (no pip install at runtime).

---

## 25. Dependencies

### 25.1 Swift packages

| Package | Purpose |
|---|---|
| `GRDB.swift` | SQLite + FTS5 |
| `mlx-swift`, `mlx-swift-examples` (LLM + embedding modules) | Local inference |
| `WhisperKit` (optional) or custom whisper.cpp bridging | Transcription |
| `swift-collections` | Ordered sets, deque |
| `swift-async-algorithms` | AsyncSequence utilities |
| `KeychainAccess` | Keychain ergonomics |
| `swift-log` | Structured logging |

No Sparkle, no analytics SDKs, no crash reporters in MVP.

### 25.2 Native / C

| Library | Purpose |
|---|---|
| `whisper.cpp` | Transcription core (compiled as XCFramework) |
| `llama.cpp` (fallback) | Optional local LLM alternative to MLX Swift LM |
| `ggml` | Shared model runtime |
| `silero-vad` (ggml-converted) | VAD |

### 25.3 Python (worker only)

| Package | Purpose |
|---|---|
| `pyannote.audio==3.1.1` | Diarisation |
| `torch>=2.4`, `torchaudio` | Pyannote runtime |
| `transformers` (optional) | NLLB translation |
| `numpy`, `scipy` | Standard |

---

## 26. Development Roadmap

### Phase 0 — Skeleton (1 week)

- Xcode project scaffolding.
- GRDB schema bootstrap and migrations.
- Permissions walkthrough.
- whisper.cpp XCFramework integration and model download flow.
- Settings surface (non-functional) with all sections present.

### Phase 1 — Offline Proof (2 weeks)

- File import path: audio in → transcript out → basic summary via MLX Swift LM.
- Hierarchical Map-Reduce summariser with all three tiers (Fast / Balanced / Quality).
- Transcript correction with locking.
- Nepali + English + mixed language modes.
- Glossary table + replacement.
- NLLB or LLM-based translation.

### Phase 2 — Native Recording (1.5 weeks)

- ScreenCaptureKit + AVFoundation recording.
- AVAssetWriter disk streaming.
- 4-hour continuous recording with auto-split.
- Checkpoint and resume on crash.
- Thermal and power hooks.
- Recording HUD.

### Phase 3 — Meeting Detail (1.5 weeks)

- Full meeting detail UI (Summary, Transcript, Translation, Outputs, Chat, Calendar tabs).
- Audio playback with segment click-to-seek.
- Apple Calendar event creation.
- Search (FTS5 keyword).

### Phase 4 — Diarisation (1 week)

- Python worker scaffolding (PyInstaller / python-build-standalone).
- Pyannote integration and merge logic.
- Speaker rename UX.

### Phase 5 — Cloud Sync (1.5 weeks)

- Google OAuth via ASWebAuthenticationSession.
- Google Drive upload with resumable protocol.
- Google Calendar bidirectional sync.
- Per-meeting connector overrides.

### Phase 6 — Semantic Search + Chat (1 week)

- MLX embeddings.
- Flat cosine index in SQLite.
- Meeting chat with citations.

### Phase 7 — Cloud API Adapter Layer (1 week)

- Provider protocols.
- Anthropic, OpenAI, Google, Groq, Deepgram adapters.
- Cost guard and monthly caps.

### Phase 8 — Polish (ongoing)

- Shortcuts.app actions.
- URL scheme `varta://`.
- Spotlight indexing (opt-in).
- Menu bar mini-recorder.
- Voice-embedding-based speaker auto-naming across meetings.
- Pre-meeting briefing from historical context.

Total: approximately 10-11 weeks of focused work for MVP + v1. Estimates assume a single senior engineer working primarily in Swift with Python worker support.

---

## 27. Project Structure

```
Varta/
├── Varta.xcworkspace
├── App/
│   ├── VartaApp.swift
│   ├── AppDelegate.swift            # AppKit bridge for menu bar, global hotkeys
│   └── Onboarding/
├── Features/
│   ├── Home/
│   ├── Recording/
│   ├── MeetingDetail/
│   │   ├── Summary/
│   │   ├── Transcript/
│   │   ├── Translation/
│   │   ├── Outputs/
│   │   ├── Chat/
│   │   └── Calendar/
│   ├── Search/
│   ├── Settings/
│   └── HUD/
├── Services/
│   ├── Recording/
│   │   ├── RecordingSession.swift
│   │   ├── ScreenAudioCapturer.swift
│   │   ├── MicCapturer.swift
│   │   └── AudioFileWriter.swift
│   ├── Transcription/
│   │   ├── WhisperEngine.swift
│   │   ├── VADGate.swift
│   │   └── LanguageRouter.swift
│   ├── Diarisation/
│   │   ├── PyannoteWorker.swift
│   │   └── TranscriptMerger.swift
│   ├── Summarisation/
│   │   ├── MLXLLMEngine.swift
│   │   ├── MapReduceSummariser.swift
│   │   └── PromptLoader.swift
│   ├── Translation/
│   │   ├── LLMTranslator.swift
│   │   └── NLLBWorker.swift
│   ├── Calendar/
│   │   ├── AppleCalendarService.swift
│   │   ├── GoogleCalendarService.swift
│   │   └── CalendarCandidateExtractor.swift
│   ├── Drive/
│   │   ├── GoogleDriveService.swift
│   │   └── UploadQueue.swift
│   ├── Storage/
│   │   ├── Database.swift
│   │   ├── Migrations/
│   │   ├── Repositories/
│   │   └── FTS/
│   ├── Search/
│   │   ├── KeywordSearch.swift
│   │   └── SemanticSearch.swift
│   ├── Chat/
│   │   └── MeetingRAG.swift
│   ├── Memory/
│   │   └── MemoryManager.swift
│   ├── Jobs/
│   │   ├── JobQueue.swift
│   │   ├── Checkpointer.swift
│   │   └── ResumeCoordinator.swift
│   ├── CloudAPIs/
│   │   ├── Providers/
│   │   │   ├── AnthropicProvider.swift
│   │   │   ├── OpenAIProvider.swift
│   │   │   ├── GoogleAIProvider.swift
│   │   │   ├── GroqProvider.swift
│   │   │   └── DeepgramProvider.swift
│   │   └── ProviderRegistry.swift
│   └── System/
│       ├── ThermalMonitor.swift
│       ├── PowerMonitor.swift
│       └── PermissionService.swift
├── Models/                          # Swift data models
├── Resources/
│   ├── Prompts/
│   └── Assets.xcassets
├── Native/
│   ├── whisper-cpp.xcframework
│   └── WhisperBridge/
│       ├── WhisperBridge.h
│       └── WhisperBridge.mm
├── Worker/
│   ├── varta-worker/
│   │   ├── main.py
│   │   ├── pipeline/
│   │   │   ├── diarisation.py
│   │   │   └── translation.py
│   │   ├── io/
│   │   │   └── stdio_protocol.py
│   │   └── requirements.txt
│   └── build-worker.sh              # PyInstaller / python-build-standalone packaging
├── Tests/
│   ├── Unit/
│   └── Integration/
└── docs/
    ├── prompts-reference.md
    ├── ipc-protocol.md
    └── model-download-checklist.md
```

---

## 28. IPC Protocol (Swift ↔ Python Worker)

### 28.1 Spawn

```
/path/to/Varta.app/Contents/Resources/varta-worker/bin/python \
    -m varta_worker --job-type diarisation --audio /tmp/normalised.wav
```

### 28.2 Message shapes

Worker emits newline-delimited JSON on stdout:

```json
{"type": "progress", "stage": "load_model", "value": 0.1}
{"type": "progress", "stage": "diarise",    "value": 0.5}
{"type": "result",   "segments": [{"start": 0.0, "end": 12.3, "speaker": "SPEAKER_00"}]}
{"type": "error",    "code": "MODEL_LOAD_FAILED", "message": "..."}
```

Swift sends input on stdin as a single JSON document and then closes stdin:

```json
{"audio_path": "/tmp/normalised.wav", "min_speakers": 1, "max_speakers": 8}
```

### 28.3 Lifetime

- Single-job worker: spawn → process → emit result → exit.
- No long-running daemon.
- Swift side enforces a 30-minute watchdog; kill and restart on hang.

---

## 29. Key Code Skeletons

### 29.1 MemoryManager

```swift
actor MemoryManager {
    enum Family { case whisper, mlxLM, mlxEmbedding, pyannote, nllb, idle }
    private var current: Family = .idle
    private var releaseHandlers: [Family: () async -> Void] = [:]

    func acquire(_ family: Family, load: () async throws -> Void) async throws {
        if current != family {
            await releaseHandlers[current]?()
            try await load()
            current = family
        }
    }

    func registerReleaseHandler(_ family: Family, _ handler: @escaping () async -> Void) {
        releaseHandlers[family] = handler
    }

    func releaseCurrent() async {
        await releaseHandlers[current]?()
        current = .idle
    }
}
```

### 29.2 RecordingSession outline

```swift
actor RecordingSession {
    private let writer: AVAssetWriter
    private let archiveInput: AVAssetWriterInput
    private let normalisedWriter: AVAudioFile
    private var state: State = .idle
    private var segmentIndex: Int = 0

    func start(title: String?) async throws { /* ScreenCaptureKit + AVFoundation setup */ }
    func pause() async throws { /* flush buffers, commit checkpoint */ }
    func resume() async throws { /* open new writer segment */ }
    func stop() async throws -> RecordingResult { /* finalise, return paths */ }
}
```

### 29.3 MapReduceSummariser outline

```swift
struct MapReduceSummariser {
    let llm: SummarisationProvider
    let checkpointer: Checkpointer
    let memory: MemoryManager

    func summarise(meeting: Meeting,
                   transcript: [TranscriptSegment],
                   mode: SummarisationMode) async throws -> FinalSummary {
        let windows = chunk(transcript, minutesPerWindow: 10, overlapMinutes: 1)
        var windowSummaries: [WindowSummary] = []
        for (i, window) in windows.enumerated() {
            if let cached = try await checkpointer.windowSummary(meeting.id, i) {
                windowSummaries.append(cached); continue
            }
            let summary = try await llm.summarise(prompt: PromptLoader.windowSummary,
                                                  context: window.text,
                                                  maxTokens: 1024,
                                                  temperature: 0.2)
            try await checkpointer.saveWindowSummary(meeting.id, i, summary)
            windowSummaries.append(.init(index: i, content: summary))
        }

        let sections = group(windowSummaries, of: 3)
        var sectionSummaries: [SectionSummary] = []
        for (i, section) in sections.enumerated() {
            if let cached = try await checkpointer.sectionSummary(meeting.id, i) {
                sectionSummaries.append(cached); continue
            }
            let summary = try await llm.summarise(prompt: PromptLoader.sectionSynthesis,
                                                  context: section.joinedText,
                                                  maxTokens: 2048,
                                                  temperature: 0.2)
            try await checkpointer.saveSectionSummary(meeting.id, i, summary)
            sectionSummaries.append(.init(index: i, content: summary))
        }

        let finalInput = sectionSummaries.map(\.content).joined(separator: "\n\n---\n\n")
        let final = try await llm.summarise(prompt: PromptLoader.finalSummary(mode: mode),
                                            context: finalInput,
                                            maxTokens: 4096,
                                            temperature: 0.2)
        try await checkpointer.saveFinalSummary(meeting.id, final)
        return FinalSummary(content: final, sections: sectionSummaries, windows: windowSummaries)
    }
}
```

### 29.4 Checkpointer contract

```swift
protocol Checkpointer {
    func windowSummary(_ meetingId: UUID, _ index: Int) async throws -> WindowSummary?
    func saveWindowSummary(_ meetingId: UUID, _ index: Int, _ content: String) async throws
    func sectionSummary(_ meetingId: UUID, _ index: Int) async throws -> SectionSummary?
    func saveSectionSummary(_ meetingId: UUID, _ index: Int, _ content: String) async throws
    func saveFinalSummary(_ meetingId: UUID, _ content: String) async throws
    func transcriptProgress(_ meetingId: UUID) async throws -> Int
    func saveTranscriptWindow(_ meetingId: UUID, _ window: Int, _ segments: [TranscriptSegment]) async throws
}
```

---

## 30. Prompt Templates (defaults)

The coding agent must ship these as editable files. Content below is the authoritative default.

### 30.1 `window_summary.md`

> You are a meeting note-taker. Summarise the transcript fragment below into a compact structured note. Preserve names, technical terms, numbers, and dates literally.
>
> Output JSON with these keys:
> - `summary`: string, 2-4 sentences.
> - `key_points`: array of 3-8 bullet strings.
> - `action_items`: array of `{task, owner_guess, due_guess, confidence}`.
> - `decisions`: array of `{decision, rationale, confidence}`.
> - `open_questions`: array of `{question, who_raised, confidence}`.
> - `notable_quotes`: array of `{speaker, quote, start_seconds}`.
>
> Be conservative on confidence. Do not invent attendees, dates, or facts not in the text.
>
> Transcript window:
> ---
> {{WINDOW_TEXT}}

### 30.2 `section_synthesis.md`

> You are synthesising 3 consecutive meeting-window summaries into a section summary. Deduplicate, resolve contradictions in favour of later mentions, and preserve any action items or decisions.
>
> Output JSON matching the window summary schema, plus `section_title` (3-6 words).
>
> Window summaries:
> ---
> {{WINDOW_SUMMARIES_JSON}}

### 30.3 `final_summary.md`

> You are composing the final meeting deliverables from section summaries.
>
> Output JSON:
> - `concise_summary`: 3-5 sentence paragraph.
> - `detailed_summary`: up to 800 words.
> - `bullet_summary`: 8-15 bullets.
> - `action_items`: merged and deduplicated.
> - `decisions`: merged and deduplicated.
> - `open_questions`: merged and deduplicated.
> - `follow_up_email`: `{subject, body}`.
> - `calendar_candidates`: `[{title, start_iso, end_iso, notes, confidence}]`.
>
> Section summaries:
> ---
> {{SECTION_SUMMARIES_JSON}}
>
> Meeting metadata:
> - title: {{MEETING_TITLE}}
> - start: {{MEETING_START_ISO}}
> - language_mode: {{LANGUAGE_MODE}}
> - glossary: {{GLOSSARY_JSON}}

### 30.4 `translation.md`

> Translate the following {{SOURCE_LANG}} text into {{TARGET_LANG}}. Preserve:
> - proper nouns (people, companies, products)
> - technical terms from the glossary (below)
> - numbers, dates, and acronyms
>
> Do not produce commentary. Output only the translated text.
>
> Glossary:
> {{GLOSSARY_JSON}}
>
> Text:
> ---
> {{SOURCE_TEXT}}

### 30.5 `calendar_candidates.md`

> Identify any future commitments that should become calendar events. Return JSON:
> - `[{title, start_iso, end_iso, notes, confidence, source_window_index, supporting_quote}]`
>
> Do not fabricate times. If a time is ambiguous (e.g. "next Tuesday"), resolve relative to the meeting start time {{MEETING_START_ISO}} in timezone {{USER_TIMEZONE}}. If a time cannot be resolved with confidence ≥ 0.5, omit the candidate.
>
> Section summaries:
> ---
> {{SECTION_SUMMARIES_JSON}}

### 30.6 `meeting_chat.md`

> Answer the user's question using only the meeting transcript excerpts below. Cite each factual claim with `[segment: <start_seconds>]`. If the answer is not supported by the excerpts, say so and do not speculate.
>
> Question:
> {{QUESTION}}
>
> Retrieved excerpts:
> ---
> {{EXCERPTS_WITH_TIMESTAMPS}}

---

## 31. Configuration

### 31.1 Settings keys (`settings` table)

| Key | Type | Default |
|---|---|---|
| `audio.default_mode` | string | `mixed` |
| `audio.sample_rate` | int | `16000` |
| `transcription.model` | string | `ggml-large-v3-q5_0` |
| `transcription.language_default` | string | `auto` |
| `transcription.vad_threshold` | float | `0.5` |
| `diarisation.enabled` | bool | `true` |
| `diarisation.hf_token` | keychain ref | — |
| `summarisation.mode` | string | `Fast` |
| `summarisation.mlx_model` | string | `mlx-community/Llama-3.1-8B-Instruct-4bit` |
| `summarisation.long_context_model` | string | `mlx-community/Phi-3.5-mini-instruct-4bit` |
| `translation.engine` | string | `llm` |
| `calendar.apple_calendar_id` | string | user-selected |
| `calendar.google_calendar_id` | string | user-selected |
| `calendar.auto_event_mode` | string | `review` |
| `calendar.auto_event_threshold` | float | `0.9` |
| `drive.enabled` | bool | `false` |
| `drive.upload_policy` | string | `artifacts` |
| `cloud.provider.transcription` | string | `local` |
| `cloud.provider.summarisation` | string | `local` |
| `cloud.provider.translation` | string | `local` |
| `cloud.monthly_cap_usd` | float | `0` |
| `privacy.spotlight_indexing` | bool | `false` |
| `hud.enabled` | bool | `false` |
| `recording.auto_split_hours` | int | `4` |

### 31.2 URL scheme

`varta://open/meeting/<uuid>` — opens the meeting detail view.
`varta://record/start` — starts a new recording.
`varta://import?path=<url>` — imports an audio file.

### 31.3 Shortcuts.app actions (v2)

| Action | Inputs | Outputs |
|---|---|---|
| Transcribe File | File reference | Meeting UUID, transcript path |
| Start Recording | Title (optional) | Meeting UUID |
| Stop Recording | — | Meeting UUID |
| Summarise Meeting | Meeting UUID | Summary text |

---

## 32. Build Instructions for the Coding Agent

The agent must follow this order:

1. **Initialise the Xcode project** with the project structure in §27. Enable strict concurrency.
2. **Implement the storage layer first.** GRDB setup, migrations v1, repositories. Unit-test migrations round-trip.
3. **Implement PermissionService** with stubs for mic, screen, calendar. Wire the onboarding flow.
4. **Integrate whisper.cpp** as an XCFramework. Implement `WhisperEngine` with VAD and word timestamps. Ship a model download screen.
5. **Implement MLX Swift LM** wrapper and `MapReduceSummariser`. Ship a model download screen. Verify on a 30-min test clip.
6. **Implement file import path end to end**: import → transcribe → summarise → view. No recording yet.
7. **Implement `RecordingSession`** with AVAssetWriter disk streaming, ScreenCaptureKit, and AVFoundation. Verify with a 30-min live recording.
8. **Implement the 4-hour checkpoint/resume path.** Validate by killing the process mid-transcription.
9. **Build the Python worker** with pyannote. Wire the IPC protocol. Integrate diarisation merge.
10. **Implement Apple Calendar** event creation with confirmation sheet.
11. **Implement keyword search** with FTS5.
12. **Implement Google Drive and Google Calendar** with OAuth flow and resumable upload.
13. **Implement semantic search** with MLX embeddings and meeting chat.
14. **Implement the Cloud API adapter layer** with protocol and provider registrations.
15. **Polish** — HUD, menu bar, Shortcuts, URL scheme.

The agent must **not** skip the storage and permission work to get to transcription. Storage correctness and permission UX are load-bearing for everything else.

The agent must write tests continuously. A stage is not "done" until its unit tests and one integration test pass.

---

## 33. Decisions Log

| # | Decision | Rationale |
|---|---|---|
| D1 | Native Swift/SwiftUI/AppKit, not Electron/Tauri | Apple Silicon first-class target; ScreenCaptureKit / EventKit integration |
| D2 | whisper.cpp over faster-whisper | Native Metal acceleration, no Python packaging for the mainline path |
| D3 | MLX Swift LM over Python MLX | Eliminates a Python worker for the LLM path; direct Metal on Apple Silicon |
| D4 | Pyannote in Python worker, not Swift | No credible native Apple Silicon diarisation exists today; accept the restricted Python surface |
| D5 | Hierarchical Map-Reduce summariser as default | Memory-safe on 16 GB, checkpointable, allows progressive output; optional 128k model for final Reduce only |
| D6 | Spawn-on-demand worker over persistent FastAPI | Smaller attack surface, simpler packaging, sufficient for single-user use |
| D7 | AAC archive + 16 kHz mono WAV processing | Storage efficiency for long classes; WAV needed for Whisper/pyannote |
| D8 | AVAssetWriter disk streaming | Prevents 4-hour in-memory buffer; stable across lid close |
| D9 | SQLite checkpoint every 5 minutes of audio | Bounded data loss window on crash |
| D10 | Local-first; cloud APIs strictly adapter-based | Privacy guarantee, cost control |
| D11 | Per-file Drive scope, not full-drive scope | Minimum-privilege OAuth |
| D12 | Diarisation is disableable and retry-tolerant | Pyannote is the least stable subsystem; must not block the rest |
| D13 | One model family resident at a time | 16 GB baseline correctness |
| D14 | LLM-based translation default, NLLB optional | Avoids spawning Python worker for translation unless user prefers NLLB quality |
| D15 | `temperature = 0.0` + VAD + rolling prompt | Reduces Nepali/code-switch hallucination risk |

---

## 34. Known Risks and Mitigations (v2)

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| whisper.cpp Metal backend regresses on a macOS update | Medium | High | Pin to a known-good whisper.cpp tag; run the benchmark corpus on every macOS update before shipping |
| Pyannote Python packaging breaks signing | Medium | High | Use `python-build-standalone` + PyInstaller one-folder; sign each dylib; test notarisation in Phase 4 |
| MLX Swift LM OOM on 16 GB with long context | Medium | Medium | Enforce Map-Reduce; gate 128k Reduce behind ≥24 GB runtime check |
| Nepali ASR quality below user expectation | High | Medium | Glossary, correction UI, per-segment language tagging, bilingual output, optional cloud transcription for difficult meetings |
| Thermal throttling during 4-hour processing | High | Medium | ProcessInfo.thermalState hooks, inter-window yield, pause on `.critical` |
| Google OAuth token refresh fails silently | Medium | Medium | Keychain storage with refresh-on-401; user-visible connector health indicator |
| Calendar event auto-created incorrectly | Low | Medium | Default to `review` mode; confidence threshold 0.9 for auto; source quote always shown |
| SQLite corruption on crash during write | Low | High | WAL mode, checkpoints every 5 min, quarantine-on-corruption and restore from last-known-good |
| Drive upload saturates residential upstream | Medium | Low | Queue with backoff; pause uploads on metered networks |
| Cloud API cost runaway | Low | Medium | Monthly cap + per-call estimator |

---

## 35. Open Questions for Sir

These are deliberately deferred to avoid blocking the blueprint. The coding agent should implement sensible defaults and surface them in Settings.

1. Which local LLM do you want as the default — Llama 3.1 8B or Qwen 2.5 7B? (Blueprint defaults to Llama 3.1 8B.)
2. Do you want the HUD live-caption window enabled by default or off? (Blueprint defaults off.)
3. For auto-event creation: do you prefer `review always`, `auto at ≥0.9 confidence`, or `draft-only`? (Blueprint defaults `review`.)
4. Should Google Drive upload happen immediately on meeting completion, or only when you explicitly tap "Upload"? (Blueprint defaults `explicit`.)
5. Would you like me to also scaffold a menu bar quick-record mini app in Phase 2, or defer to v2?
6. Preferred app icon style — minimal glyph, audio-waveform motif, or "V" monogram?

---

## 36. Final Notes

This is a serious personal productivity tool, not a demo. It must feel native, trustworthy, and fast. The mainline path must work perfectly with all connectors disabled. Cloud is an amplifier, never a requirement. The 4-hour class scenario is a first-class test case and will gate the MVP; every architectural choice in this document is aimed at making that scenario boring rather than heroic.

If a tradeoff surfaces during implementation, choose in this order: correctness, privacy, usability, speed, convenience.

End of document.
