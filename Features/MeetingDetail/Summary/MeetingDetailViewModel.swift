import Foundation

@MainActor
final class MeetingDetailViewModel: ObservableObject {
    @Published private(set) var segments: [TranscriptSegment] = []
    @Published private(set) var glossaryTerms: [GlossaryTerm] = []
    @Published private(set) var summary: SummaryContent?
    @Published private(set) var outputsByType: [GeneratedOutputType: String] = [:]
    @Published var selectedOutputLanguage: LanguageMode = .english
    @Published var isBusy = false
    @Published var errorMessage: String?

    let meetingID: String

    private let storageService: StorageService
    private let summariserService: SummariserService
    private let translationService: TranslationService

    init(meetingID: String, storageService: StorageService) {
        self.meetingID = meetingID
        self.storageService = storageService

        let memoryManager = MemoryManager()
        self.summariserService = SummariserService(storageService: storageService, memoryManager: memoryManager)
        self.translationService = TranslationService(storageService: storageService, memoryManager: memoryManager)
    }

    func refresh() async {
        do {
            let segments = try await storageService.transcriptSegments(meetingID: meetingID)
            let glossary = try await storageService.glossaryTerms()
            let summary = try await storageService.summary(meetingID: meetingID)
            let outputs = try await storageService.generatedOutputs(meetingID: meetingID, language: selectedOutputLanguage)

            self.segments = segments
            self.glossaryTerms = glossary
            self.summary = summary
            self.outputsByType = Dictionary(uniqueKeysWithValues: outputs.map { ($0.type, $0.content) })
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func regenerateSummary() async {
        isBusy = true
        defer { isBusy = false }

        do {
            _ = try await summariserService.summariseMeeting(meetingID: meetingID)
            await refresh()
        } catch {
            errorMessage = "Summary generation failed: \(error.localizedDescription)"
        }
    }

    func translateOutputsIfNeeded() async {
        guard selectedOutputLanguage == .english || selectedOutputLanguage == .nepali else {
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            _ = try await translationService.translateOutputs(meetingID: meetingID, targetLanguage: selectedOutputLanguage)
            await refresh()
        } catch {
            errorMessage = "Translation failed: \(error.localizedDescription)"
        }
    }

    func updateSegmentCorrection(segmentID: Int64, correctedText: String) async {
        do {
            try await storageService.updateTranscriptCorrection(segmentID: segmentID, correctedText: correctedText)
            await refresh()
        } catch {
            errorMessage = "Could not save correction: \(error.localizedDescription)"
        }
    }

    func setSegmentLock(segmentID: Int64, isLocked: Bool) async {
        do {
            try await storageService.setTranscriptSegmentLock(segmentID: segmentID, isLocked: isLocked)
            await refresh()
        } catch {
            errorMessage = "Could not update lock: \(error.localizedDescription)"
        }
    }

    func addGlossaryTerm(term: String, replacement: String, languageCode: LanguageMode) async {
        do {
            try await storageService.addGlossaryTerm(term: term, replacement: replacement, languageCode: languageCode)
            await refresh()
        } catch {
            errorMessage = "Could not save glossary term: \(error.localizedDescription)"
        }
    }

    func deleteGlossaryTerm(id: Int64) async {
        do {
            try await storageService.deleteGlossaryTerm(id: id)
            await refresh()
        } catch {
            errorMessage = "Could not delete glossary term: \(error.localizedDescription)"
        }
    }

    func content(for type: GeneratedOutputType) -> String {
        outputsByType[type] ?? ""
    }
}
