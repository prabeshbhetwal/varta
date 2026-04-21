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
}
