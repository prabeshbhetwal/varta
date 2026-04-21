# AGENTS.md — Varta Coding Agent Guide

This file is the single navigation guide for any coding agent (OpenAI Codex, Claude Code, or equivalent) working on the Varta codebase. Read this before touching any file.

---

## 1. Authoritative documents

Read these in order before writing any code:

1. `Varta-blueprint-v3.md` — full PRD, architecture, constraints, and decisions log. This is the source of truth.
2. `MVP-build-spec.md` — MVP boundary, acceptance criteria, and build phase order.
3. `TASKS.md` — current task checklist. Track your progress here.
4. `codex-prompts.md` — the structured prompts to use when delegating phases to Codex.

If there is any conflict between files, `Varta-blueprint-v3.md` wins.

---

## 2. Repo layout

```
Varta/
├── Varta.xcworkspace         — open this, not the .xcodeproj directly
├── App/                      — app entry point, AppDelegate, scene config
├── Features/
│   ├── Home/                 — meeting list view
│   ├── Recording/            — recording controls and status
│   ├── MeetingDetail/
│   │   ├── Summary/          — concise, detailed, bullet, action items, decisions
│   │   ├── Transcript/       — virtualised transcript list, correction, seek
│   │   ├── Translation/      — EN/NE output toggle
│   │   ├── Outputs/          — follow-up email, unresolved questions
│   │   └── Calendar/         — calendar candidate review and creation
│   ├── Search/               — FTS keyword search
│   └── Settings/             — permissions, model selection, glossary, prompts
├── Services/
│   ├── Recording/            — RecorderCoordinator, ScreenCaptureKit, AVFoundation
│   ├── Transcription/        — TranscriptionService, whisper.cpp bridge
│   ├── Summarisation/        — SummariserService, MLX Swift LM, Map-Reduce
│   ├── Translation/          — TranslationService, LLM prompt path
│   ├── Calendar/             — CalendarService, EventKit
│   ├── Storage/              — StorageService, GRDB, migrations, FTS5
│   ├── Jobs/                 — JobQueue, Checkpointer, ProcessingState
│   ├── Memory/               — MemoryManager (model lifecycle actor)
│   └── System/               — thermal hooks, power state, sleep/wake
├── Worker/
│   └── varta-worker/         — Python worker (pyannote diarisation), optional
├── Native/
│   └── whisper-cpp.xcframework
├── Models/                   — model weight placeholders and download manifests
├── Resources/
│   └── Prompts/              — editable prompt template files (see Section 5)
├── Tests/                    — unit + integration tests
└── docs/                     — architecture diagrams, decision records
```

---

## 3. Commands to run

### Build
```bash
xcodebuild -workspace Varta.xcworkspace \
           -scheme Varta \
           -destination 'platform=macOS,arch=arm64' \
           build
```

### Test
```bash
xcodebuild -workspace Varta.xcworkspace \
           -scheme VartaTests \
           -destination 'platform=macOS,arch=arm64' \
           test
```

### Lint (SwiftLint, if configured)
```bash
swiftlint lint --strict
```

### Python worker (optional, dev only)
```bash
cd Worker/varta-worker
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python worker.py --mode diarize --input /path/to/audio.wav
```

---

## 4. Standards the agent must follow

### Swift
- Swift 5.10+, strict concurrency mode enabled (`-strict-concurrency=complete`)
- SwiftUI primary; AppKit only as a bridge where SwiftUI cannot reach
- All long-running work must be async and actor-isolated
- No force-unwraps in service layer code
- No `Thread.sleep` — use Swift concurrency primitives

### Storage
- All schema changes go through GRDB migrations — never alter tables manually
- Never store model weights in the database; use the file path
- FTS5 virtual table must be kept in sync with `transcript_segments`

### Audio
- Disk-stream everything; never buffer more than a few seconds in memory
- Archive format: M4A/AAC. Processing format: 16 kHz mono WAV
- Audio files are write-once; never overwrite after finalisation

### Python worker
- IPC is JSON over stdin/stdout only — no REST, no sockets
- The worker must exit after completing a single job
- The app must handle worker failure gracefully at every call site

### Prompt templates
- Prompts live in `Resources/Prompts/` as plain `.txt` files
- Copied to `~/Library/Application Support/Varta/Prompts/` on first launch
- Never hardcode prompt strings in Swift source

---

## 5. Prompt template files (required)

The following prompt files must exist under `Resources/Prompts/`:

```
window-summary.txt
section-synthesis.txt
final-summary.txt
action-items.txt
decisions.txt
unresolved-questions.txt
follow-up-email.txt
calendar-candidates.txt
translation.txt
```

---

## 6. Permissions required

| Permission | Framework | Reason |
|---|---|---|
| Microphone | AVFoundation | Mic recording |
| Screen Recording | ScreenCaptureKit | System audio capture (no video saved) |
| Calendars | EventKit | Apple Calendar event creation |

The Screen Recording permission must be explained in onboarding. Use this exact wording:

> "macOS requires Screen Recording permission to capture system audio. Varta uses this permission only to extract audio unless you explicitly choose to capture video in a future version."

---

## 7. MVP boundary — hard rules

**Do not build any of the following in the first autonomous pass:**

- Google Drive upload
- Google Calendar sync
- Semantic search or embeddings
- Meeting chat or RAG
- Cloud API adapters
- Live-caption HUD
- Menu bar mini-app
- Spotlight indexing
- Shortcuts.app support
- URL scheme
- Auto-recording from calendar triggers
- Obsidian / Notes / Notion export

If a task seems to require one of the above, stop and report the blocker rather than quietly building it.

---

## 8. Build order (authoritative)

Follow this exact order. Do not jump ahead.

1. Initialise Xcode project with strict concurrency
2. Build storage layer (GRDB migrations, all core tables)
3. Implement permissions and onboarding flow
4. Integrate whisper.cpp (Metal backend)
5. Implement MLX Swift LM summarisation (Llama 3.1 8B)
6. Build import path end to end (file → transcript → summary)
7. Build transcript review and correction UI
8. Build native recording path (mic + system audio)
9. Build 4-hour checkpoint and resume handling
10. Build Apple Calendar suggestion and manual creation
11. Build FTS keyword search
12. Attempt optional diarisation worker (Python, non-blocking)
13. Stop — do not build post-MVP features

---

## 9. If you are blocked

- Stop immediately
- Do not guess at missing information
- Report the exact blocker: file, function, system call, or permission
- Do not silently expand scope to work around the blocker

---

## 10. Testing requirements

Before marking any phase done, the following must pass:

- All unit tests in `Tests/` for that phase's services
- The integration test for that phase's end-to-end path
- No force-unwrap crashes in debug build
- `xcodebuild test` exits 0

See `Varta-blueprint-v3.md` Section 21 for the full test strategy and benchmark corpus requirements.
