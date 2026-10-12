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

    func testRegenerationPreservesReviewedSegments() async throws {
        for locked in [false, true] {
            let storage = try StorageService(databaseURL: temporaryDatabaseURL())
            let meetingID = try await storage.createMeeting(title: "Reviewed transcript", languageMode: .english)
            let raw = NewTranscriptSegment(startSeconds: 0, endSeconds: 1, text: "Raw text", languageTag: "en", speakerLabel: nil)
            try await storage.replaceTranscriptSegments(meetingID: meetingID, segments: [raw])
            let segments = try await storage.transcriptSegments(meetingID: meetingID)
            let segment = try XCTUnwrap(segments.first)
            if locked {
                try await storage.setTranscriptSegmentLock(segmentID: segment.id, isLocked: true)
            } else {
                try await storage.updateTranscriptCorrection(segmentID: segment.id, correctedText: "Reviewed text")
            }
            do {
                try await storage.replaceTranscriptSegments(meetingID: meetingID, segments: [])
                XCTFail("Regeneration must preserve review")
            } catch StorageService.StorageError.transcriptContainsReviewedSegments { }
            let persisted = try await storage.transcriptSegments(meetingID: meetingID)
            XCTAssertEqual(persisted.first?.id, segment.id)
            XCTAssertEqual(persisted.first?.text, "Raw text")
            XCTAssertEqual(persisted.first?.correctedText, locked ? nil : "Reviewed text")
            XCTAssertEqual(persisted.first?.isLocked, locked)
        }
    }

    func testInvalidTimestampsDoNotReplaceTranscript() async throws {
        let storage = try StorageService(databaseURL: temporaryDatabaseURL())
        let meetingID = try await storage.createMeeting(title: "Timing validation", languageMode: .english)
        try await storage.replaceTranscriptSegments(meetingID: meetingID, segments: [
            NewTranscriptSegment(startSeconds: 0, endSeconds: 1, text: "Preserved", languageTag: "en", speakerLabel: nil)
        ])
        do {
            try await storage.replaceTranscriptSegments(meetingID: meetingID, segments: [
                NewTranscriptSegment(startSeconds: .nan, endSeconds: 1, text: "Invalid", languageTag: "en", speakerLabel: nil)
            ])
            XCTFail("Expected timing validation")
        } catch StorageService.StorageError.invalidTranscriptTiming { }
        let persisted = try await storage.transcriptSegments(meetingID: meetingID)
        XCTAssertEqual(persisted.map(\.text), ["Preserved"])
    }
}
