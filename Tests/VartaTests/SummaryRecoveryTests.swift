import XCTest
@testable import Varta

final class SummaryRecoveryTests: XCTestCase {
    func testResumeSkipsCompletedWindowAndPreservesPreviousOutputsUntilSuccess() async throws {
        let (storage, meeting) = try await fixture(windowCount: 2)
        try await savePrevious(storage, meeting: meeting)
        let first = RecoveryModelFixture(failWindow: 2)
        do {
            _ = try await SummariserService(storageService: storage, memoryManager: MemoryManager(), client: first)
                .summariseMeeting(meetingID: meeting)
            XCTFail("Second window should fail")
        } catch RecoveryModelFixture.Failure.interrupted { }
        let previous = try await storage.summary(meetingID: meeting)
        XCTAssertEqual(previous?.concise, "Previous content")
        let failedJobs = try await storage.jobs(statuses: [.failed], type: .summarisation)
        let job = try XCTUnwrap(failedJobs.first)
        let checkpoint = try await storage.processingState(jobID: job.id, stage: "summary")
        XCTAssertNotNil(checkpoint?.checkpointBlob)
        let resumed = RecoveryModelFixture()
        _ = try await SummariserService(storageService: storage, memoryManager: MemoryManager(), client: resumed)
            .summariseMeeting(meetingID: meeting)
        let windowCalls = await resumed.windowCalls
        XCTAssertEqual(windowCalls, 1)
        let completed = try await storage.job(id: job.id)
        XCTAssertEqual(completed?.status, .completed)
        let saved = try await storage.summary(meetingID: meeting)
        XCTAssertEqual(saved?.concise, "Resumed summary")
    }

    func testResumeSkipsCompletedSection() async throws {
        let (storage, meeting) = try await fixture(windowCount: 4)
        do {
            _ = try await SummariserService(storageService: storage, memoryManager: MemoryManager(),
                client: RecoveryModelFixture(failSection: 2)).summariseMeeting(meetingID: meeting)
            XCTFail("Second section should fail")
        } catch RecoveryModelFixture.Failure.interrupted { }
        let resumed = RecoveryModelFixture()
        _ = try await SummariserService(storageService: storage, memoryManager: MemoryManager(), client: resumed)
            .summariseMeeting(meetingID: meeting)
        let windowCalls = await resumed.windowCalls
        let sectionCalls = await resumed.sectionCalls
        XCTAssertEqual(windowCalls, 0)
        XCTAssertEqual(sectionCalls, 1)
    }

    func testChangedTranscriptRejectsCheckpointAndStartsNewJob() async throws {
        let (storage, meeting) = try await fixture(windowCount: 2)
        do {
            _ = try await SummariserService(storageService: storage, memoryManager: MemoryManager(),
                client: RecoveryModelFixture(failWindow: 2)).summariseMeeting(meetingID: meeting)
            XCTFail("Second window should fail")
        } catch RecoveryModelFixture.Failure.interrupted { }
        let segments = try await storage.transcriptSegments(meetingID: meeting)
        let segment = try XCTUnwrap(segments.first)
        try await storage.updateTranscriptCorrection(segmentID: segment.id, correctedText: "Changed evidence")
        let newClient = RecoveryModelFixture()
        _ = try await SummariserService(storageService: storage, memoryManager: MemoryManager(), client: newClient)
            .summariseMeeting(meetingID: meeting)
        let calls = await newClient.windowCalls
        XCTAssertEqual(calls, 2)
        let jobs = try await storage.jobs(type: .summarisation)
        XCTAssertEqual(jobs.count, 2)
        XCTAssertEqual(jobs.filter { $0.status == .failed }.count, 1)
        XCTAssertEqual(jobs.filter { $0.status == .completed }.count, 1)
    }

    func testChangedPromptRejectsCheckpointWithoutReplacingPromptFile() async throws {
        let (storage, meeting) = try await fixture(windowCount: 2)
        do {
            _ = try await SummariserService(storageService: storage, memoryManager: MemoryManager(),
                client: RecoveryModelFixture(failWindow: 2)).summariseMeeting(meetingID: meeting)
            XCTFail("Second window should fail")
        } catch RecoveryModelFixture.Failure.interrupted { }
        let root = await storage.appSupportDirectory()
        let prompt = root.appendingPathComponent("Prompts/window-summary.txt")
        try "window-summary updated fixture".write(to: prompt, atomically: true, encoding: .utf8)
        let newClient = RecoveryModelFixture()
        _ = try await SummariserService(storageService: storage, memoryManager: MemoryManager(), client: newClient)
            .summariseMeeting(meetingID: meeting)
        let calls = await newClient.windowCalls
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(try String(contentsOf: prompt), "window-summary updated fixture")
    }

