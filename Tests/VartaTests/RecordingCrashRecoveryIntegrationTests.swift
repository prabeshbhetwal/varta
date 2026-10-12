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

    func testNonFiniteAudioSampleThrowsInsteadOfCrashing() async throws {
        let writer = RecordingWriter()
        try writer.startWriting(to: temporaryDatabaseURL().appendingPathExtension("m4a"))
        do {
            try writer.append(sampleBuffer: makePCMBuffer(sample: .nan))
            XCTFail("Expected invalid PCM sample")
        } catch RecordingWriter.WriterError.invalidSampleBuffer { }
        _ = try await writer.finishWriting()
    }

    private func makePCMBuffer(sample: Float) throws -> CMSampleBuffer {
        let frames = 4_800
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
