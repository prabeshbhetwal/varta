import AVFoundation
import XCTest
@testable import Varta

final class RecordingCrashRecoveryIntegrationTests: XCTestCase {
    func testCrashRelaunchResumesFromLastCheckpoint() async throws {
        let dbURL = temporaryDatabaseURL()

        do {
            let storage = try StorageService(databaseURL: dbURL)
            let queue = JobQueue(storageService: storage)
            let checkpointer = Checkpointer(storageService: storage)

            let meetingID = try await storage.createMeeting(title: "Crash Recovery", languageMode: .mixed)
            let job = try await queue.beginRecordingJob(meetingID: meetingID)

            let checkpoint = RecordingCheckpointPayload(
                meetingID: meetingID,
                segmentRelativePaths: ["Recordings/seg-0.m4a", "Recordings/seg-1.m4a"],
                totalRecordedSeconds: 120,
                lastSegmentDurationSeconds: 44,
                reason: .periodic,
                recordedAt: Date()
            )

            try await checkpointer.saveRecordingCheckpoint(jobID: job.id, payload: checkpoint)
        }

        do {
            let storage = try StorageService(databaseURL: dbURL)
            let queue = JobQueue(storageService: storage)
            let checkpointer = Checkpointer(storageService: storage)

            let pausedJobs = try await queue.recoverInterruptedRecordingJobs()
            XCTAssertEqual(pausedJobs.count, 1)
            XCTAssertEqual(pausedJobs.first?.status, .paused)

            let recovered = try await checkpointer.latestRecordingCheckpoint(jobID: pausedJobs[0].id)
            XCTAssertEqual(recovered?.segmentRelativePaths.count, 2)
            let totalRecordedSeconds = try XCTUnwrap(recovered?.totalRecordedSeconds)
            XCTAssertEqual(totalRecordedSeconds, 120, accuracy: 0.001)
        }
    }

