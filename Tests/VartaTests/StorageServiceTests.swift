import GRDB
import XCTest
import Darwin
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

    #if VARTA_REQUIRE_ISOLATED_DATA
    @MainActor
    func testIsolatedBuildRejectsUnsafeDirectoryBeforeStorage() async throws {
        guard ProcessInfo.processInfo.environment["VARTA_TESTING"] == "1" else {
            XCTFail("Test scheme must isolate app startup")
            return
        }
        let previous = ProcessInfo.processInfo.environment["VARTA_DATA_DIRECTORY"]
        let before = defaultStorageMetadata()
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let defaultDirectory = support.appendingPathComponent("Varta", isDirectory: true)
        let fixture = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("varta-isolation-alias-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let directoryAlias = fixture.appendingPathComponent("default-directory", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: directoryAlias, withDestinationURL: defaultDirectory)
        let fileAliasDirectory = fixture.appendingPathComponent("database-alias", isDirectory: true)
        try FileManager.default.createDirectory(at: fileAliasDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fileAliasDirectory.appendingPathComponent("varta.sqlite"),
            withDestinationURL: defaultDirectory.appendingPathComponent("varta.sqlite"))
        defer {
            if let previous { setenv("VARTA_DATA_DIRECTORY", previous, 1) }
            else { unsetenv("VARTA_DATA_DIRECTORY") }
        }
        for directory in [nil, "", " \n\t ", "relative-data", defaultDirectory.path, directoryAlias.path, fileAliasDirectory.path] as [String?] {
            if let directory { setenv("VARTA_DATA_DIRECTORY", directory, 1) }
            else { unsetenv("VARTA_DATA_DIRECTORY") }
            let model = AppModel()
            await model.bootstrap()
            XCTAssertNil(model.storageService)
            XCTAssertNil(model.settingsStore)
            XCTAssertNil(model.recorderCoordinator)
            XCTAssertNil(model.systemRuntimeCoordinator)
            guard case .failed(let message) = model.launchState else {
                XCTFail("Missing isolation must fail startup")
                continue
            }
            XCTAssertTrue(message.contains("VARTA_DATA_DIRECTORY"))
            XCTAssertEqual(defaultStorageMetadata(), before)
        }
    }

    @MainActor
    func testIsolatedBuildOpensExplicitDirectoryWithoutDefaultStorage() async throws {
        guard ProcessInfo.processInfo.environment["VARTA_TESTING"] == "1" else {
            XCTFail("Test scheme must isolate app startup")
            return
        }
        let previous = ProcessInfo.processInfo.environment["VARTA_DATA_DIRECTORY"]
        let before = defaultStorageMetadata()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("varta-isolated-bootstrap-\(UUID().uuidString)", isDirectory: true)
        setenv("VARTA_DATA_DIRECTORY", directory.path, 1)
        let model = AppModel()
        defer {
            model.systemRuntimeCoordinator?.stop()
            if let previous { setenv("VARTA_DATA_DIRECTORY", previous, 1) }
            else { unsetenv("VARTA_DATA_DIRECTORY") }
        }
        await model.bootstrap()
        guard case .ready = model.launchState else {
            XCTFail("Explicit isolated storage must initialise")
            return
        }
        let storage = try XCTUnwrap(model.storageService)
        let files = await storage.appSupportDirectory()
        XCTAssertEqual(files.path, directory.appendingPathComponent("varta.files").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("varta.sqlite").path))
        XCTAssertEqual(defaultStorageMetadata(), before)
    }

    @MainActor
    func testIsolatedBuildRejectsHardLinkedDefaultDatabase() async throws {
        guard ProcessInfo.processInfo.environment["VARTA_TESTING"] == "1" else {
            XCTFail("Test scheme must isolate app startup")
            return
        }
        let previous = ProcessInfo.processInfo.environment["VARTA_DATA_DIRECTORY"]
        defer {
            if let previous { setenv("VARTA_DATA_DIRECTORY", previous, 1) }
            else { unsetenv("VARTA_DATA_DIRECTORY") }
        }
        let fixture = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("varta-isolation-hard-link-\(UUID().uuidString)", isDirectory: true)
        let support = fixture.appendingPathComponent("synthetic-support", isDirectory: true)
        let normalDirectory = support.appendingPathComponent("Varta", isDirectory: true)
        let aliasDirectory = fixture.appendingPathComponent("alias", isDirectory: true)
        for directory in [normalDirectory, aliasDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let normalDatabase = normalDirectory.appendingPathComponent("varta.sqlite")
        let marker = Data("Synthetic database marker; must not be opened".utf8)
        try marker.write(to: normalDatabase)
        try FileManager.default.linkItem(at: normalDatabase, to: aliasDirectory.appendingPathComponent("varta.sqlite"))
        let before = try FileManager.default.attributesOfItem(atPath: normalDatabase.path)
        setenv("VARTA_DATA_DIRECTORY", aliasDirectory.path, 1)
        let fileManager = IsolationFileManager(support: support)
        let model = AppModel()

        await model.bootstrap(fileManager: fileManager)

        XCTAssertNil(model.storageService)
        guard case .failed(let message) = model.launchState else {
            XCTFail("Hard-linked default storage must fail startup")
            return
        }
        XCTAssertTrue(message.contains("VARTA_DATA_DIRECTORY"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: aliasDirectory.appendingPathComponent("varta.files").path))
        XCTAssertEqual(try Data(contentsOf: normalDatabase), marker)
        let after = try FileManager.default.attributesOfItem(atPath: normalDatabase.path)
        XCTAssertEqual(after[.size] as? NSNumber, before[.size] as? NSNumber)
        XCTAssertEqual(after[.modificationDate] as? Date, before[.modificationDate] as? Date)
    }

    @MainActor
    func testIsolatedBuildRejectsWritableCompanionAndSidecarAliases() async throws {
        guard ProcessInfo.processInfo.environment["VARTA_TESTING"] == "1" else {
            XCTFail("Test scheme must isolate app startup")
            return
        }
        let previous = ProcessInfo.processInfo.environment["VARTA_DATA_DIRECTORY"]
        defer {
            if let previous { setenv("VARTA_DATA_DIRECTORY", previous, 1) }
            else { unsetenv("VARTA_DATA_DIRECTORY") }
        }
        let fixture = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("varta-isolation-writable-alias-\(UUID().uuidString)", isDirectory: true)
        let support = fixture.appendingPathComponent("synthetic-support", isDirectory: true)
        let normalDirectory = support.appendingPathComponent("Varta", isDirectory: true)
        try FileManager.default.createDirectory(at: normalDirectory, withIntermediateDirectories: true)
        let markerURL = normalDirectory.appendingPathComponent("synthetic-state.txt")
        let marker = Data("Synthetic default state; must remain unchanged".utf8)
        try marker.write(to: markerURL)
        let fileManager = IsolationFileManager(support: support)
        for index in 0..<4 {
            let directory = fixture.appendingPathComponent("case-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let files = directory.appendingPathComponent("varta.files", isDirectory: true)
            switch index {
            case 0:
                try FileManager.default.createSymbolicLink(at: files, withDestinationURL: normalDirectory)
            case 1:
                try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: files.appendingPathComponent("Prompts"), withDestinationURL: normalDirectory)
            case 2:
                try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("varta.sqlite-wal"), withDestinationURL: markerURL)
            default:
                try FileManager.default.linkItem(at: markerURL, to: directory.appendingPathComponent("varta.sqlite-shm"))
            }
            let before = try FileManager.default.attributesOfItem(atPath: markerURL.path)
            let directoryBefore = try FileManager.default.attributesOfItem(atPath: normalDirectory.path)
            let children = try FileManager.default.contentsOfDirectory(atPath: normalDirectory.path).sorted()
            setenv("VARTA_DATA_DIRECTORY", directory.path, 1)
            let model = AppModel()

            await model.bootstrap(fileManager: fileManager)

            XCTAssertNil(model.storageService)
            XCTAssertNil(model.settingsStore)
            XCTAssertNil(model.recorderCoordinator)
            XCTAssertNil(model.systemRuntimeCoordinator)
            guard case .failed(let message) = model.launchState else {
                XCTFail("Writable alias case \(index) must fail before storage")
                continue
            }
            XCTAssertTrue(message.contains("VARTA_DATA_DIRECTORY"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("varta.sqlite").path))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: normalDirectory.path).sorted(), children)
            XCTAssertEqual(try Data(contentsOf: markerURL), marker)
            let after = try FileManager.default.attributesOfItem(atPath: markerURL.path)
            XCTAssertEqual(after[.size] as? NSNumber, before[.size] as? NSNumber)
            XCTAssertEqual(after[.modificationDate] as? Date, before[.modificationDate] as? Date)
            let directoryAfter = try FileManager.default.attributesOfItem(atPath: normalDirectory.path)
            XCTAssertEqual(directoryAfter[.modificationDate] as? Date, directoryBefore[.modificationDate] as? Date)
        }
    }

    @MainActor
    func testIsolatedBuildRejectsDefaultTargetsAndCaseAliases() async throws {
        guard ProcessInfo.processInfo.environment["VARTA_TESTING"] == "1" else {
            XCTFail("Test scheme must isolate app startup")
            return
        }
        let previous = ProcessInfo.processInfo.environment["VARTA_DATA_DIRECTORY"]
        defer {
            if let previous { setenv("VARTA_DATA_DIRECTORY", previous, 1) }
            else { unsetenv("VARTA_DATA_DIRECTORY") }
        }
        for index in 0..<8 {
            let fixture = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
                .appendingPathComponent("varta-default-target-\(index)-\(UUID().uuidString)", isDirectory: true)
            let support = fixture.appendingPathComponent("support", isDirectory: true)
            let normal = support.appendingPathComponent("Varta", isDirectory: true)
            var selected = fixture.appendingPathComponent("selected", isDirectory: true)
            if index == 5 { selected = support.appendingPathComponent("vARTA", isDirectory: true) }
            if index == 6 { selected = support.appendingPathComponent("vARTA/isolated-child", isDirectory: true) }
            for directory in [normal, selected] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            var target = selected.appendingPathComponent("varta.sqlite")
            switch index {
            case 1: target = selected.appendingPathComponent("varta.sqlite-wal")
            case 2: target = selected.appendingPathComponent("varta.sqlite-shm")
            case 3, 4: target = selected.appendingPathComponent("varta.files/Prompts/final-summary.txt")
            case 7: target = selected.appendingPathComponent("varta.files/Recordings/fixture/mic.wav")
            default: break
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("Synthetic physical default target".utf8).write(to: target)
            let normalDatabase = normal.appendingPathComponent("varta.sqlite")
            if index == 0 {
                try FileManager.default.createSymbolicLink(at: normalDatabase, withDestinationURL: target)
            } else if index < 5 || index == 7 {
                try Data("Synthetic default database marker".utf8).write(to: normalDatabase)
            }
            switch index {
            case 1, 2:
                try FileManager.default.createSymbolicLink(at: normal.appendingPathComponent(index == 1 ? "varta.sqlite-wal" : "varta.sqlite-shm"), withDestinationURL: target)
            case 3:
                try FileManager.default.createSymbolicLink(at: normal.appendingPathComponent("Prompts"), withDestinationURL: target.deletingLastPathComponent())
            case 4, 7:
                let relative = index == 4 ? "Prompts/final-summary.txt" : "Recordings/fixture/mic.wav"
                let alias = normal.appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: alias.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
            default: break
            }
            let before = try syntheticTreeSnapshot(fixture)
            setenv("VARTA_DATA_DIRECTORY", selected.path, 1)
            let model = AppModel()

            await model.bootstrap(fileManager: IsolationFileManager(support: support))

            XCTAssertNil(model.storageService)
            XCTAssertNil(model.settingsStore)
            XCTAssertNil(model.recorderCoordinator)
            XCTAssertNil(model.systemRuntimeCoordinator)
            guard case .failed(let message) = model.launchState else {
                XCTFail("Default target case \(index) must fail before storage")
                continue
            }
            XCTAssertTrue(message.contains("VARTA_DATA_DIRECTORY"))
            XCTAssertEqual(try syntheticTreeSnapshot(fixture), before)
        }
    }

    private func syntheticTreeSnapshot(_ root: URL) throws -> [String: String] {
        let entries = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var locations = [root]
        while let location = entries.nextObject() as? URL { locations.append(location) }
        return try Dictionary(uniqueKeysWithValues: locations.map { location in
            let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
            var value = "\(attributes[.type] ?? "")|\(attributes[.size] ?? "")|\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\(attributes[.referenceCount] ?? "")"
            if attributes[.type] as? FileAttributeType == .typeRegular {
                value += "|" + (try Data(contentsOf: location)).base64EncodedString()
            }
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                value += "|" + (try FileManager.default.destinationOfSymbolicLink(atPath: location.path))
            }
            return (location.path, value)
        })
    }

    private func defaultStorageMetadata() -> [[String: String]] {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return [] }
        let database = support.appendingPathComponent("Varta/varta.sqlite").path
        return ["", "-wal", "-shm"].map { suffix in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: database + suffix) else { return [:] }
            return ["size": String(describing: attributes[.size] ?? ""),
                    "modified": String((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)]
        }
    }
    #endif

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

#if VARTA_REQUIRE_ISOLATED_DATA
private final class IsolationFileManager: FileManager, @unchecked Sendable {
    let support: URL

    init(support: URL) {
        self.support = support
        super.init()
    }

    override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        if directory == .applicationSupportDirectory, domainMask == .userDomainMask { return [support] }
        return super.urls(for: directory, in: domainMask)
    }
}
#endif
