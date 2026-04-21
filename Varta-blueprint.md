# Nepali-Aware Local AI Meeting Assistant for macOS (Apple Silicon)
**Document Type:** Product Requirements Document + Technical Architecture + Build Blueprint  
**Target Build Agent:** OpenAI Codex / Claude Code / Claude Desktop Agent  
**Platform:** Native macOS desktop app, Apple Silicon only  
**Authoring Goal:** This document is intended to be complete enough for an autonomous coding agent to implement the application without needing a separate PRD.  
**Project Type:** Personal-use desktop application  
**Primary Principle:** Free-first, local-first, privacy-first, Apple-native, and as powerful as possible using free/open-source components and built-in macOS frameworks.

---

## 1. Executive Summary

Build a **native macOS desktop application** that functions like a private, local-first version of Granola-style AI meeting notes, but optimized for **Apple Silicon** and designed to support **English, Nepali, and mixed English-Nepali conversations**.

The app must be able to:

- Record meeting audio from the Mac
- Capture **system audio** and optionally microphone audio
- Transcribe meetings locally
- Detect and separate speakers
- Support Nepali-language transcription and bilingual workflows
- Summarize meetings into multiple useful formats
- Translate transcript content between Nepali and English
- Generate follow-up content such as emails, action items, task lists, and decision logs
- Search and chat over past meetings
- Optionally create a **Calendar event** from the meeting notes, either automatically or via user confirmation
- Run primarily on-device using free native frameworks and open-source models, with a clean architecture that allows future optional paid cloud adapters without rewriting the app

This application is **not a web app**. It is a **desktop app for macOS on Apple Silicon only**.

---

## 2. Product Vision

The application should feel like a cross between:

- a **meeting recorder**
- an **AI notepad**
- a **personal meeting memory system**
- a **meeting-to-calendar and meeting-to-output workflow engine**

The product should prioritize:

1. **Privacy**  
   Audio, transcripts, summaries, embeddings, and generated outputs should remain local by default.

2. **Accuracy**  
   Focus on strong transcript quality, especially for mixed-language and low-resource Nepali use cases.

3. **Usefulness over novelty**  
   The generated outputs should be immediately practical:
   - concise meeting summary
   - action items with owners
   - key decisions
   - unresolved questions
   - follow-up email
   - translated summary
   - searchable memory

4. **Apple-native performance**  
   Use Apple-native frameworks and Apple Silicon optimized local inference wherever possible.

5. **Free-first architecture**  
   The MVP must work without requiring paid APIs.

---

## 3. Product Goals

### 3.1 Primary Goals
- Build a **fully local, free-first macOS AI meeting assistant**
- Achieve usable **English + Nepali** transcription
- Support **speaker diarization**
- Generate high-quality post-meeting notes and outputs
- Allow the user to query and search previous meetings
- Integrate with **Apple Calendar** using EventKit

### 3.2 Secondary Goals
- Allow transcript correction and glossary-based post-processing
- Provide bilingual transcript and bilingual summary views
- Support multiple meeting note templates
- Provide export formats such as Markdown, plain text, JSON, and optionally PDF later

### 3.3 Non-Goals for MVP
Do **not** build these in MVP unless they fall out naturally from the core system:
- multi-user cloud collaboration
- browser access
- SaaS billing
- enterprise admin console
- automatic meeting joins as a bot
- CRM integrations
- external sharing links
- cloud sync by default

---

## 4. Product Definition

### 4.1 Core Product Statement
A native macOS app that records meetings locally, transcribes them with speaker attribution, supports Nepali and English, generates structured AI notes, enables local search and chat over meetings, and can create calendar events from meeting content.

### 4.2 Primary Users
- Personal user
- Solo professional
- Developer / analyst / researcher
- Bilingual or multilingual user, especially English + Nepali

### 4.3 Key User Scenarios
1. Record a Zoom, Meet, or Teams meeting directly on the Mac
2. Record an in-person conversation using microphone input
3. Generate a clean meeting summary with action items afterward
4. Translate a Nepali meeting into English
5. Translate an English meeting summary into Nepali
6. Search old meetings for decisions, dates, and commitments
7. Create a calendar event from meeting notes or detected future commitments

---

