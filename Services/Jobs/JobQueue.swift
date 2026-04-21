import Foundation

actor JobQueue {
    private let storageService: StorageService

    init(storageService: StorageService) {
        self.storageService = storageService
    }

    func beginRecordingJob(meetingID: String) async throws -> JobRecord {
        let jobID = try await storageService.createJob(meetingID: meetingID, type: .recording, status: .running)
        guard let created = try await storageService.job(id: jobID) else {
            throw NSError(domain: "Varta.JobQueue", code: 1001, userInfo: [NSLocalizedDescriptionKey: "Failed to create recording job"])
        }

        return created
    }

    func updateRecordingProgress(jobID: String, progress: Double) async throws {
        try await storageService.updateJobStatus(
            id: jobID,
            status: .running,
            progress: max(0, min(progress, 1)),
            errorMessage: nil
        )
    }

    func pauseRecordingJob(jobID: String) async throws {
        try await storageService.updateJobStatus(id: jobID, status: .paused)
    }

    func completeRecordingJob(jobID: String) async throws {
        try await storageService.updateJobStatus(id: jobID, status: .completed, progress: 1)
    }

    func failRecordingJob(jobID: String, errorMessage: String) async throws {
        try await storageService.updateJobStatus(id: jobID, status: .failed, errorMessage: errorMessage)
    }

    func recoverInterruptedRecordingJobs() async throws -> [JobRecord] {
        let interrupted = try await storageService.jobs(statuses: [.running], type: .recording)
        for job in interrupted {
            try await storageService.updateJobStatus(id: job.id, status: .paused)
        }

        return try await storageService.jobs(statuses: [.paused], type: .recording)
    }

    func recordingJob(id: String) async throws -> JobRecord? {
        try await storageService.job(id: id)
    }
}