    private func temporaryDatabaseURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("varta-recovery-\(UUID().uuidString).sqlite")
    }

    func testStartupDatabaseFailureLeavesRecorderRetryable() async throws {
        let storage = try StorageService(databaseURL: temporaryDatabaseURL())
        let recorder = RecorderCoordinator(
            storageService: storage, jobQueue: JobQueue(storageService: storage),
            checkpointer: Checkpointer(storageService: storage), memoryManager: MemoryManager()
        )
        for _ in 0..<2 {
            do {
                try await recorder.startRecording(configuration: RecorderStartConfiguration(
                    meetingID: "nonexistent-fixture", captureMicrophone: true, captureSystemAudio: false
                ))
                XCTFail("Expected foreign-key failure before opening audio devices")
            } catch {
                let snapshot = await recorder.currentSnapshot()
                XCTAssertEqual(snapshot.state, .failed)
                XCTAssertNil(snapshot.meetingID)
            }
        }
    }

    func testMissingCheckpointAndEmptyMediaResumeStaysPausedWithRecoverableError() async throws {
        let storage = try StorageService(databaseURL: temporaryDatabaseURL())
        let queue = JobQueue(storageService: storage)
        let checkpointer = Checkpointer(storageService: storage)
        let meeting = try await storage.createMeeting(title: "Early crash", languageMode: .mixed)
        let job = try await queue.beginRecordingJob(meetingID: meeting)
        _ = try await queue.recoverInterruptedRecordingJobs()
        let recorder = RecorderCoordinator(storageService: storage, jobQueue: queue,
            checkpointer: checkpointer, memoryManager: MemoryManager())
        try await recorder.restoreInterruptedRecording(jobID: job.id)
        do {
            try await recorder.resumeRecording()
            XCTFail("Unknown capture sources must never enter Recording")
        } catch RecorderCoordinator.RecorderError.missingAudioInput { }
        let snapshot = await recorder.currentSnapshot()
        XCTAssertEqual(snapshot.state, .paused)
        XCTAssertEqual(snapshot.meetingID, meeting)
        XCTAssertEqual(snapshot.jobID, job.id)
        XCTAssertEqual(snapshot.segmentCount, 0)
        XCTAssertTrue(snapshot.note?.contains("Choose at least one audio source") == true)
        let savedJob = try await storage.job(id: job.id)
        let checkpoint = try await checkpointer.latestRecordingCheckpoint(jobID: job.id)
        XCTAssertEqual(savedJob?.status, .paused)
        XCTAssertNil(checkpoint)
    }

    func testEmptyInitialCheckpointPreservesCaptureChoicesWhenResumeHasNoSources() async throws {
        let storage = try StorageService(databaseURL: temporaryDatabaseURL())
        let queue = JobQueue(storageService: storage)
        let checkpointer = Checkpointer(storageService: storage)
        let meeting = try await storage.createMeeting(title: "Initial checkpoint", languageMode: .mixed)
        let job = try await queue.beginRecordingJob(meetingID: meeting)
        let initial = RecordingCheckpointPayload(meetingID: meeting, segmentRelativePaths: [],
            totalRecordedSeconds: 0, lastSegmentDurationSeconds: 0, reason: .periodic, recordedAt: Date(),
            captureMicrophone: true, captureSystemAudio: false, nextSegmentIndex: 0)
        try await checkpointer.saveRecordingCheckpoint(jobID: job.id, payload: initial)
        _ = try await queue.recoverInterruptedRecordingJobs()
        let recorder = RecorderCoordinator(storageService: storage, jobQueue: queue,
            checkpointer: checkpointer, memoryManager: MemoryManager())
        try await recorder.restoreInterruptedRecording(jobID: job.id)
        do {
            try await recorder.resumeRecording(captureMicrophone: false, captureSystemAudio: false)
            XCTFail("Source-free UI overrides must remain recoverable")
        } catch RecorderCoordinator.RecorderError.missingAudioInput { }
        let snapshot = await recorder.currentSnapshot()
        let preserved = try await checkpointer.latestRecordingCheckpoint(jobID: job.id)
        XCTAssertEqual(snapshot.state, .paused)
        XCTAssertEqual(preserved?.captureMicrophone, true)
        XCTAssertEqual(preserved?.captureSystemAudio, false)
        XCTAssertEqual(preserved?.nextSegmentIndex, 0)
        let sources = RecordingControlsViewModel.recoveredAudioSources(checkpoint: preserved, media: [], jobID: job.id)
        XCTAssertTrue(sources.microphone)
        XCTAssertFalse(sources.system)
    }

    func testAutomaticDurationStopPublishesCompletionExactlyOnceWithoutCapture() async throws {
        let storage = try StorageService(databaseURL: temporaryDatabaseURL())
        let queue = JobQueue(storageService: storage)
        let checkpointer = Checkpointer(storageService: storage)
        let meeting = try await storage.createMeeting(title: "Duration completion", languageMode: .mixed)
        let job = try await queue.beginRecordingJob(meetingID: meeting)
        let path = "Recordings/\(meeting)/segment-0-microphone-\(job.id).wav"
        let root = await storage.appSupportDirectory()
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeShortAudioFixture(to: url)
        // A short fixture with a stored timeline offset exercises the four-hour transition.
        try await storage.registerImportedMedia(meetingID: meeting, relativePath: path, originalFilename: url.lastPathComponent,
            format: "wav", durationSeconds: 0.125, source: "microphone", segmentIndex: 0, timelineOffsetSeconds: 14_399.875)
        try await checkpointer.saveRecordingCheckpoint(jobID: job.id, payload: RecordingCheckpointPayload(
            meetingID: meeting, segmentRelativePaths: [path], totalRecordedSeconds: 14_400,
            lastSegmentDurationSeconds: 0.125, reason: .periodic, recordedAt: Date(),
            captureMicrophone: true, captureSystemAudio: false, nextSegmentIndex: 1))
        _ = try await queue.recoverInterruptedRecordingJobs()
        let recorder = RecorderCoordinator(storageService: storage, jobQueue: queue,
            checkpointer: checkpointer, memoryManager: MemoryManager())
        try await recorder.restoreInterruptedRecording(jobID: job.id)
        let stopped = await recorder.stopRecordingAtDurationLimitIfNeeded()
        XCTAssertTrue(stopped)
        let snapshot = await recorder.currentSnapshot()
        XCTAssertEqual(snapshot.state, .completed)
        XCTAssertEqual(snapshot.meetingID, meeting)
        XCTAssertEqual(snapshot.jobID, job.id)
        XCTAssertEqual(snapshot.totalRecordedSeconds, 14_400, accuracy: 0.001)
        let completion = await recorder.takeCompletedRecording()
        XCTAssertEqual(completion?.meetingID, meeting)
        XCTAssertEqual(completion?.jobID, job.id)
        let second = await recorder.takeCompletedRecording()
        XCTAssertNil(second)
        await recorder.stopRecording()
        let repeated = await recorder.takeCompletedRecording()
        XCTAssertNil(repeated)
        let jobAfter = try await storage.job(id: job.id)
        XCTAssertEqual(jobAfter?.status, .completed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    private func writeShortAudioFixture(to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_000))
        buffer.frameLength = 2_000
        let samples = try XCTUnwrap(buffer.floatChannelData)
        samples[0].update(repeating: 0, count: 2_000)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    func testSingleBufferRecordingIncludesFinalSampleDuration() async throws {
        let output = temporaryDatabaseURL().appendingPathExtension("m4a")
        let writer = RecordingWriter()
        try writer.startWriting(to: output)
        try writer.append(sampleBuffer: makePCMBuffer(sample: 0))
        let duration = try await writer.finishWriting()
        XCTAssertEqual(duration, 0.1, accuracy: 0.001)
        let assetDuration = try await AVURLAsset(url: output).load(.duration)
        XCTAssertGreaterThan(CMTimeGetSeconds(assetDuration), 0)
    }

    func testFinalisingLiveWritersPreservesMaximumAndPublishesCompletionOnce() async throws {
        let storage = try StorageService(databaseURL: temporaryDatabaseURL())
        let queue = JobQueue(storageService: storage)
        let checkpointer = Checkpointer(storageService: storage)
        let meeting = try await storage.createMeeting(title: "Live writer finalisation", languageMode: .english)
        let job = try await queue.beginRecordingJob(meetingID: meeting)
        try await checkpointer.saveRecordingCheckpoint(jobID: job.id, payload: RecordingCheckpointPayload(
            meetingID: meeting, segmentRelativePaths: [], totalRecordedSeconds: 0,
            lastSegmentDurationSeconds: 0, reason: .periodic, recordedAt: Date(),
            captureMicrophone: true, captureSystemAudio: true, nextSegmentIndex: 1))
        _ = try await queue.recoverInterruptedRecordingJobs()
        let recorder = RecorderCoordinator(storageService: storage, jobQueue: queue,
            checkpointer: checkpointer, memoryManager: MemoryManager())
        try await recorder.restoreInterruptedRecording(jobID: job.id)
        let root = await storage.appSupportDirectory()
        let sources: [(RecorderCoordinator.AudioSource, Int)] = [(.microphone, 4_800), (.system, 2_400)]
        for (source, frames) in sources {
            let output = root.appendingPathComponent("Recordings/\(meeting)/segment-0-\(source.rawValue)-\(job.id).m4a")
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            let writer = RecordingWriter()
            try writer.startWriting(to: output)
            try writer.append(sampleBuffer: makePCMBuffer(sample: 0, frames: frames))
            try await recorder.finalise([source: writer], segmentIndex: 0)
            let snapshot = await recorder.currentSnapshot()
            XCTAssertTrue(snapshot.totalRecordedSeconds.isFinite)
            XCTAssertEqual(snapshot.totalRecordedSeconds, 0.1, accuracy: 0.001)
        }
        let records = try await storage.importedMedia(for: meeting)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(Set(records.compactMap(\.source)), ["microphone", "system"])
        await recorder.stopRecording()
        let checkpoint = try await checkpointer.latestRecordingCheckpoint(jobID: job.id)
        XCTAssertEqual(checkpoint?.segmentRelativePaths.count, 2)
        XCTAssertEqual(try XCTUnwrap(checkpoint?.totalRecordedSeconds), 0.1, accuracy: 0.001)
        let savedJob = try await storage.job(id: job.id)
        XCTAssertEqual(savedJob?.status, .completed)
        let completion = await recorder.takeCompletedRecording()
        XCTAssertEqual(completion?.jobID, job.id)
        let repeated = await recorder.takeCompletedRecording()
        XCTAssertNil(repeated)
    }

    func testNonFiniteAudioSampleThrowsInsteadOfCrashing() async throws {
        let writer = RecordingWriter()
        try writer.startWriting(to: temporaryDatabaseURL().appendingPathExtension("m4a"))
        do {
            try writer.append(sampleBuffer: makePCMBuffer(sample: .nan))
            XCTFail("Expected invalid PCM sample")
        } catch RecordingWriter.WriterError.invalidSampleBuffer { }
        _ = try await writer.finishWriting()
    }

    private func makePCMBuffer(sample: Float, frames: Int = 4_800) throws -> CMSampleBuffer {
        var format = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked, mBytesPerPacket: 4,
            mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1,
            mBitsPerChannel: 32, mReserved: 0
        )
        var description: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &format,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &description), noErr)
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
            memoryBlock: nil, blockLength: frames * 4, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: frames * 4,
            flags: 0, blockBufferOut: &block), noErr)
        let dataBlock = try XCTUnwrap(block)
        let samples = Array(repeating: sample, count: frames)
        try samples.withUnsafeBytes { bytes in
            XCTAssertEqual(CMBlockBufferReplaceDataBytes(with: try XCTUnwrap(bytes.baseAddress), blockBuffer: dataBlock,
                offsetIntoDestination: 0, dataLength: bytes.count), noErr)
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMTime(seconds: 100, preferredTimescale: 48_000), decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: dataBlock,
            formatDescription: try XCTUnwrap(description), sampleCount: frames,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: [4], sampleBufferOut: &buffer), noErr)
        return try XCTUnwrap(buffer)
    }
}
