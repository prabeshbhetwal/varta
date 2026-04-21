import Foundation

actor SummariserService {
    private let storageService: StorageService
    private let memoryManager: MemoryManager

    init(storageService: StorageService, memoryManager: MemoryManager) {
        self.storageService = storageService
        self.memoryManager = memoryManager
    }

    func summariseMeeting(meetingID: String) async throws -> MeetingOutputs {
        let segments = try await storageService.transcriptSegments(meetingID: meetingID)
        let glossary = try await storageService.glossaryTerms()

        let preparedSegments = segments.map { segment -> TranscriptSegment in
            let languageHint = LanguageMode(rawValue: segment.languageTag ?? "")
            let rewritten = Self.applyGlossary(
                text: segment.effectiveText,
                languageHint: languageHint,
                terms: glossary
            )

            return TranscriptSegment(
                id: segment.id,
                meetingID: segment.meetingID,
                startSeconds: segment.startSeconds,
                endSeconds: segment.endSeconds,
                text: segment.text,
                correctedText: rewritten,
                languageTag: segment.languageTag,
                speakerLabel: segment.speakerLabel,
                isLocked: segment.isLocked
            )
        }

        return try await memoryManager.runExclusive(family: .summariser) {
            let appSupportURL = await self.storageService.appSupportDirectory()
            let windowPrompt = (try? PromptTemplateService.loadPrompt(for: .windowSummary, appSupportDirectoryURL: appSupportURL)) ?? ""
            let sectionPrompt = (try? PromptTemplateService.loadPrompt(for: .sectionSynthesis, appSupportDirectoryURL: appSupportURL)) ?? ""
            let finalPrompt = (try? PromptTemplateService.loadPrompt(for: .finalSummary, appSupportDirectoryURL: appSupportURL)) ?? ""

            let windowSummaries = Self.mapWindowSummaries(segments: preparedSegments, promptPrefix: windowPrompt)
            let sectionSummaries = Self.reduceSections(windowSummaries: windowSummaries, promptPrefix: sectionPrompt)
            let summary = Self.composeFinalSummary(sectionSummaries: sectionSummaries, promptPrefix: finalPrompt)

            try await self.storageService.upsertSummary(
                meetingID: meetingID,
                summary: summary,
                sourceTranscriptRevision: segments.count
            )

            let outputs = Self.extractGeneratedOutputs(from: preparedSegments, summary: summary)
            for output in outputs {
                try await self.storageService.upsertGeneratedOutput(
                    meetingID: meetingID,
                    type: output.type,
                    language: output.language,
                    content: output.content
                )
            }

            return MeetingOutputs(summary: summary, outputs: outputs)
        }
    }

    nonisolated static func applyGlossary(
        text: String,
        languageHint: LanguageMode?,
        terms: [GlossaryTerm]
    ) -> String {
        var rewritten = text
        for term in terms {
            if term.languageCode != .mixed, let languageHint, term.languageCode != languageHint {
                continue
            }

            let escaped = NSRegularExpression.escapedPattern(for: term.term)
            guard let regex = try? NSRegularExpression(pattern: "\\b\(escaped)\\b", options: [.caseInsensitive]) else {
                continue
            }

            let range = NSRange(rewritten.startIndex..<rewritten.endIndex, in: rewritten)
            rewritten = regex.stringByReplacingMatches(in: rewritten, options: [], range: range, withTemplate: term.replacement)
        }

        return rewritten
    }

    private nonisolated static func mapWindowSummaries(
        segments: [TranscriptSegment],
        promptPrefix: String
    ) -> [Int: String] {
        var windows: [Int: [String]] = [:]
        for segment in segments {
            let index = Int(segment.startSeconds / 600)
            windows[index, default: []].append(segment.correctedText ?? segment.effectiveText)
        }

        var summaries: [Int: String] = [:]
        for (index, lines) in windows {
            let merged = lines.joined(separator: " ")
            let condensed = condensedText(from: merged, maxSentences: 3)
            let prefix = promptPrefix.isEmpty ? "" : "\(promptPrefix)\n\n"
            summaries[index] = "\(prefix)Window \(index + 1): \(condensed)"
        }

        return summaries
    }

    private nonisolated static func reduceSections(
        windowSummaries: [Int: String],
        promptPrefix: String
    ) -> [Int: String] {
        var sections: [Int: [String]] = [:]
        for (windowIndex, summary) in windowSummaries {
            let sectionIndex = windowIndex / 3
            sections[sectionIndex, default: []].append(summary)
        }

        var reduced: [Int: String] = [:]
        for (sectionIndex, summaries) in sections {
            let merged = summaries.joined(separator: " ")
            let condensed = condensedText(from: merged, maxSentences: 4)
            let prefix = promptPrefix.isEmpty ? "" : "\(promptPrefix)\n\n"
            reduced[sectionIndex] = "\(prefix)Section \(sectionIndex + 1): \(condensed)"
        }

        return reduced
    }

    private nonisolated static func composeFinalSummary(
        sectionSummaries: [Int: String],
        promptPrefix: String
    ) -> SummaryContent {
        let ordered = sectionSummaries.keys.sorted().compactMap { sectionSummaries[$0] }
        let combined = ordered.joined(separator: " ")

        let concise = condensedText(from: combined, maxSentences: 2)
        let detailed = condensedText(from: combined, maxSentences: 8)

        let bulletsList = extractSentences(from: combined, limit: 6)
            .map { "- \($0)" }
            .joined(separator: "\n")

        let conciseWithPrompt = promptPrefix.isEmpty ? concise : "\(promptPrefix)\n\n\(concise)"

        return SummaryContent(
            concise: conciseWithPrompt,
            detailed: detailed,
            bullets: bulletsList
        )
    }

    private nonisolated static func extractGeneratedOutputs(
        from segments: [TranscriptSegment],
        summary: SummaryContent
    ) -> [GeneratedOutput] {
        let lines = segments.map(\.effectiveText)

        let actionItems = lines
            .filter { line in
                let lower = line.lowercased()
                return lower.contains("action") || lower.contains("todo") || lower.contains("will") || lower.contains("need to")
            }
            .prefix(8)
            .enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")

        let decisions = lines
            .filter { line in
                let lower = line.lowercased()
                return lower.contains("decide") || lower.contains("agreed") || lower.contains("approved") || lower.contains("selected")
            }
            .prefix(8)
            .enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")

        let unresolvedQuestions = lines
            .filter { line in
                line.contains("?") || line.lowercased().contains("question") || line.lowercased().contains("clarify")
            }
            .prefix(8)
            .enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")

        let calendarCandidates = lines
            .filter { line in
                let lower = line.lowercased()
                return lower.contains("next week") || lower.contains("tomorrow") || lower.contains("follow up") || lower.contains("meet")
            }
            .prefix(5)
            .enumerated()
            .map { "- Candidate \($0.offset + 1): \($0.element)" }
            .joined(separator: "\n")

        let followUpEmail = """
        Subject: Follow-up from Meeting

        Hi team,

        Here is a concise recap:
        \(summary.concise)

        Action items:
        \(actionItems.isEmpty ? "1. No explicit action items detected." : actionItems)

        Decisions:
        \(decisions.isEmpty ? "1. No explicit decisions detected." : decisions)

        Best,
        Varta
        """

        return [
            GeneratedOutput(type: .actionItems, language: .english, content: actionItems),
            GeneratedOutput(type: .decisions, language: .english, content: decisions),
            GeneratedOutput(type: .unresolvedQuestions, language: .english, content: unresolvedQuestions),
            GeneratedOutput(type: .followUpEmail, language: .english, content: followUpEmail),
            GeneratedOutput(type: .calendarCandidates, language: .english, content: calendarCandidates),
            GeneratedOutput(type: .summaryConcise, language: .english, content: summary.concise),
            GeneratedOutput(type: .summaryDetailed, language: .english, content: summary.detailed),
            GeneratedOutput(type: .summaryBullets, language: .english, content: summary.bullets),
        ]
    }

    private nonisolated static func condensedText(from text: String, maxSentences: Int) -> String {
        let sentences = extractSentences(from: text, limit: maxSentences)
        if sentences.isEmpty {
            return "No transcript content was available."
        }

        return sentences.joined(separator: " ")
    }

    private nonisolated static func extractSentences(from text: String, limit: Int) -> [String] {
        text
            .components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(limit)
            .map { String($0) }
    }
}
