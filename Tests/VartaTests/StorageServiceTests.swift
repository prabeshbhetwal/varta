import GRDB
import XCTest
@testable import Varta

final class StorageServiceTests: XCTestCase {
    func testMigrationsCreateRequiredTables() async throws {
        let databaseURL = temporaryDatabaseURL()
        let storage = try StorageService(databaseURL: databaseURL)

        let tables = try await storage.tableNames()

        let expectedTables: Set<String> = [
            "audio_files",
            "calendar_links",
            "diarization_segments",
            "generated_outputs",
            "glossary_terms",
            "jobs",
            "meetings",
            "processing_state",
            "search_fts",
            "settings",
            "summaries",
            "transcript_segments"
        ]

        XCTAssertTrue(expectedTables.isSubset(of: Set(tables)))
    }

    func testSettingsRoundTrip() async throws {
        let databaseURL = temporaryDatabaseURL()
        let storage = try StorageService(databaseURL: databaseURL)
        let store = SettingsStore(storageService: storage)

        try await store.set("Team Meeting", for: .defaultMeetingTitlePrefix)
        try await store.set(false, for: .enableCalendarSuggestions)

        let prefix = try await store.string(for: .defaultMeetingTitlePrefix)
        let suggestionsEnabled = try await store.bool(for: .enableCalendarSuggestions)

        XCTAssertEqual(prefix, "Team Meeting")
        XCTAssertEqual(suggestionsEnabled, false)
    }

    private func temporaryDatabaseURL() -> URL {
        let fileName = "varta-tests-\(UUID().uuidString).sqlite"
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(fileName)
    }

    func testExplicitDatabaseIsolatesCompanionFiles() async throws {
        let databaseURL = temporaryDatabaseURL()
        let storage = try StorageService(databaseURL: databaseURL)
        let support = await storage.appSupportDirectory()
        XCTAssertEqual(support, databaseURL.deletingPathExtension().appendingPathExtension("files"))
    }

    func testDuplicateImportPreservesBothFiles() async throws {
        let databaseURL = temporaryDatabaseURL()
        let storage = try StorageService(databaseURL: databaseURL)
        let meetingID = try await storage.createMeeting(title: "Duplicate imports", languageMode: .mixed)
        let sourceURL = databaseURL.appendingPathExtension("txt")
        try "Synthetic import".write(to: sourceURL, atomically: true, encoding: .utf8)
        let first = try await storage.importMediaFile(sourceURL: sourceURL, meetingID: meetingID)
        let second = try await storage.importMediaFile(sourceURL: sourceURL, meetingID: meetingID)
        XCTAssertNotEqual(first.relativePath, second.relativePath)
        XCTAssertEqual(try String(contentsOf: first.destinationURL), "Synthetic import")
        XCTAssertEqual(try String(contentsOf: second.destinationURL), "Synthetic import")
    }

    func testFTSCorrectionsOnMigrationAndEdit() async throws {
        let databaseURL = temporaryDatabaseURL()
        let queue = try DatabaseQueue(path: databaseURL.path)
        try VartaMigrations.makeMigrator().migrate(queue, upTo: "003_diarization_segments")
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO meetings (id, title) VALUES ('fixture', 'FTS migration')")
            try db.execute(sql: "INSERT INTO transcript_segments (meeting_id, start_seconds, end_seconds, text, corrected_text) VALUES ('fixture', 0, 1, 'rawterm', 'reviewedterm')")
        }
        let storage = try StorageService(databaseURL: databaseURL)
        let migratedMatches = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_fts WHERE search_fts MATCH 'reviewedterm'")
        }
        XCTAssertEqual(migratedMatches, 1)
        try await storage.updateTranscriptCorrection(segmentID: 1, correctedText: "updatedterm")
        let updatedMatches = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_fts WHERE search_fts MATCH 'updatedterm'")
        }
        let staleMatches = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_fts WHERE search_fts MATCH 'reviewedterm'")
        }
        XCTAssertEqual(updatedMatches, 1)
        XCTAssertEqual(staleMatches, 0)
    }

    @MainActor
    func testTestHostDoesNotBootstrapPersonalStorage() {
        guard ProcessInfo.processInfo.environment["VARTA_TESTING"] == "1" else {
            XCTFail("Test scheme must isolate app startup")
            return
        }
        XCTAssertNil(AppModel().storageService)
    }

    func testDeleteArchivesAudioInsteadOfRemovingIt() async throws {
        let storage = try StorageService(databaseURL: temporaryDatabaseURL())
        let meetingID = try await storage.createMeeting(title: "Synthetic archive", languageMode: .english)
        let support = await storage.appSupportDirectory()
        let directory = await storage.recordingsDirectory(meetingID: meetingID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audio = directory.appendingPathComponent("synthetic.txt")
        try "Synthetic audio fixture".write(to: audio, atomically: true, encoding: .utf8)
        try await storage.registerImportedMedia(meetingID: meetingID, relativePath: "Recordings/\(meetingID)/synthetic.txt", originalFilename: "synthetic.txt", format: "txt", durationSeconds: 1)
        try await storage.deleteMeetingAndFiles(meetingID: meetingID)
        let meetings = try await storage.listMeetings()
        XCTAssertTrue(meetings.isEmpty)
        let trash = support.appendingPathComponent("_trash/\(meetingID)")
        let archive = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil).first)
        let archivedAudio = archive.appendingPathComponent("Recordings/synthetic.txt")
        XCTAssertEqual(try String(contentsOf: archivedAudio), "Synthetic audio fixture")
    }

    func testDeleteRejectsPathsOutsideMeetingFolder() async throws {
        let storage = try StorageService(databaseURL: temporaryDatabaseURL())
        let meetingID = try await storage.createMeeting(title: "Unsafe fixture", languageMode: .english)
        do {
            try await storage.registerImportedMedia(meetingID: meetingID, relativePath: "../outside.txt", originalFilename: "outside.txt", format: "txt", durationSeconds: nil)
            XCTFail("Registration must reject traversal")
        } catch StorageService.StorageError.unsafeMediaPath { }
        try await storage.registerImportedMedia(meetingID: meetingID, relativePath: "Other/outside.txt", originalFilename: "outside.txt", format: "txt", durationSeconds: nil)
        do {
            try await storage.deleteMeetingAndFiles(meetingID: meetingID)
            XCTFail("Expected path containment validation")
        } catch StorageService.StorageError.unsafeMediaPath { }
        let meetings = try await storage.listMeetings()
        XCTAssertEqual(meetings.count, 1)
    }
}
