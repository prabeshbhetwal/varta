import XCTest
@testable import Varta

final class GeneratedContentTests: XCTestCase {
    func testMapReduceIncludesLateWindowsAndStoresValidatedOutputs() async throws {
        let storage = try await makeStorage()
        let meeting = try await storage.createMeeting(title: "Window fixture", languageMode: .mixed)
        try await storage.replaceTranscriptSegments(meetingID: meeting, segments: (0..<4).map {
            NewTranscriptSegment(startSeconds: Double($0 * 610), endSeconds: Double($0 * 610 + 10), text: "Window \($0) review next week", languageTag: "en", speakerLabel: nil)
        })
        let client = ContentFixture()
        let outputs = try await SummariserService(storageService: storage, memoryManager: MemoryManager(), client: client).summariseMeeting(meetingID: meeting)
        XCTAssertEqual(outputs.summary.concise, "Fixture recap")
        XCTAssertEqual(outputs.outputs.count, 8)
        let prompts = await client.prompts
        XCTAssertEqual(prompts.filter { $0.hasPrefix("window-summary") }.count, 4)
        XCTAssertEqual(prompts.filter { $0.hasPrefix("section-synthesis") }.count, 2)
        XCTAssertTrue(prompts.contains { $0.hasPrefix("window-summary") && $0.contains("Window 3") })
        XCTAssertTrue(prompts.contains { $0.hasPrefix("final-summary") && $0.contains("\"concise\"") })
        XCTAssertTrue(prompts.contains { $0.hasPrefix("calendar-candidates") && $0.contains("source_quote") })
        let saved = try await storage.generatedOutputs(meetingID: meeting)
        XCTAssertEqual(saved.count, 8)
        let unloaded = await client.unloaded
        XCTAssertTrue(unloaded)
    }

    func testMalformedFinalOutputPreservesPreviousSummary() async throws {
        let storage = try await makeStorage()
        let meeting = try await seedTranscript(storage)
        try await storage.upsertSummary(meetingID: meeting, summary: SummaryContent(concise: "Previous", detailed: "Previous", bullets: "Previous"), sourceTranscriptRevision: 1)
        let client = ContentFixture(invalidFinal: true)
        do {
            _ = try await SummariserService(storageService: storage, memoryManager: MemoryManager(), client: client).summariseMeeting(meetingID: meeting)
            XCTFail("Malformed JSON must fail before storage")
        } catch { }
        let saved = try await storage.summary(meetingID: meeting)
        XCTAssertEqual(saved?.concise, "Previous")
        let outputs = try await storage.generatedOutputs(meetingID: meeting)
        XCTAssertTrue(outputs.isEmpty)
        let unloaded = await client.unloaded
        XCTAssertTrue(unloaded)
    }

    func testCorrectionDuringGenerationRejectsStaleContent() async throws {
        let storage = try await makeStorage()
        let meeting = try await seedTranscript(storage)
        let segments = try await storage.transcriptSegments(meetingID: meeting)
        let id = try XCTUnwrap(segments.first?.id)
        let client = ContentFixture(onFinal: {
            try await storage.updateTranscriptCorrection(segmentID: id, correctedText: "Reviewed change")
        })
        do {
            _ = try await SummariserService(storageService: storage, memoryManager: MemoryManager(), client: client).summariseMeeting(meetingID: meeting)
            XCTFail("Revision mismatch must reject stale content")
        } catch StorageService.StorageError.transcriptChanged { }
        let outputs = try await storage.generatedOutputs(meetingID: meeting)
        XCTAssertTrue(outputs.isEmpty)
    }

    func testTranslationPreservesCanonicalEnglishAndCalendarEvidence() async throws {
        let storage = try await makeStorage()
        let meeting = try await seedTranscript(storage)
        _ = try await SummariserService(storageService: storage, memoryManager: MemoryManager(), client: ContentFixture()).summariseMeeting(meetingID: meeting)
        let before = try await storage.generatedOutputs(meetingID: meeting, language: .english)
        let translator = TranslationService(storageService: storage, memoryManager: MemoryManager(), client: NepaliFixture())
        let translated = try await translator.translateOutputs(meetingID: meeting, targetLanguage: .nepali)
        XCTAssertEqual(translated.count, 8)
        let after = try await translator.translateOutputs(meetingID: meeting, targetLanguage: .english)
        XCTAssertEqual(before, after)
        let calendar = try XCTUnwrap(translated.first { $0.type == .calendarCandidates })
        let candidates = try JSONDecoder().decode([CalendarCandidate].self, from: Data(calendar.content.utf8))
        XCTAssertEqual(candidates.first?.sourceQuote, "review next week")
        XCTAssertEqual(candidates.first?.dateHint, "next week")
        XCTAssertEqual(candidates.first?.title, "अनुवाद")
    }

