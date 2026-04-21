import Foundation

actor Checkpointer {
    private let storageService: StorageService

    init(storageService: StorageService) {
        self.storageService = storageService
    }

    func saveRecordingCheckpoint(
        jobID: String,
        payload: RecordingCheckpointPayload,
        stage: String = "recording"
    ) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(payload)
        let blob = String(decoding: encoded, as: UTF8.self)

        try await storageService.upsertProcessingState(
            jobID: jobID,
            stage: stage,
            checkpointBlob: blob,
            checkpointOffsetSeconds: payload.totalRecordedSeconds
        )
    }

    func latestRecordingCheckpoint(jobID: String, stage: String = "recording") async throws -> RecordingCheckpointPayload? {
        guard let checkpoint = try await storageService.processingState(jobID: jobID, stage: stage),
              let blob = checkpoint.checkpointBlob,
              let data = blob.data(using: .utf8)
        else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RecordingCheckpointPayload.self, from: data)
    }
}
