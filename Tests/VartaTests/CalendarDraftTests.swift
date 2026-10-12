import Foundation
import XCTest
@testable import Varta

final class CalendarDraftTests: XCTestCase {
    func testDraftRejectsInvalidTitlesAndDurations() throws {
        for title in [" ", String(repeating: "x", count: 201)] {
            XCTAssertThrowsError(try CalendarDraft(title: title, startDate: Date(), durationMinutes: 30, notes: "").validated())
        }
        for duration in [Double(0), -1, Double.infinity, Double.nan, 1_441] {
            XCTAssertThrowsError(try CalendarDraft(title: "Review", startDate: Date(), durationMinutes: duration, notes: "").validated())
        }
        let validated = try CalendarDraft(title: "  Review  ", startDate: Date(timeIntervalSince1970: 100), durationMinutes: 30, notes: "Source").validated()
        XCTAssertEqual(validated.title, "Review")
        XCTAssertEqual(validated.endDate.timeIntervalSince1970, 1_900)
    }

    @MainActor
    func testCreatedCandidateCannotBeSavedTwice() async throws {
        let storage = try StorageService(databaseURL: temporaryDatabaseURL())
        let meetingID = try await preparedMeeting(storage)
        let writer = FixtureCalendarWriter()
        let service = CalendarService(storageService: storage, writer: writer)
        try await service.createEvent(meetingID: meetingID, candidateKey: candidateKey, draft: draft)
        do {
            try await service.createEvent(meetingID: meetingID, candidateKey: candidateKey, draft: draft)
            XCTFail("Duplicate event was permitted")
        } catch CalendarCreationError.previouslyReserved { }
        XCTAssertEqual(writer.saveCount, 1)
    }

    @MainActor
    func testUncertainSaveBlocksRetry() async throws {
        let storage = try StorageService(databaseURL: temporaryDatabaseURL())
        let meetingID = try await preparedMeeting(storage)
        let writer = FixtureCalendarWriter()
        writer.failure = .uncertainSave
        let service = CalendarService(storageService: storage, writer: writer)
        do {
            try await service.createEvent(meetingID: meetingID, candidateKey: candidateKey, draft: draft)
            XCTFail("Uncertain save should fail")
        } catch CalendarCreationError.uncertainSave { }
        writer.failure = nil
        do {
            try await service.createEvent(meetingID: meetingID, candidateKey: candidateKey, draft: draft)
            XCTFail("Uncertain receipt should suppress retry")
        } catch CalendarCreationError.previouslyReserved { }
        XCTAssertEqual(writer.saveCount, 1)
    }

    @MainActor
    func testDeniedPermissionDoesNotReserveCandidate() async throws {
        let storage = try StorageService(databaseURL: temporaryDatabaseURL())
        let meetingID = try await preparedMeeting(storage)
        let writer = FixtureCalendarWriter()
        writer.grantsAccess = false
        let service = CalendarService(storageService: storage, writer: writer)
        do {
            try await service.createEvent(meetingID: meetingID, candidateKey: candidateKey, draft: draft)
            XCTFail("Denied permission should fail")
        } catch CalendarCreationError.permissionDenied { }
        writer.grantsAccess = true
        try await service.createEvent(meetingID: meetingID, candidateKey: candidateKey, draft: draft)
        XCTAssertEqual(writer.saveCount, 1)
    }

    @MainActor
    func testMissingDefaultCalendarReleasesKnownUnwrittenReservation() async throws {
        let storage = try StorageService(databaseURL: temporaryDatabaseURL())
        let meetingID = try await preparedMeeting(storage)
        let writer = FixtureCalendarWriter()
        writer.failure = .calendarUnavailable
        let service = CalendarService(storageService: storage, writer: writer)
        do {
            try await service.createEvent(meetingID: meetingID, candidateKey: candidateKey, draft: draft)
            XCTFail("Missing calendar should fail")
        } catch CalendarCreationError.calendarUnavailable { }
        writer.failure = nil
        try await service.createEvent(meetingID: meetingID, candidateKey: candidateKey, draft: draft)
        XCTAssertEqual(writer.saveCount, 2)
    }

    @MainActor
    func testTranscriptChangedDuringPermissionRequestPreventsSave() async throws {
        let storage = try StorageService(databaseURL: temporaryDatabaseURL())
        let meetingID = try await preparedMeeting(storage)
        let writer = FixtureCalendarWriter()
        writer.beforeAccess = {
            try await storage.replaceTranscriptSegments(meetingID: meetingID, segments: [
                NewTranscriptSegment(startSeconds: 0, endSeconds: 1, text: "Changed", languageTag: "en", speakerLabel: nil)
            ])
        }
        let service = CalendarService(storageService: storage, writer: writer)
        do {
            try await service.createEvent(meetingID: meetingID, candidateKey: candidateKey, draft: draft)
            XCTFail("Stale calendar suggestion should fail")
        } catch StorageService.StorageError.transcriptChanged { }
        XCTAssertEqual(writer.saveCount, 0)
    }

    private var candidate: CalendarCandidate {
        CalendarCandidate(title: "Review", dateHint: nil, durationMinutes: 30, reason: "Explicit fixture", sourceQuote: "Review")
    }

    private var candidateKey: String { candidate.id }

    private func preparedMeeting(_ storage: StorageService) async throws -> String {
        let meetingID = try await storage.createMeeting(title: "Calendar fixture", languageMode: .english)
        let calendar = String(decoding: try JSONEncoder().encode([candidate]), as: UTF8.self)
        let summary = SummaryContent(concise: "Fixture", detailed: "Fixture", bullets: "Fixture")
        let outputs = GeneratedOutputType.allCases.map {
            GeneratedOutput(type: $0, language: .english, content: $0 == .calendarCandidates ? calendar : "Fixture")
        }
        try await storage.saveMeetingOutputs(meetingID: meetingID, outputs: MeetingOutputs(summary: summary, outputs: outputs), expectedTranscriptRevision: 0)
        return meetingID
    }

    private var draft: CalendarDraft { CalendarDraft(title: "Review", startDate: Date(), durationMinutes: 30, notes: "Fixture") }
    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("calendar-fixture-\(UUID().uuidString).sqlite")
    }
}

@MainActor
private final class FixtureCalendarWriter: CalendarEventWriting {
    var grantsAccess = true
    var failure: CalendarCreationError?
    var saveCount = 0
    var beforeAccess: (@MainActor () async throws -> Void)?
    func requestWriteAccess() async throws -> Bool {
        try await beforeAccess?()
        return grantsAccess
    }
    func save(_ draft: CalendarDraft) throws -> String {
        saveCount += 1
        if let failure { throw failure }
        return "fixture-event"
    }
}
