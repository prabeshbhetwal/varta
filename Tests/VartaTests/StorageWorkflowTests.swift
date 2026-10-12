import XCTest
@testable import Varta

final class StorageWorkflowTests: XCTestCase {
    func testCorrectionIncrementsRevisionAndSearchUsesEffectiveText() async throws {
        let storage = try StorageService(databaseURL: database())
        let id = try await storage.createMeeting(title: "Release planning", languageMode: .english)
        try await storage.replaceTranscriptSegments(meetingID: id, segments: [segment("Original proposal")])
        let before = try await storage.transcriptRevision(meetingID: id)
        let segments = try await storage.transcriptSegments(meetingID: id)
        let first = try XCTUnwrap(segments.first)
        try await storage.updateTranscriptCorrection(segmentID: first.id, correctedText: "Corrected deadline")
        let after = try await storage.transcriptRevision(meetingID: id)
        XCTAssertGreaterThan(after, before)
        let corrected = try await storage.searchTranscript(query: "corrected deadline")
        XCTAssertEqual(corrected.first?.text, "Corrected deadline")
        let original = try await storage.searchTranscript(query: "Original proposal")
        XCTAssertTrue(original.isEmpty)
        _ = try await storage.searchTranscript(query: "\" OR *")
        let title = try await storage.searchTranscript(query: "Release")
        XCTAssertEqual(title.first?.meetingID, id)
    }

    func testFinalTranscriptAndCheckpointCommitTogether() async throws {
        let storage = try StorageService(databaseURL: database())
        let id = try await storage.createMeeting(title: "Resume", languageMode: .english)
        try await storage.replaceTranscriptSegments(meetingID: id, segments: [segment("Previous")])
        let job = try await storage.createJob(meetingID: id, type: .transcription, status: .running)
        let revision = try await storage.transcriptRevision(meetingID: id)
        try await storage.saveTranscriptionResult(meetingID: id, jobID: job, segments: [segment("Completed")], checkpointBlob: "{\"completed\":true}", expectedTranscriptRevision: revision)
        let saved = try await storage.transcriptSegments(meetingID: id)
        let record = try await storage.job(id: job)
        let checkpoint = try await storage.processingState(jobID: job, stage: "transcription")
        XCTAssertEqual(saved.first?.text, "Completed")
        XCTAssertEqual(record?.status, .completed)
        XCTAssertEqual(checkpoint?.checkpointBlob, "{\"completed\":true}")
    }

    func testReviewedTranscriptCannotBeChangedByJobCompletion() async throws {
        let storage = try StorageService(databaseURL: database())
        let id = try await storage.createMeeting(title: "Review", languageMode: .english)
        try await storage.replaceTranscriptSegments(meetingID: id, segments: [segment("Previous")])
        let saved = try await storage.transcriptSegments(meetingID: id)
        try await storage.setTranscriptSegmentLock(segmentID: XCTUnwrap(saved.first?.id), isLocked: true)
        let job = try await storage.createJob(meetingID: id, type: .transcription, status: .running)
        let revision = try await storage.transcriptRevision(meetingID: id)
        do {
            try await storage.saveTranscriptionResult(meetingID: id, jobID: job, segments: [segment("Overwrite")], checkpointBlob: "{}", expectedTranscriptRevision: revision)
            XCTFail("Review must be preserved")
        } catch StorageService.StorageError.transcriptContainsReviewedSegments { }
        let record = try await storage.job(id: job)
        let after = try await storage.transcriptSegments(meetingID: id)
        let checkpoint = try await storage.processingState(jobID: job, stage: "transcription")
        XCTAssertEqual(record?.status, .running)
        XCTAssertEqual(after.first?.text, "Previous")
        XCTAssertNil(checkpoint)
    }

    func testMediaMetadataAndCalendarReceiptRoundTrip() async throws {
        let storage = try StorageService(databaseURL: database())
        let id = try await storage.createMeeting(title: "Capture", languageMode: .mixed)
        try await storage.registerImportedMedia(meetingID: id, relativePath: "Recordings/\(id)/segment.m4a", originalFilename: "segment.m4a", format: "m4a", durationSeconds: 10, source: "system", segmentIndex: 2, timelineOffsetSeconds: 20)
        let media = try await storage.importedMedia(for: id)
        XCTAssertEqual(media.first?.source, "system")
        XCTAssertEqual(media.first?.segmentIndex, 2)
        XCTAssertEqual(media.first?.timelineOffsetSeconds, 20)
        let candidate = CalendarCandidate(title: "Review", dateHint: nil, durationMinutes: nil, reason: "Explicit", sourceQuote: "Review")
        let candidates = String(decoding: try JSONEncoder().encode([candidate]), as: UTF8.self)
        let summary = SummaryContent(concise: "Fixture", detailed: "Fixture", bullets: "Fixture")
        let outputs = GeneratedOutputType.allCases.map {
            GeneratedOutput(type: $0, language: .english, content: $0 == .calendarCandidates ? candidates : "Fixture")
        }
        try await storage.saveMeetingOutputs(meetingID: id, outputs: MeetingOutputs(summary: summary, outputs: outputs), expectedTranscriptRevision: 0)
        let first = try await storage.reserveCalendarCandidate(meetingID: id, key: candidate.id)
        let repeated = try await storage.reserveCalendarCandidate(meetingID: id, key: candidate.id)
        XCTAssertTrue(first)
        XCTAssertFalse(repeated)
        try await storage.completeCalendarCandidate(meetingID: id, key: candidate.id, eventIdentifier: "fixture-event")
        let completed = try await storage.reserveCalendarCandidate(meetingID: id, key: candidate.id)
        XCTAssertFalse(completed)
    }

    func testMissingOrInvalidLocalModelsFailValidation() throws {
        let manifest = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Models/model-manifest.json")
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let config = LocalModelConfiguration(rootDirectory: root, manifestURL: manifest)
        XCTAssertThrowsError(try config.whisperModelURL())
        XCTAssertThrowsError(try config.languageModelDirectory())
    }

    private func database() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("workflow-fixture-\(UUID().uuidString).sqlite")
    }
    private func segment(_ text: String) -> NewTranscriptSegment {
        NewTranscriptSegment(startSeconds: 0, endSeconds: 1, text: text, languageTag: "en", speakerLabel: nil)
    }
}
