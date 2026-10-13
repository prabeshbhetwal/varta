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

        let size = try promptURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 64_000 else { throw LocalModelError.invalidOutput("Prompt \(template.filename) exceeds 64 KB.") }
        let text = try String(contentsOf: promptURL, encoding: .utf8)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalModelError.invalidOutput("Prompt \(template.filename) is empty.")
        }
        return text
    }

    static func render(_ template: PromptTemplate, context: [String: String], appSupportDirectoryURL: URL) throws -> String {
        try render(instruction: instruction(for: template, appSupportDirectoryURL: appSupportDirectoryURL), context: context)
    }

    static func snapshot(appSupportDirectoryURL: URL) throws -> [PromptTemplate: String] {
        try Dictionary(uniqueKeysWithValues: PromptTemplate.allCases.map {
            ($0, try instruction(for: $0, appSupportDirectoryURL: appSupportDirectoryURL))
        })
    }

    static func render(_ template: PromptTemplate, context: [String: String], snapshot: [PromptTemplate: String]) throws -> String {
        guard let instruction = snapshot[template] else { throw LocalModelError.missingAsset("Prompt: \(template.filename)") }
        return try render(instruction: instruction, context: context)
    }

    private static func render(instruction: String, context: [String: String]) throws -> String {
        let data = try JSONEncoder().encode(context)
        return instruction + "\n\n" + String(decoding: data, as: UTF8.self)
    }

    private static func instruction(for template: PromptTemplate, appSupportDirectoryURL: URL) throws -> String {
        let instruction = try loadPrompt(for: template, appSupportDirectoryURL: appSupportDirectoryURL)
        var contract = ""
        if [.windowSummary, .sectionSynthesis, .finalSummary, .actionItems, .decisions, .calendarCandidates].contains(template) {
            let bundled = bundledPromptContent(for: template, bundle: .main)
            guard !bundled.isEmpty else {
                throw LocalModelError.missingAsset("Required response contract for \(template.filename)")
            }
            // Keep custom/older files; bundled response and evidence contracts remain invariant.
            contract = "\n\nMandatory response and evidence rules (override earlier conflicting instructions):\n" + bundled
        }
        return instruction + contract
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