    func testQueuedCancellationPausesJobWithoutUnloadingOtherLease() async throws {
        let (storage, meeting) = try await fixture(windowCount: 1)
        let manager = MemoryManager()
        let gate = SummaryLeaseGate()
        let holder = Task {
            try await manager.runExclusive(family: .whisper) { await gate.hold() }
        }
        do { try await waitUntil { await gate.entered } }
        catch {
            await gate.release()
            holder.cancel()
            throw error
        }
        let client = RecoveryModelFixture()
        let worker = Task {
            try await SummariserService(storageService: storage, memoryManager: manager, client: client)
                .summariseMeeting(meetingID: meeting)
        }
        do {
            try await waitUntil {
                let jobs = try await storage.jobs(statuses: [.queued], type: .summarisation)
                return !jobs.isEmpty
            }
            worker.cancel()
            do { _ = try await worker.value; XCTFail("Queued generation should cancel") }
            catch is CancellationError { }
            let jobs = try await storage.jobs(type: .summarisation)
            XCTAssertEqual(jobs.first?.status, .paused)
            let unloaded = await client.unloaded
            let prompts = await client.windowCalls
            XCTAssertFalse(unloaded)
            XCTAssertEqual(prompts, 0)
            await gate.release()
            _ = try await holder.value
        } catch {
            worker.cancel()
            await gate.release()
            holder.cancel()
            throw error
        }
    }

    private func fixture(windowCount: Int) async throws -> (StorageService, String) {
        let storage = try StorageService(databaseURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("summary-recovery-\(UUID().uuidString).sqlite"))
        let root = await storage.appSupportDirectory()
        for template in PromptTemplate.allCases {
            try template.rawValue.write(to: root.appendingPathComponent("Prompts").appendingPathComponent(template.filename),
                atomically: true, encoding: .utf8)
        }
        let meeting = try await storage.createMeeting(title: "Summary recovery", languageMode: .english)
        try await storage.replaceTranscriptSegments(meetingID: meeting, segments: (0..<windowCount).map {
            NewTranscriptSegment(startSeconds: Double($0 * 610), endSeconds: Double($0 * 610 + 10),
                text: "Evidence window \($0)", languageTag: "en", speakerLabel: nil)
        })
        return (storage, meeting)
    }

    private func savePrevious(_ storage: StorageService, meeting: String) async throws {
        let revision = try await storage.transcriptRevision(meetingID: meeting)
        let summary = SummaryContent(concise: "Previous content", detailed: "Previous content", bullets: "Previous content")
        let outputs = GeneratedOutputType.allCases.map {
            GeneratedOutput(type: $0, language: .english, content: $0 == .calendarCandidates ? "[]" : "Previous content")
        }
        try await storage.saveMeetingOutputs(meetingID: meeting, outputs: MeetingOutputs(summary: summary, outputs: outputs),
            expectedTranscriptRevision: revision)
    }

    private func waitUntil(_ predicate: () async throws -> Bool) async throws {
        for _ in 0..<200 {
            if try await predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "Varta.SummaryRecoveryTests", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for a bounded fixture transition"])
    }
}

private actor RecoveryModelFixture: LocalLanguageModelClient {
    enum Failure: Error { case interrupted }
    let failWindow: Int?
    let failSection: Int?
    private(set) var windowCalls = 0
    private(set) var sectionCalls = 0
    private(set) var unloaded = false

    init(failWindow: Int? = nil, failSection: Int? = nil) {
        self.failWindow = failWindow
        self.failSection = failSection
    }

    func generate(prompt: String) async throws -> String {
        if prompt.hasPrefix("window-summary") {
            windowCalls += 1
            if windowCalls == failWindow { throw Failure.interrupted }
        }
        if prompt.hasPrefix("section-synthesis") {
            sectionCalls += 1
            if sectionCalls == failSection { throw Failure.interrupted }
        }
        if prompt.hasPrefix("calendar-candidates") { return "[]" }
        if prompt.hasPrefix("final-summary") {
            return "{\"concise\":\"Resumed summary\",\"detailed\":\"Resumed detail\",\"bullets\":\"- Resumed point\"}"
        }
        return "Validated fixture response"
    }

    func unload() async { unloaded = true }
}

private actor SummaryLeaseGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func hold() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
