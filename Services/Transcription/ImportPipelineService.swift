import Foundation

actor ImportPipelineService {
    private let storageService: StorageService
    private let transcriptionService: TranscriptionService
    private let summariserService: SummariserService

    init(
        storageService: StorageService,
        transcriptionService: TranscriptionService,
        summariserService: SummariserService
    ) {
        self.storageService = storageService
        self.transcriptionService = transcriptionService
        self.summariserService = summariserService
    }

    func importMedia(
        from sourceURL: URL,
        languageMode: LanguageMode = .mixed
    ) async throws -> String {
        let title = sourceURL.deletingPathExtension().lastPathComponent
        let meetingID = try await storageService.createMeeting(title: title, languageMode: languageMode)

        let imported = try await storageService.importMediaFile(sourceURL: sourceURL, meetingID: meetingID)
        try await storageService.registerImportedMedia(
            meetingID: meetingID,
            relativePath: imported.relativePath,
            originalFilename: sourceURL.lastPathComponent,
            format: sourceURL.pathExtension.lowercased(),
            durationSeconds: nil
        )

        _ = try await transcriptionService.transcribeMeeting(
            meetingID: meetingID,
            mediaURL: imported.destinationURL,
            languageMode: languageMode
        )

        _ = try await summariserService.summariseMeeting(meetingID: meetingID)
        return meetingID
    }
}