## 5. Constraints and Assumptions

### 5.1 Platform Constraints
- macOS only
- Apple Silicon only
- Must support current supported macOS versions where ScreenCaptureKit and EventKit are practical
- Must be optimized for local inference on Apple Silicon

### 5.2 Hardware Assumptions
Baseline target machine:
- Apple Silicon MacBook Pro / Mac mini / Mac Studio
- 16 GB unified memory minimum
- Better experience on 32 GB+ machines, but 16 GB should remain viable

### 5.3 Personal-Use Assumption
This is a personal-use application. Therefore:
- local storage is acceptable
- single-user local database is acceptable
- identity/authentication is not needed for MVP
- collaboration is not required in MVP

---

## 6. “Free + Most Powerful APIs” Interpretation

This request contains a tension:
- “completely free”
- “most powerful APIs”

The design must resolve this honestly.

### 6.1 Final Interpretation
The app should use the **most powerful free or built-in APIs first**, in this order:

1. **Native macOS APIs**
   - ScreenCaptureKit
   - AVFoundation
   - EventKit
   - AppKit / SwiftUI
   - FileManager / Core Data alternatives avoided in favor of SQLite for portability

2. **Powerful open-source local models**
   - faster-whisper
   - WhisperX
   - pyannote.audio
   - MLX / MLX-LM
   - NLLB

3. **Optional API adapter layer**
   - Keep the code structured so paid APIs can be added later
   - Paid APIs must not be required for MVP

### 6.2 Final Rule
The MVP must run with:
- **no paid cloud APIs**
- **no monthly subscription**
- **no external dependency required for core functionality**

---

## 7. Recommended Final Tech Stack

This is the **recommended implementation stack**.

### 7.1 Desktop Application Layer
- **Language:** Swift
- **UI:** SwiftUI first
- **Native integrations / advanced macOS hooks:** AppKit bridge only where needed
- **Reason:** Native Apple Silicon desktop experience, best integration with permissions, ScreenCaptureKit, EventKit, menus, windows, and performance

### 7.2 ML / Processing Layer
- **Primary processing runtime:** Python
- **Reason:** Best ecosystem for transcription, diarization, alignment, translation, and local model tooling
- The Swift app should coordinate a local Python worker / service process

### 7.3 Local LLM Runtime
- **Preferred:** MLX / MLX-LM on Apple Silicon
- **Fallback abstraction:** Ollama adapter or llama.cpp-compatible adapter if needed
- **Reason:** MLX is optimized for Apple Silicon and fits the local-first requirement

### 7.4 Local Database
- **SQLite**
- Reason:
  - single-user local app
  - fast enough
  - easy backup
  - robust
  - simple for autonomous coding agents to implement

### 7.5 Search / Retrieval
- SQLite FTS for keyword search
- Chroma or LanceDB or a lightweight local vector index for semantic search
- Embeddings stored locally

### 7.6 File Storage
Per-meeting local folder + metadata in SQLite

---

## 8. Native macOS Framework Requirements

### 8.1 ScreenCaptureKit
Use for:
- capturing system audio from on-screen meeting apps
- high-performance media capture

### 8.2 AVFoundation
Use for:
- microphone capture
- local audio session coordination
- audio format normalization if needed

### 8.3 EventKit
Use for:
- reading user calendar access when permitted
- creating calendar events from meeting notes
- optional calendar lookup for meeting context

### 8.4 SwiftUI
Use for:
- all primary UI surfaces

### 8.5 AppKit
Use only where SwiftUI is insufficient, including:
- advanced menu integration
- status bar / menu bar functionality if needed
- more granular macOS window behavior
- permission workflows that are easier with AppKit wrappers

---

## 9. High-Level Architecture

### 9.1 Top-Level Components
1. **Native macOS host app (Swift/SwiftUI)**
2. **Audio capture subsystem**
3. **Python processing engine**
4. **Local inference manager**
5. **Meeting storage and indexing layer**
6. **Calendar integration layer**
7. **Prompt/template engine**
8. **Search/chat subsystem**

### 9.2 Process Architecture
The native app should remain responsive and should **not** perform heavy ML inference directly in the main UI process.

