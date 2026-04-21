import XCTest
@testable import Varta

final class CheckpointerTests: XCTestCase {
    func testCheckpointRoundTrip() async throws {
        let storage = try StorageService(databaseURL: temporaryDatabaseURL())
        let jobQueue = JobQueue(storageService: storage)
        let checkpointer = Checkpointer(storageService: storage)

        let meetingID = try await storage.createMeeting(title: "Checkpoint", languageMode: .mixed)
        let job = try await jobQueue.beginRecordingJob(meetingID: meetingID)

        let first = RecordingCheckpointPayload(
            meetingID: meetingID,
            segmentRelativePaths: ["Recordings/one.m4a"],
            totalRecordedSeconds: 32,
            lastSegmentDurationSeconds: 32,
            reason: .periodic,
            recordedAt: Date()
        )

        try await checkpointer.saveRecordingCheckpoint(jobID: job.id, payload: first)

        let second = RecordingCheckpointPayload(
            meetingID: meetingID,
            segmentRelativePaths: ["Recordings/one.m4a", "Recordings/two.m4a"],
            totalRecordedSeconds: 67,
            lastSegmentDurationSeconds: 35,
            reason: .pause,
            recordedAt: Date()
        )

        try await checkpointer.saveRecordingCheckpoint(jobID: job.id, payload: second)

        let restored = try await checkpointer.latestRecordingCheckpoint(jobID: job.id)
        XCTAssertEqual(restored?.meetingID, meetingID)
        XCTAssertEqual(restored?.segmentRelativePaths.count, 2)
        let totalRecordedSeconds = try XCTUnwrap(restored?.totalRecordedSeconds)
        XCTAssertEqual(totalRecordedSeconds, 67, accuracy: 0.001)
        XCTAssertEqual(restored?.reason, .pause)
    }

    private func temporaryDatabaseURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("varta-checkpoint-\(UUID().uuidString).sqlite")
    }
}
