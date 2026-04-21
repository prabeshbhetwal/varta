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
}
