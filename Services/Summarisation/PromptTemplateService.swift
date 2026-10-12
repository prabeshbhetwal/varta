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
            guard !defaultContent.isEmpty else { throw LocalModelError.missingAsset("Bundled prompt: \(template.filename)") }
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
            guard !fallback.isEmpty else { throw LocalModelError.missingAsset("Bundled prompt: \(template.filename)") }
            return fallback
        }

        let text = try String(contentsOf: promptURL, encoding: .utf8)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalModelError.invalidOutput("Prompt \(template.filename) is empty.")
        }
        return text
    }

    static func render(_ template: PromptTemplate, context: [String: String], appSupportDirectoryURL: URL) throws -> String {
        let instruction = try loadPrompt(for: template, appSupportDirectoryURL: appSupportDirectoryURL)
        let data = try JSONEncoder().encode(context)
        var contract = ""
        if template == .finalSummary || template == .calendarCandidates {
            let bundled = bundledPromptContent(for: template, bundle: .main)
            guard !bundled.isEmpty else {
                throw LocalModelError.missingAsset("Structured response contract for \(template.filename)")
            }
            // Keep custom/older prompt files; the bundled schema remains an invariant.
            contract = "\n\n" + bundled
        }
        return instruction + contract + "\n\n" + String(decoding: data, as: UTF8.self)
    }

    private static func bundledPromptContent(for template: PromptTemplate, bundle: Bundle) -> String {
        let name = template.rawValue
        if let url = bundle.url(forResource: name, withExtension: "txt", subdirectory: "Prompts")
            ?? bundle.url(forResource: name, withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }

        return ""
    }

}
