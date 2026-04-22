import Foundation

actor ImportPipelineService {
    private let storageService: StorageService

    init(
        storageService: StorageService
    ) {
        self.storageService = storageService
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
        return meetingID
    }
}
