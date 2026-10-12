import AVFoundation
import XCTest
@testable import Varta

final class MediaPipelineTests: XCTestCase {
    func testMixedSourcesAndSequentialChunksShareOneTimeline() async throws {
        let storage = try makeStorage()
        let meeting = try await storage.createMeeting(title: "Mixed fixture", languageMode: .english)
        try await addAudio(storage: storage, meetingID: meeting, name: "microphone.wav", duration: 1, value: 0.2,
            source: "microphone", segmentIndex: 0, offset: 0)
        try await addAudio(storage: storage, meetingID: meeting, name: "system.wav", duration: 1, value: 0.4,
            source: "system", segmentIndex: 0, offset: 0)
        try await addAudio(storage: storage, meetingID: meeting, name: "next.wav", duration: 1, value: 0.6,
            source: "microphone", segmentIndex: 1, offset: 1)
        let root = await storage.appSupportDirectory()
        let records = try await storage.importedMedia(for: meeting)
        let prepared = try await MediaProcessingService(rootDirectory: root, windowDuration: 1).prepare(media: records, meetingID: meeting)
        XCTAssertEqual(prepared.timeline.count, 3)
        XCTAssertEqual(prepared.durationSeconds, 2, accuracy: 0.001)
        XCTAssertEqual(prepared.windows.count, 2)
        XCTAssertEqual(prepared.windows[1].startSeconds, 1, accuracy: 0.001)
        let file = try AVAudioFile(forReading: root.appendingPathComponent(prepared.windows[0].relativePath))
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 256))
        try file.read(into: buffer)
        let samples = try XCTUnwrap(buffer.floatChannelData)
        XCTAssertEqual(samples[0][128], 0.3, accuracy: 0.02)
    }

    func testDefaultWindowsBoundInferenceInputToThirtySeconds() async throws {
        let storage = try makeStorage()
        let meeting = try await storage.createMeeting(title: "Window fixture", languageMode: .english)
        try await addAudio(storage: storage, meetingID: meeting, name: "long.wav", duration: 31, value: 0.1)
        let records = try await storage.importedMedia(for: meeting)
        let root = await storage.appSupportDirectory()
        let prepared = try await MediaProcessingService(rootDirectory: root).prepare(media: records, meetingID: meeting)
        XCTAssertEqual(prepared.windows.count, 2)
        XCTAssertEqual(prepared.windows[0].durationSeconds, 30, accuracy: 0.001)
        XCTAssertEqual(prepared.windows[1].durationSeconds, 1, accuracy: 0.001)
    }

    func testSequentialChunksReusePlaybackTracks() async throws {
        let storage = try makeStorage()
        let meeting = try await storage.createMeeting(title: "Track reuse fixture", languageMode: .mixed)
        for index in 0..<5 {
            for source in ["microphone", "system"] {
                try await addAudio(storage: storage, meetingID: meeting, name: "\(source)-\(index).wav", duration: 0.25,
                    value: 0.1, source: source, segmentIndex: index, offset: Double(index) * 0.25)
            }
        }
        let records = try await storage.importedMedia(for: meeting)
        let root = await storage.appSupportDirectory()
        let item = try await MediaProcessingService.playbackItem(media: records, rootDirectory: root)
        let tracks = try await item.asset.loadTracks(withMediaType: .audio)
        let duration = CMTimeGetSeconds(try await item.asset.load(.duration))
        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(duration, 1.25, accuracy: 0.001)
    }

    func testFailedWindowResumeKeepsPriorTranscriptUntilComplete() async throws {
        let storage = try makeStorage()
        let meeting = try await storage.createMeeting(title: "Resume fixture", languageMode: .english)
        try await addAudio(storage: storage, meetingID: meeting, name: "resume.wav", duration: 31, value: 0.1)
        try await storage.replaceTranscriptSegments(meetingID: meeting, segments: [
            NewTranscriptSegment(startSeconds: 0, endSeconds: 1, text: "Prior transcript", languageTag: "en", speakerLabel: nil)
        ])
        let failing = WindowFixtureWhisper(failOnCall: 2)
        let service = TranscriptionService(storageService: storage, memoryManager: MemoryManager(), whisperClient: failing,
            voiceActivityDetector: FixtureVoiceActivityDetector())
        do {
            _ = try await service.transcribeMeeting(meetingID: meeting, languageMode: .english)
            XCTFail("Expected failure on second audio window")
        } catch WindowFixtureWhisper.FixtureError.interrupted { }
        let old = try await storage.transcriptSegments(meetingID: meeting)
        XCTAssertEqual(old.map(\.text), ["Prior transcript"])
        let jobs = try await storage.jobs(statuses: [.failed], type: .transcription)
        let job = try XCTUnwrap(jobs.first)
        let resumedClient = WindowFixtureWhisper()
        let resumed = TranscriptionService(storageService: storage, memoryManager: MemoryManager(), whisperClient: resumedClient,
            voiceActivityDetector: FixtureVoiceActivityDetector())
        let transcript = try await resumed.transcribeMeeting(meetingID: meeting, languageMode: .english, resumeJobID: job.id)
        let resumedCalls = await resumedClient.calls
        XCTAssertEqual(resumedCalls, 1)
        let resumedContexts = await resumedClient.contexts
        XCTAssertEqual(resumedContexts, ["Fixture window result"])
        XCTAssertEqual(transcript.count, 2)
        XCTAssertEqual(transcript[1].startSeconds, 30, accuracy: 0.001)
        let savedJob = try await storage.job(id: job.id)
        XCTAssertEqual(savedJob?.status, .completed)
    }

    func testRollingContextStartsEmptyForEachJobAndLanguage() async throws {
        let storage = try makeStorage()
        let client = WindowFixtureWhisper()
        let service = TranscriptionService(storageService: storage, memoryManager: MemoryManager(), whisperClient: client,
            voiceActivityDetector: FixtureVoiceActivityDetector())
        for language in [LanguageMode.english, .nepali] {
            let meeting = try await storage.createMeeting(title: "Context fixture", languageMode: language)
            try await addAudio(storage: storage, meetingID: meeting, name: "context.wav", duration: 31, value: 0.1)
            _ = try await service.transcribeMeeting(meetingID: meeting, languageMode: language)
        }
        let contexts = await client.contexts
        XCTAssertEqual(contexts, ["", "Fixture window result", "", "Fixture window result"])
    }

    func testTamperedPreparedCheckpointRejectsForeignWindowAndBrokenTimelineBeforeInference() async throws {
        let storage = try makeStorage()
        func failedFixture(title: String) async throws -> (meetingID: String, jobID: String, state: ProcessingCheckpoint) {
            let meeting = try await storage.createMeeting(title: title, languageMode: .english)
            try await addAudio(storage: storage, meetingID: meeting, name: "checkpoint.wav", duration: 31, value: 0.1)
            try await storage.replaceTranscriptSegments(meetingID: meeting, segments: [
                NewTranscriptSegment(startSeconds: 0, endSeconds: 1, text: "Prior checkpoint transcript", languageTag: "en", speakerLabel: nil)
            ])
            do {
                _ = try await TranscriptionService(storageService: storage, memoryManager: MemoryManager(),
                    whisperClient: WindowFixtureWhisper(failOnCall: 2), voiceActivityDetector: FixtureVoiceActivityDetector())
                    .transcribeMeeting(meetingID: meeting, languageMode: .english)
                XCTFail("Fixture must fail on the second window")
            } catch WindowFixtureWhisper.FixtureError.interrupted { }
            let jobs = try await storage.jobs(statuses: [.failed], type: .transcription)
            let job = try XCTUnwrap(jobs.first { $0.meetingID == meeting })
            let state = try await storage.processingState(jobID: job.id, stage: "transcription")
            return (meeting, job.id, try XCTUnwrap(state))
        }
        let original = try await failedFixture(title: "Original checkpoint")
        let foreign = try await failedFixture(title: "Foreign checkpoint")
        let originalBlob = try XCTUnwrap(original.state.checkpointBlob)
        let foreignBlob = try XCTUnwrap(foreign.state.checkpointBlob)
        let originalJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(originalBlob.utf8)) as? [String: Any])
        let foreignJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(foreignBlob.utf8)) as? [String: Any])
        let originalPrepared = try XCTUnwrap(originalJSON["preparedAudio"] as? [String: Any])
        let foreignPrepared = try XCTUnwrap(foreignJSON["preparedAudio"] as? [String: Any])
        let originalWindows = try XCTUnwrap(originalPrepared["windows"] as? [[String: Any]])
        let foreignWindows = try XCTUnwrap(foreignPrepared["windows"] as? [[String: Any]])
        let transcriptBefore = try await storage.transcriptSegments(meetingID: original.meetingID)
        let root = await storage.appSupportDirectory()
        let sourceA = try await storage.importedMedia(for: original.meetingID)
        let sourceB = try await storage.importedMedia(for: foreign.meetingID)
        let paths = sourceA.map(\.relativePath) + sourceB.map(\.relativePath)
            + (originalWindows + foreignWindows).compactMap { $0["relativePath"] as? String }
        let fileBytes = try paths.map { (path: $0, bytes: try Data(contentsOf: root.appendingPathComponent($0))) }

        for mutation in 0..<3 {
            var changed = originalJSON
            var prepared = originalPrepared
            var windows = originalWindows
            if mutation == 0 {
                windows[0]["relativePath"] = try XCTUnwrap(foreignWindows[0]["relativePath"] as? String)
            } else if mutation == 1 {
                windows[1]["startSeconds"] = 30.5
                windows[1]["durationSeconds"] = 0.5
            } else {
                windows[1]["durationSeconds"] = 0.5
                prepared["durationSeconds"] = 30.5
            }
            prepared["windows"] = windows
            changed["preparedAudio"] = prepared
            let blob = String(decoding: try JSONSerialization.data(withJSONObject: changed), as: UTF8.self)
            try await storage.upsertProcessingState(jobID: original.jobID, stage: "transcription",
                checkpointBlob: blob, checkpointOffsetSeconds: original.state.checkpointOffsetSeconds)
            let detector = FixtureVoiceActivityDetector()
            let whisper = WindowFixtureWhisper()
            do {
                _ = try await TranscriptionService(storageService: storage, memoryManager: MemoryManager(),
                    whisperClient: whisper, voiceActivityDetector: detector).transcribeMeeting(meetingID: original.meetingID,
                        languageMode: .english, resumeJobID: original.jobID)
                XCTFail("Tampered prepared audio must be rejected before inference")
            } catch TranscriptionService.TranscriptionError.invalidResume { }
            let detectorCalls = await detector.calls
            let whisperCalls = await whisper.calls
            XCTAssertEqual(detectorCalls, 0)
            XCTAssertEqual(whisperCalls, 0)
            let jobAfter = try await storage.job(id: original.jobID)
            let stateAfter = try await storage.processingState(jobID: original.jobID, stage: "transcription")
            let transcriptAfter = try await storage.transcriptSegments(meetingID: original.meetingID)
            XCTAssertEqual(jobAfter?.status, .failed)
            XCTAssertEqual(stateAfter?.checkpointBlob, blob)
            XCTAssertEqual(transcriptAfter.map(\.id), transcriptBefore.map(\.id))
            XCTAssertEqual(transcriptAfter.map(\.text), transcriptBefore.map(\.text))
            for file in fileBytes {
                XCTAssertTrue(try Data(contentsOf: root.appendingPathComponent(file.path)) == file.bytes,
                    "Fixture audio changed: \(file.path)")
            }
        }
    }

    func testContextBoundsUnicodeBytesAndRepetitionThreshold() {
        let context = WhisperDecodingPolicy.boundedContext(String(repeating: "नेपाल English ", count: 800))
        XCTAssertLessThanOrEqual(context.count, 1_024)
        XCTAssertLessThanOrEqual(context.utf8.count, 4_096)
        XCTAssertTrue(context.hasSuffix("English"))
        XCTAssertEqual(WhisperDecodingPolicy.boundedContext("e\u{301}"), "é")
        let phrase = "Please review invoice "
        XCTAssertFalse(WhisperDecodingPolicy.hasRepetitionLoop([segment(String(repeating: phrase, count: 3))]))
        XCTAssertTrue(WhisperDecodingPolicy.hasRepetitionLoop([segment(String(repeating: phrase, count: 4))]))
        XCTAssertFalse(WhisperDecodingPolicy.hasRepetitionLoop([segment(String(repeating: "no ", count: 20))]))
        XCTAssertFalse(WhisperDecodingPolicy.hasRepetitionLoop([segment("Please review invoice. We discuss shipping. Please review invoice. We confirm pricing. Please review invoice.")]))
    }

    func testLoopRetriesOnceWithCleanContextAndValidatesRetry() async throws {
        let loop = segment(String(repeating: "Please review invoice ", count: 4))
        let client = WindowFixtureWhisper(outputs: [[loop], [segment("Clean recovered speech")]])
        let result = try await TranscriptionService.decodeWindow(client: client,
            mediaURL: URL(fileURLWithPath: "/fixture.wav"), languageMode: .mixed,
            promptContext: "Previous window", durationSeconds: 1)
        XCTAssertEqual(result.map(\.text), ["Clean recovered speech"])
        let contexts = await client.contexts
        XCTAssertEqual(contexts, ["Previous window", ""])
        let invalid = WindowFixtureWhisper(outputs: [[loop], [WhisperTranscribedSegment(startSeconds: 0, endSeconds: 2, text: "Invalid retry")]])
        do {
            _ = try await TranscriptionService.decodeWindow(client: invalid,
                mediaURL: URL(fileURLWithPath: "/fixture.wav"), languageMode: .english,
                promptContext: "Prior", durationSeconds: 1)
            XCTFail("Invalid retry timestamps must not be accepted")
        } catch TranscriptionService.TranscriptionError.invalidEngineOutput { }
    }

    func testPersistentLoopPreservesPriorTranscriptAndCompletedWindowCheckpoint() async throws {
        let storage = try makeStorage()
        let meeting = try await storage.createMeeting(title: "Loop fixture", languageMode: .english)
        try await addAudio(storage: storage, meetingID: meeting, name: "loop.wav", duration: 31, value: 0.1)
        try await storage.replaceTranscriptSegments(meetingID: meeting, segments: [
            NewTranscriptSegment(startSeconds: 0, endSeconds: 1, text: "Prior transcript", languageTag: "en", speakerLabel: nil)
        ])
        let loop = segment(String(repeating: "Please review invoice ", count: 4))
        let client = WindowFixtureWhisper(outputs: [[segment("Completed window")], [loop], [loop]])
        let service = TranscriptionService(storageService: storage, memoryManager: MemoryManager(), whisperClient: client,
            voiceActivityDetector: FixtureVoiceActivityDetector())
        do {
            _ = try await service.transcribeMeeting(meetingID: meeting, languageMode: .english)
            XCTFail("Persistent loop must fail instead of saving repeated text")
        } catch TranscriptionService.TranscriptionError.repetitionLoop { }
        let transcript = try await storage.transcriptSegments(meetingID: meeting)
        XCTAssertEqual(transcript.map(\.text), ["Prior transcript"])
        let jobs = try await storage.jobs(statuses: [.failed], type: .transcription)
        let job = try XCTUnwrap(jobs.first)
        let state = try await storage.processingState(jobID: job.id, stage: "transcription")
        let blob = try XCTUnwrap(state?.checkpointBlob)
        let checkpoint = try JSONSerialization.jsonObject(with: Data(blob.utf8)) as? [String: Any]
        XCTAssertEqual(checkpoint?["completedWindows"] as? Int, 1)
        let calls = await client.calls
        XCTAssertEqual(calls, 3)
    }

    func testCancellationDoesNotRetryDetectedLoop() async throws {
        let loop = segment(String(repeating: "Please review invoice ", count: 4))
        let client = WindowFixtureWhisper(outputs: [[loop]], cancelOnCall: 1)
        do {
            _ = try await Task {
                try await TranscriptionService.decodeWindow(client: client,
                    mediaURL: URL(fileURLWithPath: "/fixture.wav"), languageMode: .english,
                    promptContext: "Prior", durationSeconds: 1)
            }.value
            XCTFail("Cancelled decode must not retry")
        } catch is CancellationError { }
        let calls = await client.calls
        XCTAssertEqual(calls, 1)
    }

    private func segment(_ text: String) -> WhisperTranscribedSegment {
        WhisperTranscribedSegment(startSeconds: 0, endSeconds: 1, text: text)
    }

    func testSpeechCropMappingRetainsOriginalSampleOffsetsAndRejectsInvalidRanges() throws {
        let span = VoiceActivitySpan(startFrame: 80_000, endFrame: 96_000)
        try WhisperDecodingPolicy.validateSpeechSpans([span], frameCount: 480_000)
        let mapped = try WhisperDecodingPolicy.mapDecodedSegments([segment("Speech at five seconds")], within: span)
        XCTAssertEqual(mapped[0].startSeconds, 5, accuracy: 0.000_1)
        XCTAssertEqual(mapped[0].endSeconds, 6, accuracy: 0.000_1)
        let later = VoiceActivitySpan(startFrame: 320_000, endFrame: 336_000)
        try WhisperDecodingPolicy.validateSpeechSpans([span, later], frameCount: 480_000)
        let separated = mapped + (try WhisperDecodingPolicy.mapDecodedSegments([segment("Later speech")], within: later))
        XCTAssertEqual(separated.map(\.startSeconds), [5, 20])
        XCTAssertEqual(separated.map(\.endSeconds), [6, 21])
        XCTAssertThrowsError(try WhisperDecodingPolicy.validateSpeechSpans([], frameCount: 480_000))
        XCTAssertThrowsError(try WhisperDecodingPolicy.validateSpeechSpans([
            VoiceActivitySpan(startFrame: 0, endFrame: 16_000), VoiceActivitySpan(startFrame: 15_999, endFrame: 32_000)
        ], frameCount: 480_000))
        XCTAssertThrowsError(try WhisperDecodingPolicy.validateSpeechSpans([
            VoiceActivitySpan(startFrame: 0, endFrame: 480_001)
        ], frameCount: 480_000))
        XCTAssertThrowsError(try WhisperDecodingPolicy.mapDecodedSegments([], within: span))
        XCTAssertThrowsError(try WhisperDecodingPolicy.mapDecodedSegments([
            WhisperTranscribedSegment(startSeconds: 1.01, endSeconds: 1.02, text: "Outside crop")
        ], within: span))
        XCTAssertThrowsError(try WhisperDecodingPolicy.mapDecodedSegments([
            WhisperTranscribedSegment(startSeconds: 0, endSeconds: 1.2, text: "Excessive native end")
        ], within: span))
        let roundedEnd = try WhisperDecodingPolicy.mapDecodedSegments([
            WhisperTranscribedSegment(startSeconds: 0, endSeconds: 1.04, text: "Centisecond padding")
        ], within: span)
        XCTAssertEqual(roundedEnd[0].endSeconds, 6, accuracy: 0.000_1)
    }

    func testQuietWindowsCompleteWithoutWhisperAndPreservePriorContent() async throws {
        let storage = try makeStorage()
        let meeting = try await storage.createMeeting(title: "Quiet detector fixture", languageMode: .english)
        try await addAudio(storage: storage, meetingID: meeting, name: "quiet.wav", duration: 31, value: 0)
        try await storage.replaceTranscriptSegments(meetingID: meeting, segments: [
            NewTranscriptSegment(startSeconds: 0, endSeconds: 1, text: "Previous transcript", languageTag: "en", speakerLabel: nil)
        ])
        let revision = try await storage.transcriptRevision(meetingID: meeting)
        try await storage.upsertSummary(meetingID: meeting, summary: SummaryContent(concise: "Previous summary",
            detailed: "Previous summary", bullets: "Previous summary"), sourceTranscriptRevision: revision)
        let detector = FixtureVoiceActivityDetector(detections: [
            VoiceActivityDetection(frameCount: 480_000, spans: []), VoiceActivityDetection(frameCount: 16_000, spans: [])
        ])
        let whisper = WindowFixtureWhisper()
        let service = TranscriptionService(storageService: storage, memoryManager: MemoryManager(),
            whisperClient: whisper, voiceActivityDetector: detector)
        let transcript = try await service.transcribeMeeting(meetingID: meeting, languageMode: .english)
        XCTAssertEqual(transcript.map(\.text), ["Previous transcript"])
        let noSpeech = await service.lastCompletionHadNoSpeech
        let whisperCalls = await whisper.calls
        let detectorCalls = await detector.calls
        XCTAssertTrue(noSpeech)
        XCTAssertEqual(whisperCalls, 0)
        XCTAssertEqual(detectorCalls, 2)
        let summary = try await storage.summary(meetingID: meeting)
        let afterRevision = try await storage.transcriptRevision(meetingID: meeting)
        XCTAssertEqual(summary?.concise, "Previous summary")
        XCTAssertEqual(afterRevision, revision)
        let jobs = try await storage.jobs(type: .transcription)
        let job = try XCTUnwrap(jobs.first)
        XCTAssertEqual(job.status, .completed)
        XCTAssertEqual(job.progress, 1)
        let state = try await storage.processingState(jobID: job.id, stage: "transcription")
        let blob = try XCTUnwrap(state?.checkpointBlob)
        let checkpoint = try JSONSerialization.jsonObject(with: Data(blob.utf8)) as? [String: Any]
        XCTAssertEqual(checkpoint?["completedWindows"] as? Int, 2)
        XCTAssertEqual(state?.checkpointOffsetSeconds, 31)
        let media = try await storage.importedMedia(for: meeting)
        let root = await storage.appSupportDirectory()
        XCTAssertEqual(media.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(media[0].relativePath).path))
    }

    func testMixedQuietSpeechWindowsResumeAtOriginalAbsoluteOffsets() async throws {
        let storage = try makeStorage()
        let meeting = try await storage.createMeeting(title: "Mixed VAD fixture", languageMode: .mixed)
        try await addAudio(storage: storage, meetingID: meeting, name: "mixed.wav", duration: 61, value: 0.1)
        let middle = VoiceActivitySpan(startFrame: 80_000, endFrame: 96_000)
        let detector = FixtureVoiceActivityDetector(detections: [
            VoiceActivityDetection(frameCount: 480_000, spans: []),
            VoiceActivityDetection(frameCount: 480_000, spans: [middle]),
            VoiceActivityDetection(frameCount: 16_000, spans: [VoiceActivitySpan(startFrame: 0, endFrame: 16_000)])
        ])
        let failing = WindowFixtureWhisper(failOnCall: 2)
        let service = TranscriptionService(storageService: storage, memoryManager: MemoryManager(),
            whisperClient: failing, voiceActivityDetector: detector)
        do {
            _ = try await service.transcribeMeeting(meetingID: meeting, languageMode: .mixed)
            XCTFail("Last window should fail before checkpoint advancement")
        } catch WindowFixtureWhisper.FixtureError.interrupted { }
        let jobs = try await storage.jobs(statuses: [.failed], type: .transcription)
        let job = try XCTUnwrap(jobs.first)
        let state = try await storage.processingState(jobID: job.id, stage: "transcription")
        let checkpoint = try JSONSerialization.jsonObject(with: Data(XCTUnwrap(state?.checkpointBlob).utf8)) as? [String: Any]
        XCTAssertEqual(checkpoint?["completedWindows"] as? Int, 2)
        let resumedWhisper = WindowFixtureWhisper()
        let resumedDetector = FixtureVoiceActivityDetector()
        let resumed = TranscriptionService(storageService: storage, memoryManager: MemoryManager(),
            whisperClient: resumedWhisper, voiceActivityDetector: resumedDetector)
        let transcript = try await resumed.transcribeMeeting(meetingID: meeting, languageMode: .mixed, resumeJobID: job.id)
        XCTAssertEqual(transcript.map(\.startSeconds), [35, 60])
        XCTAssertEqual(transcript.map(\.endSeconds), [36, 61])
        let resumedCalls = await resumedWhisper.calls
        let resumedDetectionCalls = await resumedDetector.calls
        XCTAssertEqual(resumedCalls, 1)
        XCTAssertEqual(resumedDetectionCalls, 1)
        let originalSpans = await failing.receivedSpans
        XCTAssertEqual(originalSpans.first, [middle])
    }

    func testInvalidVoiceActivityCannotCallWhisperOrAdvanceCheckpoint() async throws {
        let storage = try makeStorage()
        let meeting = try await storage.createMeeting(title: "Invalid VAD fixture", languageMode: .english)
        try await addAudio(storage: storage, meetingID: meeting, name: "invalid.wav", duration: 1, value: 0.1)
        let detector = FixtureVoiceActivityDetector(detections: [VoiceActivityDetection(frameCount: 16_000,
            spans: [VoiceActivitySpan(startFrame: 0, endFrame: 16_001)])])
        let whisper = WindowFixtureWhisper()
        do {
            _ = try await TranscriptionService(storageService: storage, memoryManager: MemoryManager(),
                whisperClient: whisper, voiceActivityDetector: detector).transcribeMeeting(meetingID: meeting, languageMode: .english)
            XCTFail("Out-of-bounds speech must fail before decoding")
        } catch TranscriptionService.TranscriptionError.invalidVoiceActivity { }
        let calls = await whisper.calls
        XCTAssertEqual(calls, 0)
        let jobs = try await storage.jobs(statuses: [.failed], type: .transcription)
        let job = try XCTUnwrap(jobs.first)
        let state = try await storage.processingState(jobID: job.id, stage: "transcription")
        let checkpoint = try JSONSerialization.jsonObject(with: Data(XCTUnwrap(state?.checkpointBlob).utf8)) as? [String: Any]
        XCTAssertEqual(checkpoint?["completedWindows"] as? Int, 0)
    }

    func testCancellationDuringVoiceActivityLeavesCurrentWindowPending() async throws {
        let storage = try makeStorage()
        let meeting = try await storage.createMeeting(title: "Cancelled VAD fixture", languageMode: .english)
        try await addAudio(storage: storage, meetingID: meeting, name: "cancel.wav", duration: 1, value: 0.1)
        let detector = FixtureVoiceActivityDetector(cancelOnCall: 1)
        let whisper = WindowFixtureWhisper()
        let service = TranscriptionService(storageService: storage, memoryManager: MemoryManager(),
            whisperClient: whisper, voiceActivityDetector: detector)
        do {
            _ = try await Task { try await service.transcribeMeeting(meetingID: meeting, languageMode: .english) }.value
            XCTFail("Cancelled VAD must not decode or complete the window")
        } catch is CancellationError { }
        let calls = await whisper.calls
        XCTAssertEqual(calls, 0)
        let jobs = try await storage.jobs(statuses: [.paused], type: .transcription)
        let job = try XCTUnwrap(jobs.first)
        let state = try await storage.processingState(jobID: job.id, stage: "transcription")
        let checkpoint = try JSONSerialization.jsonObject(with: Data(XCTUnwrap(state?.checkpointBlob).utf8)) as? [String: Any]
        XCTAssertEqual(checkpoint?["completedWindows"] as? Int, 0)
    }

    func testChangedVoiceActivityIdentityRejectsResumeBeforeDetectorOrWhisperRuns() async throws {
        let storage = try makeStorage()
        let meeting = try await storage.createMeeting(title: "Detector identity fixture", languageMode: .english)
        try await addAudio(storage: storage, meetingID: meeting, name: "identity.wav", duration: 31, value: 0.1)
        do {
            _ = try await TranscriptionService(storageService: storage, memoryManager: MemoryManager(),
                whisperClient: WindowFixtureWhisper(failOnCall: 2), voiceActivityDetector: FixtureVoiceActivityDetector())
                .transcribeMeeting(meetingID: meeting, languageMode: .english)
            XCTFail("Fixture should fail on second window")
        } catch WindowFixtureWhisper.FixtureError.interrupted { }
        let jobs = try await storage.jobs(statuses: [.failed], type: .transcription)
        let job = try XCTUnwrap(jobs.first)
        let changed = FixtureVoiceActivityDetector(identity: "fixture-vad-v2")
        let whisper = WindowFixtureWhisper()
        do {
            _ = try await TranscriptionService(storageService: storage, memoryManager: MemoryManager(),
                whisperClient: whisper, voiceActivityDetector: changed).transcribeMeeting(meetingID: meeting,
                    languageMode: .english, resumeJobID: job.id)
            XCTFail("Changed detector identity must invalidate prior window results")
        } catch TranscriptionService.TranscriptionError.invalidResume { }
        let detectionCalls = await changed.calls
        let whisperCalls = await whisper.calls
        XCTAssertEqual(detectionCalls, 0)
        XCTAssertEqual(whisperCalls, 0)
    }

    func testChangedWhisperIdentityRejectsResumeBeforeDetectorOrWhisperRuns() async throws {
        let storage = try makeStorage()
        let meeting = try await storage.createMeeting(title: "ASR identity fixture", languageMode: .english)
        try await addAudio(storage: storage, meetingID: meeting, name: "asr-identity.wav", duration: 31, value: 0.1)
        do {
            _ = try await TranscriptionService(storageService: storage, memoryManager: MemoryManager(),
                whisperClient: WindowFixtureWhisper(failOnCall: 2), voiceActivityDetector: FixtureVoiceActivityDetector())
                .transcribeMeeting(meetingID: meeting, languageMode: .english)
            XCTFail("Fixture should fail on second window")
        } catch WindowFixtureWhisper.FixtureError.interrupted { }
        let jobs = try await storage.jobs(statuses: [.failed], type: .transcription)
        let job = try XCTUnwrap(jobs.first)
        let detector = FixtureVoiceActivityDetector()
        let changed = WindowFixtureWhisper(identity: "fixture-whisper-v2")
        do {
            _ = try await TranscriptionService(storageService: storage, memoryManager: MemoryManager(),
                whisperClient: changed, voiceActivityDetector: detector).transcribeMeeting(meetingID: meeting,
                    languageMode: .english, resumeJobID: job.id)
            XCTFail("Changed ASR model identity must invalidate prior decoded windows")
        } catch TranscriptionService.TranscriptionError.invalidResume { }
        let detectionCalls = await detector.calls
        let whisperCalls = await changed.calls
        XCTAssertEqual(detectionCalls, 0)
        XCTAssertEqual(whisperCalls, 0)
    }

    func testActualWhisperMetadataIdentityIsStableAndDetectsFileAppendAndNewPath() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("whisper-metadata-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = folder.appendingPathComponent("metadata-only.bin")
        let manifest = folder.appendingPathComponent("fixture-manifest.json")
        // These bytes exercise file metadata only; they are not a valid Whisper model.
        try Data([1, 2, 3]).write(to: model, options: .withoutOverwriting)
        let content = """
        {"whisper":{"engine":"whisper.cpp","backend":"metal","model":"ggml-large-v3-q5_0","path":"metadata-only.bin"},
         "summariser":{"engine":"mlx-swift","model":"llama-3.1-8b-instruct-4bit","path":"unused-language-model"}}
        """
        try Data(content.utf8).write(to: manifest, options: .withoutOverwriting)
        let bridge = WhisperCppBridge(configuration: WhisperCppConfiguration(models: LocalModelConfiguration(
            rootDirectory: folder, manifestURL: manifest)))
        let original: String
        do { original = try bridge.configurationIdentity() }
        catch LocalModelError.engineUnavailable(let engine) {
            throw XCTSkip("Metadata getter fixture requires the app's linked native module: \(engine)")
        }
        XCTAssertEqual(original, try bridge.configurationIdentity())
        let handle = try FileHandle(forWritingTo: model)
        do {
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: Data([4]))
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        let appended = try bridge.configurationIdentity()
        XCTAssertNotEqual(appended, original)
        XCTAssertEqual(appended, try bridge.configurationIdentity())
        let copied = folder.appendingPathComponent("copied-metadata-only.bin")
        try FileManager.default.copyItem(at: model, to: copied)
        let changedPath = WhisperCppBridge(configuration: WhisperCppConfiguration(models: LocalModelConfiguration(
            rootDirectory: folder, manifestURL: manifest, whisperOverride: copied)))
        XCTAssertNotEqual(try changedPath.configurationIdentity(), appended)
    }

    func testCleanContextRetryKeepsSameOriginalSpeechSpans() async throws {
        let span = VoiceActivitySpan(startFrame: 80_000, endFrame: 96_000)
        let loop = WhisperTranscribedSegment(startSeconds: 5, endSeconds: 6,
            text: String(repeating: "Please review invoice ", count: 4))
        let clean = WhisperTranscribedSegment(startSeconds: 5, endSeconds: 6, text: "Clean speech")
        let client = WindowFixtureWhisper(outputs: [[loop], [clean]])
        _ = try await TranscriptionService.decodeWindow(client: client, mediaURL: URL(fileURLWithPath: "/fixture.wav"),
            languageMode: .mixed, promptContext: "Prior context", durationSeconds: 30, speechSpans: [span])
        let requests = await client.receivedSpans
        XCTAssertEqual(requests, [[span], [span]])
    }

    func testInterruptedRecordingRestoresPausedWithoutOpeningDevices() async throws {
        let storage = try makeStorage()
        let queue = JobQueue(storageService: storage)
        let checkpointer = Checkpointer(storageService: storage)
        let meeting = try await storage.createMeeting(title: "Recovery fixture", languageMode: .mixed)
        let job = try await queue.beginRecordingJob(meetingID: meeting)
        let name = "segment-0-microphone-\(job.id).wav"
        try await addAudio(storage: storage, meetingID: meeting, name: name, duration: 1, value: 0.1,
            source: "microphone", segmentIndex: 0, offset: 0)
        let records = try await storage.importedMedia(for: meeting)
        let checkpoint = RecordingCheckpointPayload(meetingID: meeting, segmentRelativePaths: records.map(\.relativePath),
            totalRecordedSeconds: 1, lastSegmentDurationSeconds: 1, reason: .periodic, recordedAt: Date(),
            captureMicrophone: true, captureSystemAudio: false, nextSegmentIndex: 1)
        try await checkpointer.saveRecordingCheckpoint(jobID: job.id, payload: checkpoint)
        _ = try await queue.recoverInterruptedRecordingJobs()
        let recorder = RecorderCoordinator(storageService: storage, jobQueue: queue,
            checkpointer: checkpointer, memoryManager: MemoryManager())
        try await recorder.restoreInterruptedRecording(jobID: job.id)
        let snapshot = await recorder.currentSnapshot()
        XCTAssertEqual(snapshot.state, .paused)
        XCTAssertEqual(snapshot.segmentCount, 1)
        XCTAssertEqual(snapshot.totalRecordedSeconds, 1, accuracy: 0.001)
    }

    func testMediaPathTraversalIsRejected() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try MediaProcessingService.checkedURL(relativePath: "../outside.wav", rootDirectory: root))
    }

    func testRecordingClockStopsAtDurationBoundary() throws {
        let clock = RecordingCaptureClock(durationLimit: 1)
        XCTAssertTrue(clock.accepts(sampleBuffer: try sampleBuffer(startSeconds: 0)))
        XCTAssertFalse(clock.accepts(sampleBuffer: try sampleBuffer(startSeconds: 1)))
        XCTAssertTrue(clock.hasReachedLimit())
    }

    func testInvalidRawDurationStillStopsAtFourHourBoundary() throws {
        let clock = RecordingCaptureClock(durationLimit: 14_400)
        XCTAssertTrue(clock.accepts(sampleBuffer: try sampleBuffer(startSeconds: 0)))
        let invalidTiming = try sampleBuffer(startSeconds: 14_400, rawDuration: .invalid)
        XCTAssertFalse(CMTimeGetSeconds(CMSampleBufferGetDuration(invalidTiming)).isFinite)
        XCTAssertFalse(clock.accepts(sampleBuffer: invalidTiming))
        XCTAssertTrue(clock.hasReachedLimit())
    }

    private func makeStorage() throws -> StorageService {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("varta-media-\(UUID().uuidString).sqlite")
        return try StorageService(databaseURL: url)
    }

    private func addAudio(storage: StorageService, meetingID: String, name: String, duration: Double, value: Float,
        source: String? = nil, segmentIndex: Int? = nil, offset: Double? = nil) async throws {
        let root = await storage.appSupportDirectory()
        let path = "Imports/\(meetingID)/\(name)"
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
        let samples = try XCTUnwrap(buffer.floatChannelData)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        var remaining = Int(duration * 16_000)
        while remaining > 0 {
            let count = min(remaining, 4_096)
            buffer.frameLength = AVAudioFrameCount(count)
            samples[0].update(repeating: value, count: count)
            try file.write(from: buffer)
            remaining -= count
        }
        try await storage.registerImportedMedia(meetingID: meetingID, relativePath: path,
            originalFilename: name, format: "wav", durationSeconds: duration,
            source: source, segmentIndex: segmentIndex, timelineOffsetSeconds: offset)
    }

    private func sampleBuffer(startSeconds: Double, rawDuration: CMTime = CMTime(value: 1, timescale: 16_000)) throws -> CMSampleBuffer {
        var format = AudioStreamBasicDescription(mSampleRate: 16_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2,
            mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var description: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &format,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &description), noErr)
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: 8_000, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: 8_000, flags: 0, blockBufferOut: &block), kCMBlockBufferNoErr)
        var timing = CMSampleTimingInfo(duration: rawDuration,
            presentationTimeStamp: CMTime(seconds: startSeconds, preferredTimescale: 16_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: try XCTUnwrap(block),
            formatDescription: try XCTUnwrap(description), sampleCount: 4_000, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: [2], sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }
}

