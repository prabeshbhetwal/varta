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
        try await storage.saveTranscriptionResult(meetingID: id, jobID: job, segments: [segment("Completed")], checkpointBlob: "{\"completed\":true}", expectedTranscriptRevision: revision, expectedSourceMediaIDs: [], processedDurationSeconds: 1)
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
            try await storage.saveTranscriptionResult(meetingID: id, jobID: job, segments: [segment("Overwrite")], checkpointBlob: "{}", expectedTranscriptRevision: revision, expectedSourceMediaIDs: [], processedDurationSeconds: 1)
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

    func testCalendarIdentityDistinguishesEventsAndDelimiterText() {
        let first = CalendarCandidate(title: "Review A", dateHint: "tomorrow", durationMinutes: 30, reason: "Explicit", sourceQuote: "Review A and B tomorrow")
        let second = CalendarCandidate(title: "Review B", dateHint: "tomorrow", durationMinutes: 30, reason: "Explicit", sourceQuote: first.sourceQuote)
        let longer = CalendarCandidate(title: first.title, dateHint: first.dateHint, durationMinutes: 60, reason: first.reason, sourceQuote: first.sourceQuote)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.id, longer.id)
        let pipeOne = CalendarCandidate(title: "Review", dateHint: "b|c", durationMinutes: nil, reason: "", sourceQuote: "a")
        let pipeTwo = CalendarCandidate(title: "Review", dateHint: "c", durationMinutes: nil, reason: "", sourceQuote: "a|b")
        XCTAssertNotEqual(pipeOne.id, pipeTwo.id)
    }

    func testSilentTranscriptionCompletesWithoutReplacingPriorContent() async throws {
        let storage = try StorageService(databaseURL: database())
        let meeting = try await storage.createMeeting(title: "Quiet audio", languageMode: .english)
        try await storage.replaceTranscriptSegments(meetingID: meeting, segments: [segment("Prior speech")])
        let revision = try await storage.transcriptRevision(meetingID: meeting)
        let summary = SummaryContent(concise: "Prior", detailed: "Prior", bullets: "Prior")
        let outputs = GeneratedOutputType.allCases.map { GeneratedOutput(type: $0, language: .english, content: "Prior output") }
        try await storage.saveMeetingOutputs(meetingID: meeting, outputs: MeetingOutputs(summary: summary, outputs: outputs), expectedTranscriptRevision: revision)
        let before = try await storage.generatedOutputs(meetingID: meeting)
        let job = try await storage.createJob(meetingID: meeting, type: .transcription, status: .running)
        try await storage.saveTranscriptionResult(meetingID: meeting, jobID: job, segments: [],
            checkpointBlob: "{\"completedWindows\":1,\"segments\":[]}", expectedTranscriptRevision: revision,
            expectedSourceMediaIDs: [], processedDurationSeconds: 30)
        let transcript = try await storage.transcriptSegments(meetingID: meeting)
        let afterRevision = try await storage.transcriptRevision(meetingID: meeting)
        let afterOutputs = try await storage.generatedOutputs(meetingID: meeting)
        let record = try await storage.job(id: job)
        let checkpoint = try await storage.processingState(jobID: job, stage: "transcription")
        XCTAssertEqual(transcript.map(\.text), ["Prior speech"])
        XCTAssertEqual(afterRevision, revision)
        XCTAssertEqual(afterOutputs, before)
        XCTAssertEqual(record?.status, .completed)
        XCTAssertTrue(record?.errorMessage?.hasPrefix("No speech detected.") == true)
        XCTAssertEqual(checkpoint?.checkpointOffsetSeconds, 30)
    }

    func testSourceChangeRejectsCompletionInsideTransaction() async throws {
        let storage = try StorageService(databaseURL: database())
        let meeting = try await storage.createMeeting(title: "Source change", languageMode: .english)
        try await storage.replaceTranscriptSegments(meetingID: meeting, segments: [segment("Prior")])
        let revision = try await storage.transcriptRevision(meetingID: meeting)
        let job = try await storage.createJob(meetingID: meeting, type: .transcription, status: .running)
        try await storage.registerImportedMedia(meetingID: meeting, relativePath: "Imports/\(meeting)/added.wav",
            originalFilename: "added.wav", format: "wav", durationSeconds: 1)
        do {
            try await storage.saveTranscriptionResult(meetingID: meeting, jobID: job, segments: [segment("Overwrite")],
                checkpointBlob: "{}", expectedTranscriptRevision: revision, expectedSourceMediaIDs: [], processedDurationSeconds: 1)
            XCTFail("A changed source snapshot must not commit")
        } catch StorageService.StorageError.sourceMediaChanged { }
        let transcript = try await storage.transcriptSegments(meetingID: meeting)
        let checkpoint = try await storage.processingState(jobID: job, stage: "transcription")
        let record = try await storage.job(id: job)
        XCTAssertEqual(transcript.map(\.text), ["Prior"])
        XCTAssertNil(checkpoint)
        XCTAssertEqual(record?.status, .running)
    }

    func testMissingOrInvalidLocalModelsFailValidation() throws {
        let manifest = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Models/model-manifest.json")
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let config = LocalModelConfiguration(rootDirectory: root, manifestURL: manifest)
        XCTAssertThrowsError(try config.whisperModelURL())
        XCTAssertThrowsError(try config.languageModelDirectory())
    }

    func testLegacyManifestResolvesWhisperButRequiresVADEntry() throws {
        let root = try assetFixtureDirectory()
        let manifest = try assetManifest(root: root, omitVAD: true)
        let whisper = root.appendingPathComponent("whisper-placeholder.bin")
        try Data([1]).write(to: whisper)
        let configuration = LocalModelConfiguration(rootDirectory: root, manifestURL: manifest, whisperOverride: whisper)
        XCTAssertEqual(try configuration.whisperModelURL(), whisper, "This checks file resolution, never real model compatibility")
        XCTAssertThrowsError(try configuration.vadModelURL())
    }

    func testVADRejectsMissingEmptyDirectoryAndIncorrectSizeAssets() throws {
        let root = try assetFixtureDirectory()
        let manifest = try assetManifest(root: root)
        let empty = root.appendingPathComponent("empty.bin")
        try Data().write(to: empty)
        let directory = root.appendingPathComponent("directory.bin")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let undersized = root.appendingPathComponent("undersized.bin")
        try Data([1]).write(to: undersized)
        let oversized = root.appendingPathComponent("oversized.bin")
        try Data(repeating: 0, count: LocalModelConfiguration.vadModelByteCount + 1).write(to: oversized)
        for url in [root.appendingPathComponent("missing.bin"), empty, directory, undersized, oversized] {
            let configuration = LocalModelConfiguration(rootDirectory: root, manifestURL: manifest, vadOverride: url)
            XCTAssertThrowsError(try configuration.vadModelURL(), url.lastPathComponent)
        }
    }

    func testVADRejectsCorrectSizeWithWrongContentChecksum() throws {
        let root = try assetFixtureDirectory()
        let manifest = try assetManifest(root: root)
        let file = root.appendingPathComponent("wrong-content.bin")
        try Data(repeating: 0, count: LocalModelConfiguration.vadModelByteCount).write(to: file)
        let configuration = LocalModelConfiguration(rootDirectory: root, manifestURL: manifest, vadOverride: file)
        XCTAssertThrowsError(try configuration.vadModelURL()) { error in
            guard case LocalModelError.invalidAsset(let message) = error else { return XCTFail("Expected checksum validation failure") }
            XCTAssertTrue(message.contains("checksum"))
        }
    }

    func testVADManifestPinAndRelativePathCannotBeChanged() throws {
        let mutations = [
            ["engine": "other-engine"], ["backend": "metal"], ["model": "other-model"],
            ["sha256": String(repeating: "0", count: 64)], ["path": "../outside.bin"]
        ]
        for mutation in mutations {
            let root = try assetFixtureDirectory()
            let manifest = try assetManifest(root: root, vadChanges: mutation)
            let configuration = LocalModelConfiguration(rootDirectory: root, manifestURL: manifest)
            XCTAssertThrowsError(try configuration.vadModelURL())
        }
    }

    private func assetFixtureDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("varta-vad-asset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func assetManifest(root: URL, omitVAD: Bool = false, vadChanges: [String: String] = [:]) throws -> URL {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Models/model-manifest.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any])
        if omitVAD { object.removeValue(forKey: "vad") }
        else {
            var vad = try XCTUnwrap(object["vad"] as? [String: Any])
            for (key, value) in vadChanges { vad[key] = value }
            object["vad"] = vad
        }
        let url = root.appendingPathComponent("model-manifest.json")
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
        return url
    }

    private func database() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("workflow-fixture-\(UUID().uuidString).sqlite")
    }
    private func segment(_ text: String) -> NewTranscriptSegment {
        NewTranscriptSegment(startSeconds: 0, endSeconds: 1, text: text, languageTag: "en", speakerLabel: nil)
    }
}