#### Recommended approach
- SwiftUI host application launches and manages:
  - a local Python worker
  - or multiple subprocesses for transcription, alignment, diarization, translation, and summarization
- Communication via:
  - local IPC
  - local HTTP on loopback
  - or stdin/stdout process protocol
- Prefer a clean, explicit service boundary

### 9.3 Recommended Runtime Split
#### Swift app responsibilities
- Permissions
- Recording start/stop
- UI
- Job queue
- File organization
- Database writes
- Search UX
- Calendar sync UX

#### Python worker responsibilities
- STT
- alignment
- diarization
- translation
- summarization orchestration
- embeddings generation
- search preprocessing

---

## 10. End-to-End Workflow

### 10.1 Recording Workflow
1. User opens app
2. User clicks **Start Recording**
3. User chooses source mode:
   - system audio only
   - microphone only
   - mixed system + microphone
4. App requests required permissions if not already granted
5. App begins recording
6. App writes raw audio to meeting folder
7. User clicks **Stop Recording**
8. App finalizes audio file
9. App queues processing pipeline

### 10.2 Processing Workflow
1. Normalize audio
2. Run voice activity detection
3. Run transcription
4. Run timestamp alignment
5. Run diarization
6. Merge transcript + diarization
7. Detect per-segment language where possible
8. Generate transcript artifacts
9. Generate summaries and structured outputs
10. Generate translations
11. Generate embeddings
12. Save results to DB and files
13. Mark meeting as searchable

### 10.3 Calendar Event Workflow
1. Summarization / extraction step identifies:
   - future date/time commitments
   - follow-up meetings
   - deadlines
   - appointments
2. Calendar extraction engine builds candidate event objects
3. User sees:
   - title
   - date/time
   - notes
   - attendees if inferable
4. User confirms or edits
5. App creates event via EventKit

#### Optional automation mode
Allow a user preference:
- “Always ask before creating event”
- “Create draft event only”
- “Auto-create event when confidence exceeds threshold”
Default must be **ask before creating**

---

## 11. Core Feature Set

### 11.1 Recording
Must support:
- Start / Stop recording
- Visible timer
- Recording state indicator
- Save audio locally
- Record from:
  - microphone
  - system audio
  - both when possible

### 11.2 Transcription
Must support:
- local transcription
- English
- Nepali
- mixed-language handling as best effort
- timestamped output
- transcript correction

### 11.3 Speaker Diarization
Must support:
- speaker segmentation
- speaker labels such as Speaker 1, Speaker 2
- optionally allow user rename after the meeting

### 11.4 Summarization
Must support at minimum:
- concise summary
- detailed summary
- action items
- decisions
- unresolved questions
- follow-up email draft
- task list

### 11.5 Translation
Must support:
- transcript English → Nepali
- transcript Nepali → English
- summary English → Nepali
- summary Nepali → English
- preserve names, acronyms, and glossary terms

### 11.6 Search and Chat
Must support:
- keyword search
- full-text search
- semantic search
- chat with meeting transcript
- filtering by date, speaker, meeting title

### 11.7 Calendar Sync
Must support:
- Apple Calendar access
- event creation from extracted commitments
- optional read existing event context when permission is granted

### 11.8 Export
Must support:
- Markdown export
- Plain text export
- JSON export
- Copy summary to clipboard

---

## 12. Audio Capture Requirements

### 12.1 Supported Recording Modes
1. **System audio only**
2. **Microphone only**
3. **System + microphone**
4. **Manual file import** for audio/video recordings

### 12.2 Audio File Requirements
Preferred storage format:
- WAV during processing
- optionally FLAC archive later if desired

### 12.3 Audio Normalization
Normalize all audio to pipeline input standard:
- mono when required by downstream model
- 16 kHz for ASR / diarization if needed
- preserve original raw file as archive

### 12.4 Important OS-Level Behavior
- System audio capture support varies by macOS version and configuration
- On supported macOS versions, use ScreenCaptureKit-based audio capture
- For mixed microphone + system capture, design a robust fallback path

### 12.5 Failure Handling
If direct system-audio capture fails:
- allow user to import recording manually
- show explicit error states
- do not silently fail

---

## 13. STT (Speech-to-Text) Requirements

