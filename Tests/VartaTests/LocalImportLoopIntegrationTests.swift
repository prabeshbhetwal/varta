import AVFoundation
import XCTest
@testable import Varta

final class LocalImportLoopIntegrationTests: XCTestCase {
    func testImportThenPersistInjectedFixtureTranscript() async throws {
        let storage = try StorageService(databaseURL: temporaryDatabaseURL())
        let memoryManager = MemoryManager()
        let transcription = TranscriptionService(
            storageService: storage, memoryManager: memoryManager, whisperClient: FixtureWhisperClient()
        )
        let importer = ImportPipelineService(storageService: storage)

        let inputURL = try makeSampleMediaFile()
        let meetingID = try await importer.importMedia(from: inputURL, languageMode: .mixed)

        let importedMedia = try await storage.importedMedia(for: meetingID)
        XCTAssertFalse(importedMedia.isEmpty)

        let importedURL = await storage.resolvedImportedMediaURL(relativePath: importedMedia[0].relativePath)
        let detail = await MeetingDetailViewModel(meetingID: meetingID, storageService: storage, memoryManager: memoryManager)
        await detail.refresh()
        let audioFolder = await detail.recordingsFolderURL
        XCTAssertEqual(audioFolder, importedURL.deletingLastPathComponent())
        _ = try await transcription.transcribeMeeting(meetingID: meetingID, mediaURL: importedURL, languageMode: .mixed)

        let segments = try await storage.transcriptSegments(meetingID: meetingID)
        XCTAssertFalse(segments.isEmpty)

        let appSupport = await storage.appSupportDirectory()
        let promptDirectory = appSupport.appendingPathComponent("Prompts", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: promptDirectory.path))
        XCTAssertNotEqual(appSupport, try StorageService.applicationSupportDirectory(fileManager: .default))
    }

    func testDefaultTranscriptionFailsWithoutReplacingExistingTranscript() async throws {
        let storage = try StorageService(databaseURL: temporaryDatabaseURL())
        let meetingID = try await storage.createMeeting(title: "Preserve transcript", languageMode: .english)
        try await storage.replaceTranscriptSegments(meetingID: meetingID, segments: [
            NewTranscriptSegment(startSeconds: 0, endSeconds: 1, text: "Existing transcript", languageTag: "en", speakerLabel: nil)
        ])
        let transcription = TranscriptionService(storageService: storage, memoryManager: MemoryManager())
        do {
            _ = try await transcription.transcribeMeeting(meetingID: meetingID, mediaURL: makeSampleMediaFile(), languageMode: .english)
            XCTFail("An unintegrated engine must fail rather than invent a transcript")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("whisper.cpp engine and model"))
        }
        let segments = try await storage.transcriptSegments(meetingID: meetingID)
        XCTAssertEqual(segments.map(\.text), ["Existing transcript"])
    }

    private func temporaryDatabaseURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("varta-integration-\(UUID().uuidString).sqlite")
    }

    private func makeSampleMediaFile() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("sample-\(UUID().uuidString).wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        let samples = try XCTUnwrap(buffer.floatChannelData)
        samples[0].initialize(repeating: 0, count: 16_000)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}

// Synthetic transcript fixture: verifies persistence, never model accuracy.
private struct FixtureWhisperClient: WhisperCppClient {
    func transcribe(mediaURL: URL, languageMode: LanguageMode) async throws -> [WhisperTranscribedSegment] {
        [WhisperTranscribedSegment(startSeconds: 0, endSeconds: 1, text: "We agreed to review the release next week.")]
    }
}
