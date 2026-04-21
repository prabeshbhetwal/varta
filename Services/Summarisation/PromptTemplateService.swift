import Foundation

enum PromptTemplate: String, CaseIterable, Sendable {
    case windowSummary = "window-summary"
    case sectionSynthesis = "section-synthesis"
    case finalSummary = "final-summary"
    case actionItems = "action-items"
    case decisions = "decisions"
    case unresolvedQuestions = "unresolved-questions"
    case followUpEmail = "follow-up-email"
    case calendarCandidates = "calendar-candidates"
    case translation = "translation"

    var filename: String {
        "\(rawValue).txt"
    }
}

enum PromptTemplateService {
    static func ensurePromptTemplatesInstalled(
        appSupportDirectoryURL: URL,
        bundle: Bundle,
        fileManager: FileManager = .default
    ) throws {
        let promptsDirectory = appSupportDirectoryURL.appendingPathComponent("Prompts", isDirectory: true)
        try fileManager.createDirectory(at: promptsDirectory, withIntermediateDirectories: true)

        for template in PromptTemplate.allCases {
            let destinationURL = promptsDirectory.appendingPathComponent(template.filename)
            if fileManager.fileExists(atPath: destinationURL.path) {
                continue
            }

            let defaultContent = bundledPromptContent(for: template, bundle: bundle)
            try defaultContent.write(to: destinationURL, atomically: true, encoding: .utf8)
        }
    }

    static func loadPrompt(
        for template: PromptTemplate,
        appSupportDirectoryURL: URL,
        fileManager: FileManager = .default
    ) throws -> String {
        let promptURL = appSupportDirectoryURL
            .appendingPathComponent("Prompts", isDirectory: true)
            .appendingPathComponent(template.filename)

        if !fileManager.fileExists(atPath: promptURL.path) {
            let fallback = bundledPromptContent(for: template, bundle: .main)
            return fallback
        }

        return try String(contentsOf: promptURL, encoding: .utf8)
    }

    private static func bundledPromptContent(for template: PromptTemplate, bundle: Bundle) -> String {
        let name = template.rawValue
        if let url = bundle.url(forResource: name, withExtension: "txt", subdirectory: "Prompts"),
           let text = try? String(contentsOf: url, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }

        return defaultPromptContents[template] ?? ""
    }

    private static let defaultPromptContents: [PromptTemplate: String] = [
        .windowSummary: "Summarise this transcript window in 3-5 concise bullet points.",
        .sectionSynthesis: "Combine these window summaries into one section summary with key points and risks.",
        .finalSummary: "Create concise, detailed, and bullet summaries from the section summaries.",
        .actionItems: "Extract action items as an owner + task + due date list when available.",
        .decisions: "Extract explicit decisions and include rationale if present.",
        .unresolvedQuestions: "List unresolved questions and who should answer each question when available.",
        .followUpEmail: "Draft a professional follow-up email using summary, decisions, and action items.",
        .calendarCandidates: "Suggest possible follow-up events with title, date hints, duration, and reason.",
        .translation: "Translate output while preserving factual meaning and structure."
    ]
}