### 13.1 Chosen Primary STT Engine
- **faster-whisper**

### 13.2 Why
- fast
- strong multilingual performance
- efficient on local hardware
- suitable for long-form meeting transcription

### 13.3 Model Strategy
Use configurable model profiles:
- **Default Balanced:** `large-v3` or fastest practical equivalent
- **Low Memory:** smaller model
- **High Accuracy:** larger multilingual model if hardware allows

### 13.4 Runtime Profiles
Provide a settings option:
- Speed mode
- Balanced mode
- Accuracy mode

### 13.5 Transcript Output Requirements
Each segment must contain:
- segment id
- start time
- end time
- text
- detected language if available
- confidence if available
- speaker label after merge

---

## 14. Timestamp Alignment Requirements

### 14.1 Chosen Tool
- **WhisperX**

### 14.2 Purpose
Use WhisperX after base transcription to improve:
- segment boundaries
- word-level timestamps
- sync between transcript and playback
- transcript seek accuracy
- alignment with speaker diarization windows

### 14.3 Result
The UI must be able to:
- click transcript line
- jump to timestamp
- highlight current segment during playback

---

## 15. Speaker Diarization Requirements

### 15.1 Chosen Tool
- **pyannote.audio**

### 15.2 Output Requirements
Generate speaker turns as:
- speaker label
- start time
- end time

### 15.3 Merge Logic
After transcription and alignment:
- assign transcript segments to the most overlapping diarized speaker segment
- allow confidence-based tie handling
- store raw diarization and merged results separately

### 15.4 Speaker Naming
MVP:
- Speaker 1
- Speaker 2
- Speaker 3

Post-MVP:
- allow manual renaming
- persist aliases across meetings if user chooses

---

## 16. Nepali Language Requirements

### 16.1 Critical Requirement
The application must explicitly support:
- Nepali transcription
- Nepali translation
- English-Nepali mixed conversations

### 16.2 Practical Reality
Nepali transcription quality may be lower than English depending on:
- accent variation
- microphone quality
- overlapping speakers
- code-switching
- technical vocabulary
- named entities

The product must be designed to compensate with:
- glossary support
- correction UI
- segment-by-segment language tagging
- post-processing cleanup

### 16.3 Language Handling Modes
Add a user setting:
- Auto detect
- English only
- Nepali only
- Mixed English + Nepali

### 16.4 Per-Segment Language Detection
Because mixed-language meetings are common, the pipeline should attempt to assign a detected language per segment where possible.

### 16.5 Transcript Editing Support
The user must be able to:
- edit incorrect Nepali transcript text
- lock corrected text
- regenerate summaries from corrected transcript

### 16.6 Glossary Support
Implement a local glossary table for:
- names
- company names
- project names
- acronyms
- domain-specific vocabulary
- Nepali transliterations

Glossary entries should support:
- canonical form
- alternate spellings
- language-specific forms
- replacement priority

---

## 17. Translation Requirements

### 17.1 Chosen Translation Engine
- **NLLB family**, local if feasible

### 17.2 Translation Targets
Support:
- English → Nepali
- Nepali → English

### 17.3 Translation Quality Rules
The translator must:
- preserve names
- preserve technical terms where appropriate
- avoid literal mistranslation of product names and jargon
- respect glossary overrides

### 17.4 Translation Modes
1. Translate transcript
2. Translate summary
3. Translate action items
4. Translate decisions
5. Translate generated email

### 17.5 Bilingual UX
The meeting detail view should allow:
- original only
- translated only
- side-by-side bilingual mode

---

## 18. LLM Summarization and Content Generation

### 18.1 Preferred Local Inference Stack
- **MLX / MLX-LM**

### 18.2 Why
- optimized for Apple Silicon
- local-first
- strong future compatibility with Apple hardware
- avoids paid APIs

### 18.3 Model Strategy
Use an abstraction layer so the user can choose among local models.

Recommended default class:
- compact instruct model in roughly 7B–8B parameter class, quantized for Apple Silicon

### 18.4 Summary Output Types
The app must support generation of:

#### Standard outputs
- one-paragraph summary
- bullet summary
- detailed summary

#### Structured outputs
- action items with owner and due date if inferable
- key decisions
- unresolved questions
- blockers / risks
- next steps

