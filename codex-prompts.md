# Codex Prompts — Varta Build

Each section below is a self-contained prompt to send to Codex for one build phase. Use the 7-part structure that Codex expects: Goal, Scope, Files allowed to change, Files not allowed to change, Acceptance criteria, Commands to run, What to do if blocked.

Send one phase prompt at a time. Do not send Phase 1 until Phase 0 is complete and verified.

---

## Phase 0 — Skeleton

```
Goal:
Scaffold the Varta macOS app. Initialise the Xcode workspace, enable strict Swift concurrency, set up GRDB, write all database migrations, and implement the three permission flows (Microphone, Screen Recording, Calendar). Build a navigable Settings shell and an onboarding view.

Scope:
Project scaffolding, storage layer, migrations, permissions, onboarding, settings shell. Nothing else.

Files allowed to change:
- Varta.xcworkspace and all .xcodeproj contents
- App/ (entry point, scene configuration)
- Services/Storage/ (StorageService, migrations)
- Features/Settings/ (shell UI only, no functional settings yet)
- Varta/Resources/ (Info.plist, entitlements)
- Any new source files needed for the above

Files not allowed to change:
- Worker/ (Python worker — do not touch)
- Features/Recording/ (not yet)
- Features/MeetingDetail/ (not yet)
- Any cloud, Google, or post-MVP related files

Acceptance criteria:
- xcodebuild build exits 0 for macOS arm64 target
- App launches without crash on a clean install
- GRDB migrations apply on first launch (all core tables created)
- Microphone permission dialog appears when triggered
- Screen Recording permission dialog appears with correct explanation wording
- Calendar permission dialog appears when triggered
- Settings view is navigable (no crashes, values persist to settings table)

Commands to run:
xcodebuild -workspace Varta.xcworkspace -scheme Varta -destination 'platform=macOS,arch=arm64' build
xcodebuild -workspace Varta.xcworkspace -scheme VartaTests -destination 'platform=macOS,arch=arm64' test

What to do if blocked:
Stop immediately. Report the exact file, line, or system call causing the block. Do not guess. Do not expand scope to work around it.
```

---

## Phase 1 — Local import proof

```
Goal:
Implement the full local import loop: import an audio or video file, transcribe it with whisper.cpp (Metal backend), review and correct the transcript, generate a local AI summary and structured outputs (action items, decisions, questions, email, calendar candidates), and translate outputs between English and Nepali using the local LLM.

Scope:
File import, whisper.cpp integration, TranscriptionService, transcript viewer, transcript correction, glossary, MLX Swift LM integration, SummariserService (hierarchical Map-Reduce), TranslationService, editable prompt templates.

Files allowed to change:
- Features/Home/ (show imported meeting in list)
- Features/MeetingDetail/Summary/
- Features/MeetingDetail/Transcript/
- Features/MeetingDetail/Translation/
- Features/MeetingDetail/Outputs/
- Services/Transcription/
- Services/Summarisation/
- Services/Translation/
- Services/Storage/ (new queries only, no schema changes without migrations)
- Services/Memory/ (MemoryManager actor)
- Native/whisper-cpp.xcframework
- Models/ (model download manifest)
- Resources/Prompts/ (all prompt template files)

Files not allowed to change:
- Services/Recording/ (not yet)
- Worker/ (not yet)
- Features/Recording/ (not yet)
- Features/MeetingDetail/Calendar/ (not yet)
- Features/Search/ (not yet)
- Anything Google, cloud, or post-MVP

Acceptance criteria:
- File picker accepts audio (mp3, m4a, wav, aiff) and video (mp4, mov, m4v) formats
- Imported audio produces a timestamped transcript in the viewer
- Transcript segments can be edited and locked (raw text preserved separately)
- Glossary terms are applied before summarisation
- Concise, detailed, and bullet summaries are generated on-device
- Action items, decisions, unresolved questions, and follow-up email are generated
- EN↔NE translation works for all outputs
- Prompt files exist under Resources/Prompts/ and are copied to Application Support on first launch
- Unit tests pass: glossary replacement, language tagging, transcript correction locking
- Integration test passes: import file → transcript → summary → translation

Commands to run:
xcodebuild -workspace Varta.xcworkspace -scheme Varta -destination 'platform=macOS,arch=arm64' build
xcodebuild -workspace Varta.xcworkspace -scheme VartaTests -destination 'platform=macOS,arch=arm64' test

What to do if blocked:
Stop immediately. Report exact blocker. Do not attempt to build cloud translation, Google APIs, or any post-MVP feature as a workaround.
```

---

## Phase 2 — Native recording

