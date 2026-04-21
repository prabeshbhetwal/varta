import XCTest
@testable import Varta

final class TranscriptCorrectionLockingTests: XCTestCase {
    func testLockedSegmentRejectsCorrectionUpdate() async throws {
        let storage = try StorageService(databaseURL: temporaryDatabaseURL())
        let meetingID = try await storage.createMeeting(title: "Lock Test", languageMode: .mixed)

        try await storage.replaceTranscriptSegments(
            meetingID: meetingID,
            segments: [
                NewTranscriptSegment(
                    startSeconds: 0,
                    endSeconds: 3,
                    text: "Original raw text",
                    languageTag: "en",
                    speakerLabel: nil
                )
            ]
        )

        guard let segment = try await storage.transcriptSegments(meetingID: meetingID).first else {
            XCTFail("Expected segment")
            return
        }

        try await storage.setTranscriptSegmentLock(segmentID: segment.id, isLocked: true)

        do {
            try await storage.updateTranscriptCorrection(segmentID: segment.id, correctedText: "Updated")
            XCTFail("Expected locked segment error")
        } catch StorageService.StorageError.transcriptSegmentLocked(let id) {
            XCTAssertEqual(id, segment.id)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let persisted = try await storage.transcriptSegments(meetingID: meetingID).first
        XCTAssertEqual(persisted?.text, "Original raw text")
        XCTAssertNil(persisted?.correctedText)
        XCTAssertEqual(persisted?.isLocked, true)
    }

    private func temporaryDatabaseURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("varta-lock-tests-\(UUID().uuidString).sqlite")
    }
}