#### Communication outputs
- follow-up email
- Slack-style update
- project update note
- personal recap

#### Bilingual outputs
- English summary
- Nepali summary
- English follow-up email
- Nepali follow-up note

### 18.5 Regeneration Rules
The user must be able to:
- regenerate outputs from raw transcript
- regenerate outputs from corrected transcript
- switch templates and rerun generation

### 18.6 Prompt Templates
Templates must be file-based and editable locally.

Template categories:
- General meeting
- Stand-up
- Interview
- Client call
- 1:1
- Project planning
- Brainstorming
- Personal conversation / note capture

---

## 19. Calendar Sync Requirements

### 19.1 Framework
- EventKit

### 19.2 Core Use Cases
1. Create a follow-up meeting event from extracted commitments
2. Convert “let’s meet next Tuesday at 3 PM” into a suggested event
3. Attach meeting summary to event notes
4. Optionally match a recorded meeting to an existing calendar event

### 19.3 Event Extraction Pipeline
The summarization system should produce structured candidate events:
- title
- start date/time
- end date/time or default duration
- notes
- confidence score
- source transcript references

### 19.4 Event Creation UX
Display proposed event in confirmation sheet:
- editable title
- editable date/time
- editable notes
- create button
- cancel button

### 19.5 Automatic Matching with Existing Events
If calendar access is granted, the app may:
- read today’s calendar events
- suggest linking a recording to the nearest scheduled meeting
- inherit title and time range if confidence is high

This must be optional and privacy-conscious.

### 19.6 Default Behavior
Default:
- read/write permission only after explicit user consent
- ask before event creation

---

## 20. Search and Chat Requirements

### 20.1 Search Modes
1. Keyword search
2. Full-text search
3. Semantic search
4. Filtered search

### 20.2 Filter Options
- date range
- title
- speaker
- language
- tag
- summary type

### 20.3 Meeting Chat
The user should be able to ask:
- “What decisions were made?”
- “What did Speaker 2 say about budget?”
- “Which meetings mentioned visa?”
- “Summarise only the Nepali sections.”
- “List all deadlines mentioned last week.”

### 20.4 RAG Scope
Chat should retrieve from:
- transcript chunks
- corrected transcript
- summaries
- action items
- decisions
- translations if available

### 20.5 Citation Requirement
Every answer in meeting chat should include:
- source meeting title
- timestamp references where possible

---

## 21. Data Model

Use SQLite. The schema should be explicit and normalized enough for future extension.

### 21.1 Core Tables
- `meetings`
- `audio_files`
- `transcript_segments`
- `diarization_segments`
- `speakers`
- `translations`
- `summaries`
- `generated_outputs`
- `embeddings`
- `calendar_links`
- `glossary_terms`
- `jobs`
- `settings`
- `tags`

### 21.2 Suggested Schema Sketch

#### meetings
- id
- uuid
- title
- source_type
- recording_mode
- language_mode
- start_time
- end_time
- duration_seconds
- notes_raw
- status
- created_at
- updated_at

#### audio_files
- id
- meeting_id
- original_path
- normalized_path
- sample_rate
- channels
- duration_seconds
- file_size_bytes
- created_at

#### transcript_segments
- id
- meeting_id
- segment_index
- start_seconds
- end_seconds
- speaker_id nullable
- detected_language nullable
- confidence nullable
- original_text
- corrected_text nullable
- locked boolean
- created_at
- updated_at

#### diarization_segments
- id
- meeting_id
- start_seconds
- end_seconds
- raw_speaker_label
- confidence nullable

#### speakers
- id
- meeting_id
- speaker_label
- user_alias nullable
- color nullable

#### translations
- id
- meeting_id
- source_language
- target_language
- content_type
- source_segment_id nullable
- translated_text
- created_at

#### summaries
- id
- meeting_id
- template_name
- language
- summary_type
- content
- model_name
- generated_from_corrected_transcript boolean
- created_at

#### generated_outputs
- id
- meeting_id
- output_type
- language
- content
- metadata_json
- created_at

#### embeddings
- id
- meeting_id
- segment_id nullable
- chunk_text
- embedding_vector_ref
- created_at

