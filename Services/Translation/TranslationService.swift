import Foundation

actor TranslationService {
    private let storageService: StorageService
    private let memoryManager: MemoryManager

    init(storageService: StorageService, memoryManager: MemoryManager) {
        self.storageService = storageService
        self.memoryManager = memoryManager
    }

    func translateOutputs(meetingID: String, targetLanguage: LanguageMode) async throws -> [GeneratedOutput] {
        guard targetLanguage == .english || targetLanguage == .nepali else {
            return []
        }

        let sourceLanguage: LanguageMode = targetLanguage == .english ? .nepali : .english
        let existingSourceOutputs = try await storageService.generatedOutputs(meetingID: meetingID, language: sourceLanguage)

        let sourceOutputs: [GeneratedOutput]
        if existingSourceOutputs.isEmpty {
            sourceOutputs = try await storageService.generatedOutputs(meetingID: meetingID, language: .english)
        } else {
            sourceOutputs = existingSourceOutputs
        }

        let appSupportURL = await storageService.appSupportDirectory()
        let translationPrompt = (try? PromptTemplateService.loadPrompt(for: .translation, appSupportDirectoryURL: appSupportURL)) ?? ""

        let translated = try await memoryManager.runExclusive(family: .translation) {
            sourceOutputs.map { output in
                let translatedText = Self.translateText(
                    output.content,
                    to: targetLanguage,
                    promptPrefix: translationPrompt
                )
                return GeneratedOutput(type: output.type, language: targetLanguage, content: translatedText)
            }
        }

        for output in translated {
            try await storageService.upsertGeneratedOutput(
                meetingID: meetingID,
                type: output.type,
                language: output.language,
                content: output.content
            )
        }

        return translated
    }

    nonisolated static func translateText(_ text: String, to language: LanguageMode, promptPrefix: String = "") -> String {
        guard !text.isEmpty else {
            return text
        }

        let dictionary: [String: String]
        switch language {
        case .nepali:
            dictionary = enToNeDictionary
        case .english:
            dictionary = neToEnDictionary
        case .mixed:
            return text
        }

        var translated = text
        for (source, target) in dictionary {
            let escaped = NSRegularExpression.escapedPattern(for: source)
            guard let regex = try? NSRegularExpression(pattern: "\\b\(escaped)\\b", options: [.caseInsensitive]) else {
                continue
            }

            let range = NSRange(translated.startIndex..<translated.endIndex, in: translated)
            translated = regex.stringByReplacingMatches(in: translated, options: [], range: range, withTemplate: target)
        }

        if promptPrefix.isEmpty {
            return translated
        }

        return "\(promptPrefix)\n\n\(translated)"
    }

    private nonisolated static let enToNeDictionary: [String: String] = [
        "meeting": "बैठक",
        "summary": "सारांश",
        "action": "कार्य",
        "items": "सूची",
        "decisions": "निर्णयहरू",
        "decision": "निर्णय",
        "questions": "प्रश्नहरू",
        "question": "प्रश्न",
        "follow-up": "फलो-अप",
        "email": "इमेल",
        "next": "अर्को",
        "week": "हप्ता",
        "tomorrow": "भोलि",
        "team": "टोली",
        "task": "काम",
        "owner": "जिम्मेवार",
        "due": "समयसीमा",
        "approved": "स्वीकृत",
        "agreed": "सहमत",
        "please": "कृपया",
    ]

    private nonisolated static let neToEnDictionary: [String: String] = [
        "बैठक": "meeting",
        "सारांश": "summary",
        "कार्य": "action",
        "सूची": "items",
        "निर्णयहरू": "decisions",
        "निर्णय": "decision",
        "प्रश्नहरू": "questions",
        "प्रश्न": "question",
        "फलो-अप": "follow-up",
        "इमेल": "email",
        "अर्को": "next",
        "हप्ता": "week",
        "भोलि": "tomorrow",
        "टोली": "team",
        "काम": "task",
        "जिम्मेवार": "owner",
        "समयसीमा": "due",
        "स्वीकृत": "approved",
        "सहमत": "agreed",
        "कृपया": "please",
    ]
}
