import Foundation

actor TranslationService {
    private let storageService: StorageService
    private let memoryManager: MemoryManager
    private let client: any LocalLanguageModelClient

    init(storageService: StorageService, memoryManager: MemoryManager, client: any LocalLanguageModelClient = MLXLanguageModelClient()) {
        self.storageService = storageService
        self.memoryManager = memoryManager
        self.client = client
    }

    func translateOutputs(meetingID: String, targetLanguage: LanguageMode) async throws -> [GeneratedOutput] {
        guard targetLanguage != .mixed else { throw LocalModelError.invalidOutput("Choose English or Nepali for translated outputs.") }
        let revision = try await storageService.transcriptRevision(meetingID: meetingID)
        let source = try await storageService.generatedOutputs(meetingID: meetingID, language: .english)
        guard !source.isEmpty else { throw LocalModelError.invalidOutput("Generate English meeting outputs before translating.") }
        // English remains the canonical source; never replace it with a back translation.
        if targetLanguage == .english { return source }
        guard try await storageService.summaryIsCurrent(meetingID: meetingID) else { throw StorageService.StorageError.transcriptChanged }
        let root = await storageService.appSupportDirectory()
        let jobID = try await storageService.createJob(meetingID: meetingID, type: .translation, status: .queued)
        do {
          return try await memoryManager.runExclusive(family: .translation) {
            do {
                try await self.storageService.updateJobStatus(id: jobID, status: .running)
                var translated: [GeneratedOutput] = []
                for output in source {
                    try Task.checkCancellation()
                    let text: String
                    if output.type == .calendarCandidates {
                        let candidates = try JSONDecoder().decode([CalendarCandidate].self, from: SummariserService.jsonData(output.content))
                        var values: [CalendarCandidate] = []
                        for candidate in candidates {
                            try candidate.validate()
                            let title = try await self.translate(candidate.title, root: root)
                            let reason = try await self.translate(candidate.reason, root: root)
                            let value = CalendarCandidate(title: title, dateHint: candidate.dateHint, durationMinutes: candidate.durationMinutes, reason: reason, sourceQuote: candidate.sourceQuote)
                            try value.validate()
                            values.append(value)
                        }
                        text = String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
                    } else {
                        text = try await self.translate(output.content, root: root)
                    }
                    translated.append(GeneratedOutput(type: output.type, language: .nepali, content: text))
                    try await self.storageService.updateJobStatus(id: jobID, status: .running, progress: Double(translated.count) / Double(source.count) * 0.9)
                }
                try Task.checkCancellation()
                try await self.storageService.saveTranslatedOutputs(meetingID: meetingID, sourceOutputs: source, outputs: translated, expectedTranscriptRevision: revision, jobID: jobID)
                await self.client.unload()
                return translated
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

    private func translate(_ text: String, root: URL) async throws -> String {
        guard !text.isEmpty else { return text }
        var parts: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            var end = text.index(start, offsetBy: 8_000, limitedBy: text.endIndex) ?? text.endIndex
            if end < text.endIndex, let boundary = text[start..<end].lastIndex(where: \.isWhitespace) {
                end = text.index(after: boundary)
            }
            let instruction = try PromptTemplateService.instruction(for: .translation, appSupportDirectoryURL: root)
            let result = try await client.generate(instruction: instruction, context: [
                "target_language": "ne", "source_language": "en", "text": String(text[start..<end])
            ]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !result.isEmpty else { throw LocalModelError.invalidOutput("Translation returned empty text.") }
            parts.append(result)
            start = end
        }
        return parts.joined(separator: "\n")
    }
}