#### calendar_links
- id
- meeting_id
- event_identifier
- calendar_title
- linked_at

#### glossary_terms
- id
- term
- canonical_form
- language
- replacement_text
- priority
- active

#### jobs
- id
- meeting_id nullable
- job_type
- status
- progress
- payload_json
- error_message nullable
- created_at
- updated_at

---

## 22. File and Folder Layout

### 22.1 App Project Layout
Recommended top-level structure:

```text
MeetingAssistant/
  macos-app/
    MeetingAssistant.xcodeproj
    MeetingAssistantApp/
      App/
      Features/
      Shared/
      Services/
      Models/
      Views/
      ViewModels/
      Native/
      Resources/
  python-worker/
    app/
      main.py
      api/
      pipeline/
      stt/
      alignment/
      diarization/
      translation/
      llm/
      embeddings/
      calendar/
      storage/
      utils/
    models/
    requirements.txt
    pyproject.toml
  shared/
    prompts/
    templates/
    schemas/
  storage/
    meetings/
    database/
    logs/
  docs/
```

### 22.2 Per-Meeting Storage Layout
```text
storage/meetings/{meeting_uuid}/
  audio/
    original.wav
    normalized.wav
  transcript/
    transcript_raw.json
    transcript_merged.json
    transcript_corrected.json
  outputs/
    summary_en.md
    summary_ne.md
    action_items.json
    decisions.json
    followup_email_en.md
    followup_note_ne.md
  metadata/
    meeting.json
    processing.json
```

---

## 23. UI / UX Requirements

### 23.1 Main Screens
1. Home / Recent Meetings
2. Recording Screen
3. Meeting Detail Screen
4. Search Screen
5. Settings Screen
6. Calendar Review / Event Suggestion Sheet
7. Processing Queue / Job Status Screen

### 23.2 Home Screen
Must show:
- recent meetings
- search bar
- start recording button
- import audio button
- processing jobs section

### 23.3 Recording Screen
Must show:
- title field
- audio source mode
- timer
- waveform or level meter
- recording status
- stop button
- optional quick note field

### 23.4 Meeting Detail Screen
Tabs or segmented controls:
- Summary
- Transcript
- Translation
- Outputs
- Search/chat
- Calendar suggestions

### 23.5 Transcript Screen
Must support:
- timestamp click
- speaker labels
- edit mode
- lock corrected segment
- search within transcript
- filter by speaker
- filter by language

### 23.6 Outputs Screen
Must support:
- regenerate output
- choose template
- choose language
- copy output
- export output

### 23.7 Search/Chat Screen
Must support:
- semantic question answering
- result citations
- timestamp references

### 23.8 Settings Screen
Must support:
- model selection
- language mode default
- transcript quality mode
- storage location
- calendar permissions
- auto event suggestion mode
- glossary editor
- privacy settings

---

## 24. Processing Pipeline Design

### 24.1 Pipeline Steps
1. Ingest
2. Normalize audio
3. VAD
4. Transcribe
5. Align
6. Diarize
7. Merge
8. Language detect segments
9. Generate outputs
10. Translate
11. Embed
12. Index
13. Suggest calendar events

### 24.2 Pipeline Rules
- Every stage must write intermediate artifacts
- Failures must be resumable
- Jobs must be idempotent where possible
- User must be able to rerun individual stages

### 24.3 Job Types
- record_audio
- import_audio
- normalize_audio
- transcribe_audio
- align_transcript
- diarize_audio
- merge_transcript
- detect_language
- generate_summary
- translate_outputs
- embed_chunks
- index_meeting
- suggest_calendar_events

---

## 25. Performance Strategy for Apple Silicon

### 25.1 Local Model Execution Strategy
- Prefer models optimized or converted for Apple Silicon where possible
- Keep default models realistic for 16 GB RAM
- Allow higher-memory profile for stronger machines

### 25.2 Background Processing
- All heavy jobs must run off main UI thread
- Use job queue with progress updates
- App must remain usable during processing

### 25.3 Caching
Cache:
- transcriptions
- alignments
- diarization
- summaries
- translations
- embeddings

### 25.4 Regeneration Efficiency
When transcript corrections change:
- rerun only downstream dependent stages
- do not force a full re-transcription unless explicitly requested

