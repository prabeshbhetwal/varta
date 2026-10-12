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
        let service = TranscriptionService(storageService: storage, memoryManager: MemoryManager(), whisperClient: failing)
        do {
            _ = try await service.transcribeMeeting(meetingID: meeting, languageMode: .english)
            XCTFail("Expected failure on second audio window")
        } catch WindowFixtureWhisper.FixtureError.interrupted { }
        let old = try await storage.transcriptSegments(meetingID: meeting)
        XCTAssertEqual(old.map(\.text), ["Prior transcript"])
        let jobs = try await storage.jobs(statuses: [.failed], type: .transcription)
        let job = try XCTUnwrap(jobs.first)
        let resumedClient = WindowFixtureWhisper()
        let resumed = TranscriptionService(storageService: storage, memoryManager: MemoryManager(), whisperClient: resumedClient)
        let transcript = try await resumed.transcribeMeeting(meetingID: meeting, languageMode: .english, resumeJobID: job.id)
        let resumedCalls = await resumedClient.calls
        XCTAssertEqual(resumedCalls, 1)
        XCTAssertEqual(transcript.count, 2)
        XCTAssertEqual(transcript[1].startSeconds, 30, accuracy: 0.001)
        let savedJob = try await storage.job(id: job.id)
        XCTAssertEqual(savedJob?.status, .completed)
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
    private(set) var calls = 0

    init(failOnCall: Int? = nil) { self.failOnCall = failOnCall }

    nonisolated func validateConfiguration() throws { }

    func transcribe(mediaURL: URL, languageMode: LanguageMode) async throws -> [WhisperTranscribedSegment] {
        calls += 1
        if calls == failOnCall { throw FixtureError.interrupted }
        return [WhisperTranscribedSegment(startSeconds: 0, endSeconds: 1, text: "Fixture window result")]
    }
}