    func testCancellationWhileWaitingForModelLeasePausesTranslationJob() async throws {
        let storage = try await makeStorage()
        let meeting = try await seedTranscript(storage)
        _ = try await SummariserService(storageService: storage, memoryManager: MemoryManager(), client: ContentFixture()).summariseMeeting(meetingID: meeting)
        let memory = MemoryManager()
        await memory.handleThermalStateChange(.critical)
        let client = NepaliFixture()
        let service = TranslationService(storageService: storage, memoryManager: memory, client: client)
        let operation = Task { try await service.translateOutputs(meetingID: meeting, targetLanguage: .nepali) }
        var queued: [JobRecord] = []
        for _ in 0..<250 {
            queued = try await storage.jobs(statuses: [.queued], type: .translation)
            if !queued.isEmpty { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(queued.count, 1)
        operation.cancel()
        do {
            _ = try await operation.value
            XCTFail("Queued operation must propagate cancellation")
        } catch is CancellationError { }
        let paused = try await storage.jobs(statuses: [.paused], type: .translation)
        XCTAssertEqual(paused.count, 1)
        let unloaded = await client.unloaded
        XCTAssertFalse(unloaded, "A client without the model lease must not clear another client's GPU cache")
    }

    func testGlossaryReplacementIsLiteral() {
        let term = GlossaryTerm(id: 1, term: "cost", replacement: "$5\\hour", languageCode: .mixed)
        XCTAssertEqual(SummariserService.applyGlossary(text: "cost estimate", languageHint: .english, terms: [term]), "$5\\hour estimate")
    }

    private func makeStorage() async throws -> StorageService {
        let storage = try StorageService(databaseURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("content-fixture-\(UUID().uuidString).sqlite"))
        let root = await storage.appSupportDirectory()
        for template in PromptTemplate.allCases {
            try template.rawValue.write(to: root.appendingPathComponent("Prompts").appendingPathComponent(template.filename), atomically: true, encoding: .utf8)
        }
        return storage
    }

    private func seedTranscript(_ storage: StorageService) async throws -> String {
        let id = try await storage.createMeeting(title: "Fixture", languageMode: .english)
        try await storage.replaceTranscriptSegments(meetingID: id, segments: [
            NewTranscriptSegment(startSeconds: 0, endSeconds: 10, text: "Please review next week", languageTag: "en", speakerLabel: nil)
        ])
        return id
    }
}

// Injected responses establish orchestration and persistence, never model accuracy.
private actor ContentFixture: LocalLanguageModelClient {
    var prompts: [String] = []
    var unloaded = false
    private let invalidFinal: Bool
    private let onFinal: (@Sendable () async throws -> Void)?
    init(invalidFinal: Bool = false, onFinal: (@Sendable () async throws -> Void)? = nil) {
        self.invalidFinal = invalidFinal
        self.onFinal = onFinal
    }
    func generate(prompt: String) async throws -> String {
        prompts.append(prompt)
        if prompt.hasPrefix("calendar-candidates") {
            return "[{\"title\":\"Review\",\"date_hint\":\"next week\",\"duration_minutes\":null,\"reason\":\"Explicit follow up\",\"source_quote\":\"review next week\"}]"
        }
        if prompt.hasPrefix("final-summary") {
            try await onFinal?()
            if invalidFinal { return "malformed" }
            return "{\"concise\":\"Fixture recap\",\"detailed\":\"Fixture detail\",\"bullets\":\"- Fixture point\"}"
        }
        return "Model fixture response \(prompts.count)"
    }
    func unload() async { unloaded = true }
}

private actor NepaliFixture: LocalLanguageModelClient {
    private(set) var unloaded = false
    func generate(prompt: String) async throws -> String { "अनुवाद" }
    func unload() async { unloaded = true }
}