---

## 26. Security and Privacy Requirements

### 26.1 Default Privacy Mode
Everything local by default.

### 26.2 Data Storage Rules
- raw audio local
- transcript local
- embeddings local
- summaries local
- no cloud upload unless future user explicitly enables it

### 26.3 Permission Handling
The app must ask explicitly for:
- microphone access
- screen/audio capture access
- calendar access

### 26.4 Sensitive Content Controls
Allow user to:
- delete raw audio
- keep transcript but remove audio
- redact segments
- exclude meeting from semantic index
- disable automatic calendar suggestion for selected meetings

### 26.5 Future-Proofing
Architect code so cloud connectors can be added later, but keep them disabled and absent from MVP UX.

---

## 27. Error Handling Requirements

### 27.1 Required Error States
- microphone permission denied
- system audio capture unavailable
- recording write failure
- transcription failure
- alignment failure
- diarization failure
- translation failure
- local model load failure
- calendar permission denied
- calendar event create failure

### 27.2 UX Rules
- explicit error message
- retry action where possible
- raw meeting data must not be lost if later stages fail

---

## 28. Testing Requirements

### 28.1 Unit Tests
Test:
- transcript merge logic
- glossary replacement logic
- date/time extraction
- calendar event candidate generation
- segment-to-speaker matching
- pipeline status transitions

### 28.2 Integration Tests
Test:
- record → transcribe → summarize
- import audio → transcribe → translate
- transcript correction → regenerate outputs
- event extraction → calendar creation

### 28.3 Real-World Test Dataset
Create a local test corpus covering:
- English-only meeting
- Nepali-only recording
- mixed English-Nepali discussion
- overlapping speech
- noisy environment
- low-volume microphone capture
- code-switching technical conversation

### 28.4 Acceptance Benchmarks
The app should be considered MVP-ready if it can:
- process 30-minute meetings reliably
- produce usable transcript and summary
- create a suggested calendar event from explicit future commitments
- support transcript correction and re-generation
- preserve all outputs locally

---

## 29. Build Phases

### Phase 1 — Core Proof of Concept
Goal:
- process imported audio file end-to-end

Deliver:
- imported audio
- transcript
- diarization
- summary
- translation
- local storage

### Phase 2 — Native Recording App
Goal:
- add live recording via native Mac UI

Deliver:
- record start/stop
- system/mic capture
- meeting folder creation
- processing job queue

### Phase 3 — Rich Meeting Viewer
Goal:
- make the result usable

Deliver:
- transcript editor
- summary tabs
- outputs screen
- playback + timestamps

### Phase 4 — Search and Chat
Goal:
- turn meetings into memory

Deliver:
- semantic search
- citations
- question answering

### Phase 5 — Calendar Automation
Goal:
- convert future commitments into calendar actions

Deliver:
- event extraction
- review sheet
- EventKit create flow

### Phase 6 — Polish
Goal:
- make it feel production-grade

Deliver:
- better settings
- glossary editor
- retries
- exports
- queue robustness
- onboarding

---

## 30. Prompting / Output Templates

The app must ship with editable local prompt templates for each output type.

### 30.1 Default Summary Prompt
Generate a structured summary of the meeting using only information present in the transcript. Include:
- concise overview
- key discussion points
- action items
- decisions
- unresolved questions

### 30.2 Action Items Prompt
Extract action items. For each item, include:
- task
- likely owner
- due date if inferable
- confidence
- supporting quote or timestamp

### 30.3 Calendar Event Prompt
Identify any future meeting, deadline, or appointment that should become a calendar event. Return:
- title
- start time
- end time or suggested duration
- rationale
- confidence
- relevant transcript citation

### 30.4 Translation Prompt
Translate the content while preserving:
- names
- titles
- company names
- acronyms
- technical terms
Use glossary rules where provided.

---

## 31. Calendar Intelligence Rules

### 31.1 What Counts as a Calendar Candidate
The app should suggest calendar events when the transcript contains:
- explicit meeting scheduling
- explicit deadlines with date/time
- follow-up appointments
- reminders tied to a concrete date/time

### 31.2 What Does Not Count Automatically
Do not auto-create events for:
- vague intentions
- non-time-bound suggestions
- “we should catch up sometime”
- low-confidence references

