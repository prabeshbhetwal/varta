import Foundation

actor TranscriptionService {
    private let storageService: StorageService
    private let memoryManager: MemoryManager
    private let whisperClient: WhisperCppClient

    init(
        storageService: StorageService,
        memoryManager: MemoryManager,
        whisperClient: WhisperCppClient = WhisperCppBridge()
    ) {
        self.storageService = storageService
        self.memoryManager = memoryManager
        self.whisperClient = whisperClient
    }

    func transcribeMeeting(
        meetingID: String,
        mediaURL: URL,
        languageMode: LanguageMode
    ) async throws -> [TranscriptSegment] {
        let transcribed = try await memoryManager.runExclusive(family: .whisper) {
            try await self.whisperClient.transcribe(mediaURL: mediaURL, languageMode: languageMode)
        }

        let insertable = transcribed.map { segment in
            NewTranscriptSegment(
                startSeconds: segment.startSeconds,
                endSeconds: segment.endSeconds,
                text: segment.text,
                languageTag: Self.languageTag(for: segment.text, languageMode: languageMode).rawValue,
                speakerLabel: nil
            )
        }

        try await storageService.replaceTranscriptSegments(meetingID: meetingID, segments: insertable)
        return try await storageService.transcriptSegments(meetingID: meetingID)
    }

    nonisolated static func languageTag(for text: String, languageMode: LanguageMode) -> LanguageMode {
        switch languageMode {
        case .english:
            return .english
        case .nepali:
            return .nepali
        case .mixed:
            let hasDevanagari = text.unicodeScalars.contains { scalar in
                (0x0900...0x097F).contains(scalar.value)
            }
            let hasLatin = text.unicodeScalars.contains { scalar in
                (0x0041...0x007A).contains(scalar.value)
            }

            if hasDevanagari && hasLatin {
                return .mixed
            }

            if hasDevanagari {
                return .nepali
            }

            return .english
        }
    }
}
