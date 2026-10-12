import Foundation
import CryptoKit

actor SummariserService {
    private struct Checkpoint: Codable, Sendable {
        let transcriptRevision: Int
        let inputFingerprint: String
        var summaries: [String] = []
        var extracted: [GeneratedOutputType: [String]] = [:]
        var candidates: [CalendarCandidate] = []
        var sections: [String] = []
    }

    private let storageService: StorageService
    private let memoryManager: MemoryManager
    private let client: any LocalLanguageModelClient

    init(storageService: StorageService, memoryManager: MemoryManager, client: any LocalLanguageModelClient = MLXLanguageModelClient()) {
        self.storageService = storageService
        self.memoryManager = memoryManager
        self.client = client
    }

    func summariseMeeting(meetingID: String) async throws -> MeetingOutputs {
        let revision = try await storageService.transcriptRevision(meetingID: meetingID)
        let segments = try await storageService.transcriptSegments(meetingID: meetingID)
        guard !segments.isEmpty else { throw LocalModelError.invalidOutput("Review a transcript before generating meeting content.") }
        let glossary = try await storageService.glossaryTerms()
        let root = await storageService.appSupportDirectory()
        let meeting = try await storageService.listMeetings().first { $0.id == meetingID }
        let date = meeting.map { ISO8601DateFormatter().string(from: $0.createdAt) } ?? ""
        let windows = try Self.windows(segments: segments, glossary: glossary)
        let fingerprint = try Self.fingerprint(windows: windows, meetingDate: date, root: root)
        let recovered = try await matchingCheckpoint(meetingID: meetingID, revision: revision, fingerprint: fingerprint, windows: windows)
        let checkpoint = recovered?.checkpoint ?? Checkpoint(transcriptRevision: revision, inputFingerprint: fingerprint)
        let jobID: String
        if let recovered {
            jobID = recovered.jobID
            try await storageService.updateJobStatus(id: jobID, status: .queued, errorMessage: nil)
        } else {
            jobID = try await storageService.createJob(meetingID: meetingID, type: .summarisation, status: .queued)
        }

        do {
            try await persist(checkpoint, jobID: jobID, windowCount: windows.count, status: .queued)
            return try await memoryManager.runExclusive(family: .summariser) {
                do {
                    try await self.storageService.updateJobStatus(id: jobID, status: .running)
                    let result = try await self.generate(windows: windows, meetingDate: date, root: root, jobID: jobID, checkpoint: checkpoint)
                    try Task.checkCancellation()
                    let latestGlossary = try await self.storageService.glossaryTerms()
                    let latestWindows = try Self.windows(segments: segments, glossary: latestGlossary)
                    guard try Self.fingerprint(windows: latestWindows, meetingDate: date, root: root) == fingerprint else {
                        throw LocalModelError.invalidOutput("Prompts or glossary changed during generation. Generate again with current settings.")
                    }
                    try await self.storageService.saveMeetingOutputs(meetingID: meetingID, outputs: result, expectedTranscriptRevision: revision, jobID: jobID)
                    await self.client.unload()
                    return result
                } catch {
                    await self.client.unload()
                    throw error
                }
            }
        } catch {
            try await storageService.updateJobStatus(id: jobID, status: error is CancellationError ? .paused : .failed, errorMessage: error.localizedDescription)
            throw error
        }
    }

    private func generate(windows: [String], meetingDate: String, root: URL, jobID: String, checkpoint initial: Checkpoint) async throws -> MeetingOutputs {
        var checkpoint = initial
        let types: [(GeneratedOutputType, PromptTemplate)] = [
            (.actionItems, .actionItems), (.decisions, .decisions), (.unresolvedQuestions, .unresolvedQuestions)
        ]
        for window in windows.dropFirst(checkpoint.summaries.count) {
            try Task.checkCancellation()
            let summary = try await run(.windowSummary, context: ["transcript": window], root: root)
            var extraction: [GeneratedOutputType: String] = [:]
            for (type, prompt) in types {
                extraction[type] = try await run(prompt, context: ["transcript": window], root: root)
            }
            let raw = try await run(.calendarCandidates, context: ["transcript": window, "meeting_date": meetingDate], root: root)
            let proposed = try JSONDecoder().decode([CalendarCandidate].self, from: Self.jsonData(raw))
            for candidate in proposed {
                try candidate.validate()
                guard window.range(of: candidate.sourceQuote, options: [.caseInsensitive]) != nil else {
                    throw LocalModelError.invalidOutput("Calendar candidate lacks a quote from its source transcript.")
                }
            }
            // Commit a whole window only after every response and evidence quote validates.
            checkpoint.summaries.append(summary)
            for (type, _) in types { checkpoint.extracted[type, default: []].append(extraction[type] ?? "") }
            for candidate in proposed {
                if !checkpoint.candidates.contains(candidate) { checkpoint.candidates.append(candidate) }
            }
            try await persist(checkpoint, jobID: jobID, windowCount: windows.count)
        }
        let sectionCount = (checkpoint.summaries.count + 2) / 3
        for sectionIndex in checkpoint.sections.count..<sectionCount {
            let index = sectionIndex * 3
            let text = checkpoint.summaries[index..<min(index + 3, checkpoint.summaries.count)].joined(separator: "\n\n")
            checkpoint.sections.append(try await run(.sectionSynthesis, context: ["window_summaries": text], root: root))
            try await persist(checkpoint, jobID: jobID, windowCount: windows.count)
        }
        let raw = try await run(.finalSummary, context: ["section_summaries": try await boundedSynthesis(checkpoint.sections, root: root)], root: root)
        let summary = try JSONDecoder().decode(SummaryContent.self, from: Self.jsonData(raw))
        guard [summary.concise, summary.detailed, summary.bullets].allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw LocalModelError.invalidOutput("Final summary requires concise, detailed and bullet text.")
        }
        var outputs = types.map { type, _ in
            GeneratedOutput(type: type, language: .english, content: (checkpoint.extracted[type] ?? []).joined(separator: "\n\n"))
        }
        let emailContext = try await boundedSynthesis(outputs.map(\.content), root: root)
        outputs.append(GeneratedOutput(type: .followUpEmail, language: .english, content: try await run(.followUpEmail, context: ["summary": summary.concise, "extracted_outputs": emailContext], root: root)))
        outputs.append(GeneratedOutput(type: .calendarCandidates, language: .english, content: String(decoding: try JSONEncoder().encode(checkpoint.candidates), as: UTF8.self)))
        outputs += [
            GeneratedOutput(type: .summaryConcise, language: .english, content: summary.concise),
            GeneratedOutput(type: .summaryDetailed, language: .english, content: summary.detailed),
            GeneratedOutput(type: .summaryBullets, language: .english, content: summary.bullets)
        ]
        return MeetingOutputs(summary: summary, outputs: outputs)
    }

    private func matchingCheckpoint(meetingID: String, revision: Int, fingerprint: String, windows: [String]) async throws
        -> (jobID: String, checkpoint: Checkpoint)? {
        let jobs = try await storageService.jobs(statuses: [.paused, .failed], type: .summarisation)
        for job in jobs where job.meetingID == meetingID {
            guard let state = try await storageService.processingState(jobID: job.id, stage: "summary"),
                  let blob = state.checkpointBlob, blob.utf8.count <= 16_000_000,
                  let checkpoint = try? JSONDecoder().decode(Checkpoint.self, from: Data(blob.utf8)),
                  checkpoint.transcriptRevision == revision, checkpoint.inputFingerprint == fingerprint,
                  checkpoint.summaries.count <= windows.count,
                  checkpoint.sections.count <= (windows.count + 2) / 3,
                  checkpoint.sections.isEmpty || checkpoint.summaries.count == windows.count,
                  checkpoint.candidates.count <= 1_000,
                  Set(checkpoint.extracted.keys).isSubset(of: [.actionItems, .decisions, .unresolvedQuestions]),
                  [GeneratedOutputType.actionItems, .decisions, .unresolvedQuestions].allSatisfy({
                      (checkpoint.extracted[$0] ?? []).count == checkpoint.summaries.count
                  }),
                  (checkpoint.summaries + checkpoint.sections + checkpoint.extracted.values.flatMap { $0 })
                    .allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { continue }
            let evidence = windows.prefix(checkpoint.summaries.count)
            guard checkpoint.candidates.allSatisfy({ candidate in
                (try? candidate.validate()) != nil && evidence.contains(where: {
                    $0.range(of: candidate.sourceQuote, options: .caseInsensitive) != nil
                })
            }) else { continue }
            return (job.id, checkpoint)
        }
        return nil
    }

    private func persist(_ checkpoint: Checkpoint, jobID: String, windowCount: Int, status: JobStatus = .running) async throws {
        let data = try JSONEncoder().encode(checkpoint)
        guard data.count <= 16_000_000 else { throw LocalModelError.invalidOutput("Summary checkpoint exceeds the bounded storage limit.") }
        try await storageService.upsertProcessingState(jobID: jobID, stage: "summary",
            checkpointBlob: String(decoding: data, as: UTF8.self), checkpointOffsetSeconds: nil)
        let sectionCount = (windowCount + 2) / 3
        let progress = Double(checkpoint.summaries.count) / Double(max(windowCount, 1)) * 0.8
            + Double(checkpoint.sections.count) / Double(max(sectionCount, 1)) * 0.1
        try await storageService.updateJobStatus(id: jobID, status: status, progress: progress, errorMessage: nil)
    }

    private nonisolated static func fingerprint(windows: [String], meetingDate: String, root: URL) throws -> String {
        let prompts = try PromptTemplate.allCases.map {
            try PromptTemplateService.render($0, context: [:], appSupportDirectoryURL: root)
        }
        let data = try JSONEncoder().encode([meetingDate] + windows + prompts)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func boundedSynthesis(_ values: [String], root: URL) async throws -> String {
        var current = values
        for _ in 0..<5 {
            let combined = current.joined(separator: "\n\n")
            if combined.utf8.count <= 60_000 { return combined }
            var reduced: [String] = []
            for index in stride(from: 0, to: current.count, by: 3) {
                reduced.append(try await run(.sectionSynthesis, context: [
                    "section_summaries": current[index..<min(index + 3, current.count)].joined(separator: "\n\n")
                ], root: root))
            }
            current = reduced
        }
        throw LocalModelError.invalidOutput("Meeting content exceeds the bounded synthesis context.")
    }

    private func run(_ template: PromptTemplate, context: [String: String], root: URL) async throws -> String {
        try Task.checkCancellation()
        let response = try await client.generate(prompt: PromptTemplateService.render(template, context: context, appSupportDirectoryURL: root))
        let text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LocalModelError.invalidOutput("Empty response for \(template.rawValue).") }
        return text
    }

    private nonisolated static func windows(segments: [TranscriptSegment], glossary: [GlossaryTerm]) throws -> [String] {
        guard segments.allSatisfy({ $0.startSeconds.isFinite && $0.endSeconds.isFinite && $0.startSeconds >= 0 && $0.endSeconds >= $0.startSeconds }) else {
            throw StorageService.StorageError.invalidTranscriptTiming
        }
        let last = segments.map(\.endSeconds).max() ?? 0
        guard last <= 14_400 else { throw LocalModelError.invalidOutput("Meeting exceeds the four-hour processing limit.") }
        let count = max(1, Int(ceil(last / 600)))
        return (0..<count).compactMap { index in
            let start = max(0, Double(index * 600) - 30)
            let end = Double((index + 1) * 600)
            let text = segments.filter { $0.endSeconds >= start && $0.startSeconds < end }.map { segment in
                let corrected = applyGlossary(text: segment.effectiveText, languageHint: LanguageMode(rawValue: segment.languageTag ?? ""), terms: glossary)
                return "[\(segment.startSeconds)-\(segment.endSeconds)] \(corrected)"
            }.joined(separator: "\n")
            return text.isEmpty ? nil : text
        }
    }

    nonisolated static func jsonData(_ text: String) throws -> Data {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fence = "\u{0060}\u{0060}\u{0060}"
        if value.hasPrefix(fence), let newline = value.firstIndex(of: "\n"), value.hasSuffix(fence) {
            value = String(value[value.index(after: newline)..<value.index(value.endIndex, offsetBy: -3)])
        }
        return Data(value.utf8)
    }

    nonisolated static func applyGlossary(text: String, languageHint: LanguageMode?, terms: [GlossaryTerm]) -> String {
        var rewritten = text
        for term in terms {
            if term.languageCode != .mixed, let languageHint, term.languageCode != languageHint { continue }
            let escaped = NSRegularExpression.escapedPattern(for: term.term)
            guard let regex = try? NSRegularExpression(pattern: "\\b\(escaped)\\b", options: [.caseInsensitive]) else { continue }
            let range = NSRange(rewritten.startIndex..<rewritten.endIndex, in: rewritten)
            rewritten = regex.stringByReplacingMatches(in: rewritten, options: [], range: range, withTemplate: NSRegularExpression.escapedTemplate(for: term.replacement))
        }
        return rewritten
    }
}
