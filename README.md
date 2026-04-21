# Varta

**Nepali-aware, Apple Silicon-native AI meeting assistant.**

Varta records, transcribes, summarises, translates, and files meetings — entirely on-device, by default. Built for a bilingual (English + Nepali + code-switched) user. Feels like a native macOS app because it is one.

---

## What it does

- Records microphone and/or system audio
- Imports audio and video files
- Transcribes with timestamps using whisper.cpp (Metal-accelerated)
- Lets you review and correct the transcript
- Generates local AI summaries, action items, and decisions via MLX Swift LM
- Translates outputs between English and Nepali
- Suggests future Apple Calendar events and supports manual creation via EventKit
- Stores everything locally in SQLite — no cloud required

---

## Platform

| Requirement | Detail |
|---|---|
| OS | macOS 14 (Sonoma) or later |
| Chip | Apple Silicon only |
| Memory | 16 GB minimum, 32 GB recommended |
| Disk | 20 GB free minimum (models + audio + database) |

---

## Architecture in brief

```
Varta.app (native Swift process)
  ├── SwiftUI UI layer
  ├── Core services (Swift)
  │   ├── RecorderCoordinator       — ScreenCaptureKit + AVFoundation
  │   ├── TranscriptionService      — whisper.cpp + Metal
  │   ├── SummariserService         — MLX Swift LM (Llama 3.1 8B)
  │   ├── TranslationService        — local LLM prompt path
  │   ├── CalendarService           — EventKit
  │   ├── StorageService            — GRDB + SQLite + FTS5
  │   ├── JobQueue / Checkpointer   — resumable processing
  │   └── MemoryManager             — one model family resident at a time
  └── varta-worker (Python, optional)
      └── pyannote diarisation      — spawned on demand, exits after job
```

The Python worker is a soft dependency. If it fails, the app still fully functions without speaker separation.

---

## Default settings

| Setting | Default |
|---|---|
| Local LLM | Llama 3.1 8B |
| Live-caption HUD | Off |
| Calendar event creation | Review always (manual confirm) |
| Google Drive upload | Post-MVP |
| Menu bar app | Post-MVP |

---

## Data storage

All data lives on-device:

```
~/Library/Application Support/Varta/
  ├── varta.sqlite          — main database
  ├── meetings/{uuid}/      — audio + artifacts per meeting
  └── models/               — whisper + LLM weights

~/Library/Logs/Varta/       — application logs
```

---

## MVP scope

The MVP is intentionally narrow. See `MVP-build-spec.md` for the full boundary.

**In MVP:** recording, import, transcription, correction, summarisation, translation, calendar suggestion, FTS search, local storage, optional diarisation.

**Post-MVP:** Google Drive, Google Calendar, semantic search, meeting chat, cloud APIs, live-caption HUD, menu bar app, Spotlight, Shortcuts, URL scheme.

---

## Project documents

| File | Purpose |
|---|---|
| `Varta-blueprint-v3.md` | Full PRD + architecture + technical spec |
| `MVP-build-spec.md` | MVP boundary, acceptance criteria, build order |
| `AGENTS.md` | Guide for coding agents (Codex, Claude Code) |
| `TASKS.md` | Phase-by-phase task checklist |
| `codex-prompts.md` | Structured prompts to send to Codex per phase |

---

## Build order (for coding agents)

See `AGENTS.md` and `codex-prompts.md`. The authoritative build order is in Section 26 of `Varta-blueprint-v3.md`.

---

## Principles

1. Correctness over speed
2. Privacy over convenience
3. Native over cross-platform
4. Diarisation is optional, never load-bearing
5. Post-MVP features must not contaminate the MVP build
