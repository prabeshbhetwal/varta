import XCTest
@testable import Varta

final class LocalImportLoopIntegrationTests: XCTestCase {
    func testImportTranscriptSummaryAndTranslationLoop() async throws {
        let storage = try StorageService(databaseURL: temporaryDatabaseURL())
        let memoryManager = MemoryManager()
        let transcription = TranscriptionService(storageService: storage, memoryManager: memoryManager)
        let summariser = SummariserService(storageService: storage, memoryManager: memoryManager)
        let importer = ImportPipelineService(
            storageService: storage,
            transcriptionService: transcription,
            summariserService: summariser
        )
        let translator = TranslationService(storageService: storage, memoryManager: memoryManager)

        let inputURL = try makeSampleMediaFile()
        let meetingID = try await importer.importMedia(from: inputURL, languageMode: .mixed)

        let segments = try await storage.transcriptSegments(meetingID: meetingID)
        XCTAssertFalse(segments.isEmpty)

        let summary = try await storage.summary(meetingID: meetingID)
        XCTAssertNotNil(summary)
        XCTAssertFalse(summary?.concise.isEmpty ?? true)

        let englishOutputs = try await storage.generatedOutputs(meetingID: meetingID, language: .english)
        XCTAssertFalse(englishOutputs.isEmpty)

        let nepaliOutputs = try await translator.translateOutputs(meetingID: meetingID, targetLanguage: .nepali)
        XCTAssertFalse(nepaliOutputs.isEmpty)

        let actionItemsNepali = nepaliOutputs.first(where: { $0.type == .actionItems })?.content ?? ""
        XCTAssertFalse(actionItemsNepali.isEmpty)

        let appSupport = await storage.appSupportDirectory()
        let promptDirectory = appSupport.appendingPathComponent("Prompts", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: promptDirectory.path))
    }

    private func temporaryDatabaseURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("varta-integration-\(UUID().uuidString).sqlite")
    }

    private func makeSampleMediaFile() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("sample-\(UUID().uuidString).m4a")

        let content = """
        We reviewed the integration milestone and decided to ship on Friday.
        Ram will prepare the release notes tomorrow.
        Nepali segment: हामी अर्को हप्ता पुन: बैठक गर्नेछौं।
        Open question: who owns monitoring setup?
        """

        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