### 31.3 Confidence Thresholds
Event suggestion objects should include confidence score.
Only auto-suggest UI if above threshold.
Default: suggest but require review.

---

## 32. Optional Post-MVP Features (Do Not Block MVP)

- menu bar mini-recorder
- automatic meeting title inference from calendar
- participant voice profile matching
- offline sync across multiple Macs
- Apple Reminders integration
- auto-tagging
- sentiment / tone analysis
- organization of people / projects across meetings
- screenshot capture during calls
- import Zoom / Teams local recordings automatically

---

## 33. Important Product Decisions

### Decision 1
This must be a **native macOS app**, not Electron/Tauri, because:
- Apple Silicon is a first-class target
- we need strong native integration
- ScreenCaptureKit + EventKit + system permissions are smoother in a native app

### Decision 2
Use **SwiftUI + AppKit bridge**, not AppKit-only:
- SwiftUI for velocity and modern UI
- AppKit only where necessary

### Decision 3
Use **Python worker** for ML pipeline:
- far better open-source ecosystem
- easiest for autonomous coding agents to implement robustly

### Decision 4
Use **local-first storage and local inference**
- privacy
- cost control
- aligns with free-first objective

### Decision 5
Calendar sync must be **user-confirmed by default**
- safer
- avoids bad auto-created events
- more privacy-conscious

---

## 34. Codex / Claude Build Instructions

The coding agent must follow these rules:

1. Build the project in phases
2. Do not skip the proof-of-concept pipeline
3. Implement the native macOS host app in Swift / SwiftUI
4. Implement the ML worker in Python
5. Use ScreenCaptureKit, AVFoundation, and EventKit natively
6. Use SQLite for storage
7. Use faster-whisper for base STT
8. Use WhisperX for alignment
9. Use pyannote.audio for diarization
10. Use NLLB for translation
11. Use MLX / MLX-LM for local generation where feasible
12. Store all intermediate artifacts
13. Make every pipeline stage resumable
14. Build transcript correction before investing in excessive summary complexity
15. Default all privacy-sensitive behavior to local-only and opt-in

---

## 35. Minimum Deliverables for First Working Version

A version is considered “working” when it can:
- record a meeting locally on macOS
- store the audio
- transcribe English and Nepali speech locally
- assign approximate speaker labels
- display transcript with timestamps
- generate summary and action items
- translate summary between English and Nepali
- suggest a calendar event from explicit future commitments
- create that event in Apple Calendar after confirmation
- search across processed meetings locally

---

## 36. Known Risks and Mitigations

### Risk 1 — System audio capture complexity
Mitigation:
- support manual import immediately
- implement robust permission messaging
- separate recording engine from transcription engine

### Risk 2 — Nepali transcription quality
Mitigation:
- glossary
- correction UI
- mixed-language setting
- transcript regeneration pipeline

### Risk 3 — Speaker diarization errors
Mitigation:
- keep raw diarization editable
- allow manual speaker rename
- keep transcript correction layer independent

### Risk 4 — Local model memory limits
Mitigation:
- provide model tiers
- default to realistic local models for 16 GB machines
- avoid requiring giant models in MVP

### Risk 5 — False calendar extraction
Mitigation:
- confirmation UI
- confidence thresholds
- transcript citations in suggestion sheet

---

## 37. Final Implementation Priority Order

Build in this order:

1. Audio import
2. Transcription
3. Alignment
4. Diarization
5. Summary generation
6. Translation
7. Native recording
8. Transcript editing
9. Search/chat
10. Calendar suggestion and EventKit creation
11. UX polish

This order matters. Do not begin with UI polish or advanced automation before the core pipeline is trustworthy.

---

## 38. Final Notes

This project must be built as a **serious local productivity tool**, not as a demo.

The priority is:
- reliability
- privacy
- transcript usefulness
- Nepali support
- practical outputs
- native Mac experience

A correct version of this product is better than a flashy one.

The app should feel:
- clean
- calm
- efficient
- private
- Apple-native
- trustworthy

If tradeoffs arise, choose:
1. correctness
2. privacy
3. usability
4. speed
5. convenience

in that order.

---