private actor WindowFixtureWhisper: WhisperCppClient {
    enum FixtureError: Error { case interrupted }
    private let failOnCall: Int?
    private let outputs: [[WhisperTranscribedSegment]]?
    private let cancelOnCall: Int?
    private let identity: String
    private(set) var calls = 0
    private(set) var contexts: [String] = []
    private(set) var receivedSpans: [[VoiceActivitySpan]] = []

    init(failOnCall: Int? = nil, outputs: [[WhisperTranscribedSegment]]? = nil, cancelOnCall: Int? = nil,
        identity: String = "fixture-whisper-v1") {
        self.failOnCall = failOnCall
        self.outputs = outputs
        self.cancelOnCall = cancelOnCall
        self.identity = identity
    }

    nonisolated func validateConfiguration() throws { }
    nonisolated func configurationIdentity() throws -> String { identity }

    func transcribe(mediaURL: URL, languageMode: LanguageMode, promptContext: String, speechSpans: [VoiceActivitySpan]) async throws -> [WhisperTranscribedSegment] {
        calls += 1
        contexts.append(promptContext)
        receivedSpans.append(speechSpans)
        if calls == failOnCall { throw FixtureError.interrupted }
        if calls == cancelOnCall { withUnsafeCurrentTask { $0?.cancel() } }
        if let outputs { return outputs[min(calls - 1, outputs.count - 1)] }
        let first = speechSpans[0]
        let start = Double(first.startFrame) / 16_000
        return [WhisperTranscribedSegment(startSeconds: start,
            endSeconds: min(start + 1, Double(first.endFrame) / 16_000), text: "Fixture window result")]
    }
}

// A test-only detector for injected model fixtures; it makes no speech-accuracy claim.
actor FixtureVoiceActivityDetector: VoiceActivityDetecting {
    private let identity: String
    private let detections: [VoiceActivityDetection]?
    private let cancelOnCall: Int?
    private(set) var calls = 0

    init(identity: String = "fixture-vad-v1", detections: [VoiceActivityDetection]? = nil, cancelOnCall: Int? = nil) {
        self.identity = identity
        self.detections = detections
        self.cancelOnCall = cancelOnCall
    }

    nonisolated func configurationIdentity() throws -> String { identity }

    func detectSpeech(mediaURL: URL) async throws -> VoiceActivityDetection {
        calls += 1
        if calls == cancelOnCall { withUnsafeCurrentTask { $0?.cancel() } }
        if let detections {
            guard !detections.isEmpty else { throw TranscriptionService.TranscriptionError.invalidVoiceActivity }
            return detections[min(calls - 1, detections.count - 1)]
        }
        let audio = try AVAudioFile(forReading: mediaURL)
        return VoiceActivityDetection(frameCount: audio.length,
            spans: [VoiceActivitySpan(startFrame: 0, endFrame: audio.length)])
    }
}