```
Goal:
Implement native audio recording: microphone and system audio (ScreenCaptureKit), disk-streamed to disk, checkpointed, and resumable. The app must handle 4 continuous hours of recording without crash, survive a lid-close/wake cycle, and respond to thermal and power state changes.

Scope:
RecorderCoordinator actor, ScreenCaptureKit system audio, AVFoundation microphone, AVAssetWriter disk streaming, JobQueue, Checkpointer, ProcessingState, thermal hooks, power hooks, sleep/wake handling. Recording controls UI.

Files allowed to change:
- Features/Recording/ (recording controls UI)
- Services/Recording/ (RecorderCoordinator, all recording logic)
- Services/Jobs/ (JobQueue, Checkpointer, ProcessingState)
- Services/System/ (thermal, power, sleep/wake)
- Services/Storage/ (new queries for job and checkpoint state — migrations required for any schema change)

Files not allowed to change:
- Services/Transcription/ (do not modify the transcription logic)
- Services/Summarisation/ (do not modify)
- Worker/ (not yet)
- Features/MeetingDetail/Calendar/ (not yet)
- Features/Search/ (not yet)
- Any Google, cloud, or post-MVP files

Acceptance criteria:
- Recording starts within 1.5 s of user tapping record
- System audio and microphone are captured and mixed
- Audio is streamed to disk in M4A/AAC format; in-memory buffer does not exceed a few seconds
- 4-hour recording session completes without crash or data loss
- Transcript checkpoints are committed to SQLite at regular intervals
- Lid-close mid-session: app flushes writer and checkpoints state
- Wake after lid-close: app resumes processing from last checkpoint without data loss
- ProcessInfo.thermalState critical: heavy processing pauses; recording continues
- Battery state: concurrency reduced appropriately
- Unit tests pass: checkpoint logic, MemoryManager lifecycle transitions
- Integration test passes: crash → relaunch → processing resumes

Commands to run:
xcodebuild -workspace Varta.xcworkspace -scheme Varta -destination 'platform=macOS,arch=arm64' build
xcodebuild -workspace Varta.xcworkspace -scheme VartaTests -destination 'platform=macOS,arch=arm64' test

What to do if blocked:
Stop immediately. Report exact blocker (e.g., ScreenCaptureKit entitlement issue, AVAssetWriter format error). Do not work around a signing or entitlement issue by disabling the permission check.
```

---

## Phase 3 — Meeting detail completion

```
Goal:
Complete the meeting detail UI with all tabs (Summary, Transcript, Translation, Outputs, Calendar). Implement Apple Calendar event suggestion, review sheet, and EventKit manual creation. Implement FTS keyword search across meetings and transcripts.

Scope:
Meeting detail tabs, calendar candidate display, EventKit creation, calendar_links storage, FTS search view and queries.

Files allowed to change:
- Features/MeetingDetail/Summary/
- Features/MeetingDetail/Transcript/
- Features/MeetingDetail/Translation/
- Features/MeetingDetail/Outputs/
- Features/MeetingDetail/Calendar/
- Features/Search/
- Services/Calendar/ (CalendarService, EventKit)
- Services/Storage/ (FTS queries, calendar_links queries — migrations for any schema change)

Files not allowed to change:
- Services/Recording/ (do not modify)
- Services/Transcription/ (do not modify)
- Services/Summarisation/ (do not modify)
- Worker/ (not yet)
- Any Google Calendar, Google Drive, or post-MVP files

Acceptance criteria:
- Meeting detail has five tabs: Summary, Transcript, Translation, Outputs, Calendar
- Summary tab shows all output types including follow-up email
- Transcript tab has virtualised list, click-to-seek, correction, language and speaker pills
- Calendar tab lists extracted event candidates with title, date, time, and attendees if available
- User can confirm a candidate: EventKit creates the event in Apple Calendar
- calendar_links record stored after creation
- FTS search returns results within 300 ms for a typical corpus
- Search results link to the correct meeting and scroll to the correct segment
- Integration tests pass: FTS returns correct results; calendar event created in Apple Calendar

Commands to run:
xcodebuild -workspace Varta.xcworkspace -scheme Varta -destination 'platform=macOS,arch=arm64' build
xcodebuild -workspace Varta.xcworkspace -scheme VartaTests -destination 'platform=macOS,arch=arm64' test

What to do if blocked:
Stop immediately. If EventKit denies access, report the entitlement gap. Do not substitute Google Calendar or any other calendar service.
```

---

## Phase 4 — Optional diarisation

```
Goal:
Add the optional Python diarisation worker (pyannote.audio). The worker is spawned on demand, processes one job over JSON/stdio, and exits. If it fails for any reason, the app must still function completely without speaker labels.

Scope:
varta-worker Python package, JSON IPC protocol, DiarisationClient Swift caller, merge logic, graceful failure paths, speaker pill UI.

Files allowed to change:
- Worker/varta-worker/ (all Python worker code)
- Services/Recording/ (DiarisationClient caller only)
- Services/Storage/ (diarization_segments queries)
- Features/MeetingDetail/Transcript/ (speaker pill display, unavailable indicator)

Files not allowed to change:
- Services/Transcription/ (do not modify transcription logic)
- Services/Summarisation/ (do not modify)
- Services/Calendar/ (do not modify)
- Features/Search/ (do not modify)
- Any Google, cloud, or post-MVP files

Acceptance criteria:
- Worker receives a JSON payload with audio path and emits diarisation segments as JSON
- Worker exits after completing one job
- Speaker labels appear on transcript segments when diarisation succeeds
- Worker crash or timeout: app logs the failure and continues without speaker labels
- "Speaker separation unavailable" indicator shown in UI when worker failed
- All Phase 0–3 tests still pass
- Integration test: worker runs → segments labelled correctly
- Integration test: worker crash → transcription + summary complete successfully

Commands to run:
cd Worker/varta-worker && python -m pytest tests/
xcodebuild -workspace Varta.xcworkspace -scheme Varta -destination 'platform=macOS,arch=arm64' build
xcodebuild -workspace Varta.xcworkspace -scheme VartaTests -destination 'platform=macOS,arch=arm64' test

What to do if blocked:
If pyannote packaging breaks notarisation or hardened runtime, stop and report. Do not attempt to disable the hardened runtime or bypass Gatekeeper. The app must ship without diarisation if packaging cannot be resolved cleanly.
```

---

## Notes on prompting Codex

- Send one phase at a time. Verify acceptance criteria fully before moving to the next.
- If Codex asks for clarification, direct it to `Varta-blueprint-v3.md` Section [N] for the relevant spec.
- If Codex produces code that touches a post-MVP file, reject the output and re-send the prompt with an explicit note that the file is out of scope.
- The 7-part structure (Goal / Scope / Allowed / Not allowed / Acceptance criteria / Commands / If blocked) is load-bearing — do not shorten it when sending to Codex.
