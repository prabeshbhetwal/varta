import AVFoundation
import GRDB
import XCTest
@testable import Varta

final class LocalImportLoopIntegrationTests: XCTestCase {
    func testImportThenPersistInjectedFixtureTranscript() async throws {
        let storage = try StorageService(databaseURL: temporaryDatabaseURL())
        let memoryManager = MemoryManager()
        let transcription = TranscriptionService(
            storageService: storage, memoryManager: memoryManager, whisperClient: FixtureWhisperClient()
        )
        let importer = ImportPipelineService(storageService: storage)

        let inputURL = try makeSampleMediaFile()
        let meetingID = try await importer.importMedia(from: inputURL, languageMode: .mixed)

        let importedMedia = try await storage.importedMedia(for: meetingID)
        XCTAssertFalse(importedMedia.isEmpty)

        let importedURL = await storage.resolvedImportedMediaURL(relativePath: importedMedia[0].relativePath)
        let detail = await MeetingDetailViewModel(meetingID: meetingID, storageService: storage, memoryManager: memoryManager)
        await detail.refresh()
        let audioFolder = await detail.recordingsFolderURL
        XCTAssertEqual(audioFolder, importedURL.deletingLastPathComponent())
        _ = try await transcription.transcribeMeeting(meetingID: meetingID, mediaURL: importedURL, languageMode: .mixed)

        let segments = try await storage.transcriptSegments(meetingID: meetingID)
        XCTAssertFalse(segments.isEmpty)

        let appSupport = await storage.appSupportDirectory()
        let promptDirectory = appSupport.appendingPathComponent("Prompts", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: promptDirectory.path))
        XCTAssertNotEqual(appSupport, try StorageService.applicationSupportDirectory(fileManager: .default))
    }

    func testDefaultTranscriptionFailsWithoutReplacingExistingTranscript() async throws {
        let storage = try StorageService(databaseURL: temporaryDatabaseURL())
        let meetingID = try await storage.createMeeting(title: "Preserve transcript", languageMode: .english)
        try await storage.replaceTranscriptSegments(meetingID: meetingID, segments: [
            NewTranscriptSegment(startSeconds: 0, endSeconds: 1, text: "Existing transcript", languageTag: "en", speakerLabel: nil)
        ])
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let transcription = TranscriptionService(storageService: storage, memoryManager: MemoryManager(),
            whisperClient: WhisperCppBridge(configuration: WhisperCppConfiguration(models: LocalModelConfiguration(whisperOverride: missing))))
        do {
            _ = try await transcription.transcribeMeeting(meetingID: meetingID, mediaURL: makeSampleMediaFile(), languageMode: .english)
            XCTFail("Missing local assets must fail rather than invent a transcript")
        } catch {
            XCTAssertTrue(error is LocalModelError)
        }
        let segments = try await storage.transcriptSegments(meetingID: meetingID)
        XCTAssertEqual(segments.map(\.text), ["Existing transcript"])
    }

    @MainActor
    func testSameSelectedMeetingAppendRefreshesPlaybackWithoutReplacingReviewedRows() async throws {
        let storage = try StorageService(databaseURL: temporaryDatabaseURL())
        let meetingID = try await storage.createMeeting(title: "Append recording", languageMode: .english)
        try await storage.replaceTranscriptSegments(meetingID: meetingID, segments: [
            NewTranscriptSegment(startSeconds: 0, endSeconds: 1, text: "Original", languageTag: "en", speakerLabel: nil)
        ])
        let initial = try await storage.transcriptSegments(meetingID: meetingID)
        let segmentID = try XCTUnwrap(initial.first?.id)
        try await storage.updateTranscriptCorrection(segmentID: segmentID, correctedText: "Reviewed correction")
        try await storage.setTranscriptSegmentLock(segmentID: segmentID, isLocked: true)
        try await appendSampleMedia(storage: storage, meetingID: meetingID, segmentIndex: 0)
        let home = HomeViewModel(storageService: storage)
        home.selectedMeetingID = meetingID
        await home.refreshMeetings()
        let detail = MeetingDetailViewModel(meetingID: meetingID, storageService: storage, memoryManager: MemoryManager())
        await detail.refresh()
        await detail.preparePlayback()
        let player = try XCTUnwrap(detail.player)
        let firstItem = try XCTUnwrap(player.currentItem)
        let firstDuration = try await firstItem.asset.load(.duration)
        XCTAssertEqual(firstDuration.seconds, 1, accuracy: 0.01)
        try await appendSampleMedia(storage: storage, meetingID: meetingID, segmentIndex: 1)
        await home.refreshMeetings(select: meetingID)
        XCTAssertEqual(home.selectedMeetingID, meetingID)
        XCTAssertEqual(home.meetingContentRevisions[meetingID], 1)
        await detail.refreshMedia()
        XCTAssertEqual(detail.importedMedia.count, 2)
        XCTAssertTrue(detail.player === player)
        let updatedItem = try XCTUnwrap(player.currentItem)
        XCTAssertFalse(updatedItem === firstItem)
        let updatedDuration = try await updatedItem.asset.load(.duration)
        XCTAssertEqual(updatedDuration.seconds, 2, accuracy: 0.01)
        XCTAssertEqual(detail.segments.map(\.id), [segmentID])
        XCTAssertEqual(detail.segments.first?.correctedText, "Reviewed correction")
        XCTAssertEqual(detail.segments.first?.isLocked, true)
    }

    @MainActor
    func testMediaRefreshFailureKeepsTranscriptRows() async throws {
        let databaseURL = temporaryDatabaseURL()
        let storage = try StorageService(databaseURL: databaseURL)
        let meetingID = try await storage.createMeeting(title: "Failed media query", languageMode: .english)
        try await storage.replaceTranscriptSegments(meetingID: meetingID, segments: [
            NewTranscriptSegment(startSeconds: 0, endSeconds: 1, text: "Keep editor row", languageTag: "en", speakerLabel: nil)
        ])
        let detail = MeetingDetailViewModel(meetingID: meetingID, storageService: storage, memoryManager: MemoryManager())
        await detail.refresh()
        let rowIDs = detail.segments.map(\.id)
        let isolatedDatabase = try DatabaseQueue(path: databaseURL.path)
        try await isolatedDatabase.write { db in try db.execute(sql: "DROP TABLE audio_files") }
        await detail.refreshMedia()
        XCTAssertEqual(detail.segments.map(\.id), rowIDs)
        XCTAssertEqual(detail.segments.first?.effectiveText, "Keep editor row")
        XCTAssertTrue(detail.errorMessage?.hasPrefix("Recording refresh failed:") == true)
    }

    @MainActor
    func testCancelledOrInactivePlaybackRequestsDoNotPublishOrPlay() async throws {
        let storage = try StorageService(databaseURL: temporaryDatabaseURL())
        let meetingID = try await storage.createMeeting(title: "Playback lifecycle", languageMode: .english)
        try await appendSampleMedia(storage: storage, meetingID: meetingID, segmentIndex: 0)
        let detail = MeetingDetailViewModel(meetingID: meetingID, storageService: storage, memoryManager: MemoryManager())
        await detail.refresh()
        let cancelled = Task { await detail.preparePlayback() }
        cancelled.cancel()
        await cancelled.value
        XCTAssertNil(detail.player)
        XCTAssertFalse(detail.isPreparingPlayback)
        let scheduledSeek = Task { await detail.seek(to: 0) }
        detail.stopPlayback()
        await scheduledSeek.value
        XCTAssertNil(detail.player)
        XCTAssertFalse(detail.isPreparingPlayback)
        detail.activatePlayback()
        await detail.preparePlayback()
        let player = try XCTUnwrap(detail.player)
        let lateSeek = Task { await detail.seek(to: 0) }
        detail.stopPlayback()
        await lateSeek.value
        XCTAssertEqual(player.rate, 0)
    }

    @MainActor
    func testAutomaticCompletionRefreshesHomeExactlyOnce() async throws {
        let storage = try StorageService(databaseURL: temporaryDatabaseURL())
        let queue = JobQueue(storageService: storage)
        let checkpointer = Checkpointer(storageService: storage)
        let meetingID = try await storage.createMeeting(title: "Automatic completion", languageMode: .mixed)
        let job = try await queue.beginRecordingJob(meetingID: meetingID)
        try await appendSampleMedia(storage: storage, meetingID: meetingID, segmentIndex: 0, timelineOffset: 14_399)
        let media = try await storage.importedMedia(for: meetingID)
        let checkpoint = RecordingCheckpointPayload(meetingID: meetingID, segmentRelativePaths: media.map(\.relativePath),
            totalRecordedSeconds: 14_400, lastSegmentDurationSeconds: 1, reason: .periodic, recordedAt: Date(),
            captureMicrophone: true, captureSystemAudio: false)
        try await checkpointer.saveRecordingCheckpoint(jobID: job.id, payload: checkpoint)
        try await queue.pauseRecordingJob(jobID: job.id)
        let recorder = RecorderCoordinator(storageService: storage, jobQueue: queue, checkpointer: checkpointer, memoryManager: MemoryManager())
        let home = HomeViewModel(storageService: storage)
        var callbacks: [String?] = []
        var refreshTask: Task<Void, Never>?
        let controls = RecordingControlsViewModel(recorderCoordinator: recorder) { meetingID in
            callbacks.append(meetingID)
            refreshTask = Task { await home.refreshMeetings(select: meetingID) }
        }
        try await recorder.restoreInterruptedRecording(jobID: job.id)
        let stopped = await recorder.stopRecordingAtDurationLimitIfNeeded()
        XCTAssertTrue(stopped)
        await controls.refreshSnapshot()
        await controls.refreshSnapshot()
        await refreshTask?.value
        XCTAssertEqual(callbacks, [meetingID])
        XCTAssertEqual(controls.snapshot.state, .completed)
        XCTAssertEqual(home.selectedMeetingID, meetingID)
        XCTAssertEqual(home.meetingContentRevisions[meetingID], 1)
    }

    @MainActor
    func testUnknownRecoveredSourcesStayPausedUntilUserChoosesSource() async throws {
        let storage = try StorageService(databaseURL: temporaryDatabaseURL())
        let queue = JobQueue(storageService: storage)
        let checkpointer = Checkpointer(storageService: storage)
        let meetingID = try await storage.createMeeting(title: "Legacy empty checkpoint", languageMode: .mixed)
        let job = try await queue.beginRecordingJob(meetingID: meetingID)
        let checkpoint = RecordingCheckpointPayload(meetingID: meetingID, segmentRelativePaths: [], totalRecordedSeconds: 0,
            lastSegmentDurationSeconds: 0, reason: .periodic, recordedAt: Date())
        try await checkpointer.saveRecordingCheckpoint(jobID: job.id, payload: checkpoint)
        try await queue.pauseRecordingJob(jobID: job.id)
        let recorder = RecorderCoordinator(storageService: storage, jobQueue: queue, checkpointer: checkpointer, memoryManager: MemoryManager())
        let controls = RecordingControlsViewModel(recorderCoordinator: recorder)
        await controls.restoreInterruptedRecording(jobID: job.id, storageService: storage)
        XCTAssertFalse(controls.captureMicrophone)
        XCTAssertFalse(controls.captureSystemAudio)
        controls.resumeRecording()
        XCTAssertEqual(controls.snapshot.state, .paused)
        XCTAssertEqual(controls.errorMessage, RecorderCoordinator.RecorderError.missingAudioInput.localizedDescription)
    }

    private func appendSampleMedia(storage: StorageService, meetingID: String, segmentIndex: Int, timelineOffset: Double? = nil) async throws {
        let source = try makeSampleMediaFile()
        let copied = try await storage.importMediaFile(sourceURL: source, meetingID: meetingID)
        try await storage.registerImportedMedia(meetingID: meetingID, relativePath: copied.relativePath,
            originalFilename: source.lastPathComponent, format: "wav", durationSeconds: 1,
            source: "microphone", segmentIndex: segmentIndex, timelineOffsetSeconds: timelineOffset ?? Double(segmentIndex))
    }

    private func temporaryDatabaseURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("varta-integration-\(UUID().uuidString).sqlite")
    }

    private func makeSampleMediaFile() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("sample-\(UUID().uuidString).wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        let samples = try XCTUnwrap(buffer.floatChannelData)
        samples[0].initialize(repeating: 0, count: 16_000)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}

// Synthetic transcript fixture: verifies persistence, never model accuracy.
private struct FixtureWhisperClient: WhisperCppClient {
    func transcribe(mediaURL: URL, languageMode: LanguageMode, promptContext: String) async throws -> [WhisperTranscribedSegment] {
        [WhisperTranscribedSegment(startSeconds: 0, endSeconds: 1, text: "We agreed to review the release next week.")]
    }
}
