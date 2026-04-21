import Foundation

enum LanguageMode: String, CaseIterable, Codable, Sendable {
    case english = "en"
    case nepali = "ne"
    case mixed = "mixed"
}

enum GeneratedOutputType: String, CaseIterable, Codable, Sendable {
    case actionItems = "action_items"
    case decisions = "decisions"
    case unresolvedQuestions = "unresolved_questions"
    case followUpEmail = "follow_up_email"
    case calendarCandidates = "calendar_candidates"
    case summaryConcise = "summary_concise"
    case summaryDetailed = "summary_detailed"
    case summaryBullets = "summary_bullets"
}

struct MeetingListItem: Identifiable, Sendable {
    let id: String
    let title: String
    let languageMode: LanguageMode
    let createdAt: Date
    let updatedAt: Date
}

struct ImportedMediaRecord: Identifiable, Sendable {
    let id: String
    let meetingID: String
    let relativePath: String
    let originalFilename: String?
    let format: String
    let durationSeconds: Double?
    let sampleRateHz: Int?
    let channelCount: Int?
    let createdAt: Date
}

struct TranscriptSegment: Identifiable, Sendable {
    let id: Int64
    let meetingID: String
    let startSeconds: Double
    let endSeconds: Double
    let text: String
    let correctedText: String?
    let languageTag: String?
    let speakerLabel: String?
    let isLocked: Bool

    var effectiveText: String {
        if let correctedText, !correctedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return correctedText
        }

        return text
    }
}

struct NewTranscriptSegment: Sendable {
    let startSeconds: Double
    let endSeconds: Double
    let text: String
    let languageTag: String?
    let speakerLabel: String?
}

struct GlossaryTerm: Identifiable, Sendable {
    let id: Int64
    let term: String
    let replacement: String
    let languageCode: LanguageMode
}

struct SummaryContent: Sendable {
    let concise: String
    let detailed: String
    let bullets: String
}

struct GeneratedOutput: Identifiable, Sendable {
    var id: String { "\(type.rawValue)-\(language.rawValue)" }

    let type: GeneratedOutputType
    let language: LanguageMode
    let content: String
}

struct MeetingOutputs: Sendable {
    let summary: SummaryContent
    let outputs: [GeneratedOutput]
}

enum JobType: String, CaseIterable, Codable, Sendable {
    case recording = "recording"
    case transcription = "transcription"
    case summarisation = "summarisation"
    case translation = "translation"
}

enum JobStatus: String, CaseIterable, Codable, Sendable {
    case queued = "queued"
    case running = "running"
    case paused = "paused"
    case completed = "completed"
    case failed = "failed"
}

struct JobRecord: Identifiable, Sendable {
    let id: String
    let meetingID: String?
    let jobType: JobType
    let status: JobStatus
    let progress: Double
    let errorMessage: String?
    let createdAt: Date
    let updatedAt: Date
}

struct ProcessingCheckpoint: Sendable {
    let jobID: String
    let stage: String
    let checkpointBlob: String?
    let checkpointOffsetSeconds: Double?
    let updatedAt: Date
}
