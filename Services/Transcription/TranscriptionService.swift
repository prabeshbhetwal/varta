import Foundation

actor TranscriptionService {
    private struct Checkpoint: Codable, Sendable {
        let meetingID: String
        let languageMode: LanguageMode
        let sourceMediaIDs: [String]
        let transcriptRevision: Int
        let preparedAudio: PreparedMeetingAudio
        var completedWindows: Int
        var segments: [NewTranscriptSegment]
    }

    enum TranscriptionError: LocalizedError {
        case alreadyRunning
        case invalidResume
        case reviewedTranscript
        case invalidEngineOutput

        var errorDescription: String? {
            switch self {
            case .alreadyRunning: return "Transcription is already running for this meeting."
            case .invalidResume: return "The saved transcription checkpoint no longer matches this meeting. Start a new transcription."
            case .reviewedTranscript: return "Transcription contains corrections or locked segments. Preserve those edits before retranscribing."
            case .invalidEngineOutput: return "Whisper returned invalid transcript timestamps or text. Prior transcript remains preserved."
            }
        }
    }

    private let storageService: StorageService
    private let memoryManager: MemoryManager
    private let whisperClient: WhisperCppClient
    private var isTranscribing = false

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
        try whisperClient.validateConfiguration()
        let records = try await storageService.importedMedia(for: meetingID)
        let root = await storageService.appSupportDirectory()
        guard records.contains(where: {
            root.appendingPathComponent($0.relativePath).standardizedFileURL == mediaURL.standardizedFileURL
        }) else { throw MediaProcessingError.invalidMedia(mediaURL.lastPathComponent) }
        return try await transcribeMeeting(meetingID: meetingID, languageMode: languageMode)
    }

    func transcribeMeeting(
        meetingID: String,
        languageMode: LanguageMode,
        resumeJobID: String? = nil
    ) async throws -> [TranscriptSegment] {
        guard !isTranscribing else { throw TranscriptionError.alreadyRunning }
        try whisperClient.validateConfiguration()
        isTranscribing = true
        defer { isTranscribing = false }
        let root = await storageService.appSupportDirectory()
        let records = try await storageService.importedMedia(for: meetingID)
        guard !records.isEmpty else { throw MediaProcessingError.noAudio }
        let sourceIDs = records.map(\.id).sorted()
        let running = try await storageService.jobs(statuses: [.running], type: .transcription)
        guard !running.contains(where: { $0.meetingID == meetingID }) else { throw TranscriptionError.alreadyRunning }
        let revision = try await storageService.transcriptRevision(meetingID: meetingID)
        let existing = try await storageService.transcriptSegments(meetingID: meetingID)
        guard !existing.contains(where: { $0.isLocked || $0.correctedText != nil }) else {
            throw TranscriptionError.reviewedTranscript
        }

        let jobID: String
        var saved: Checkpoint?
        if let resumeJobID {
            guard let job = try await storageService.job(id: resumeJobID), job.meetingID == meetingID,
                  job.jobType == .transcription, job.status == .paused || job.status == .failed,
                  let state = try await storageService.processingState(jobID: resumeJobID, stage: "transcription"),
                  let blob = state.checkpointBlob, blob.utf8.count <= 8_000_000,
                  let data = blob.data(using: .utf8) else { throw TranscriptionError.invalidResume }
            let decoded = try JSONDecoder().decode(Checkpoint.self, from: data)
            guard decoded.meetingID == meetingID, decoded.languageMode == languageMode,
                  decoded.sourceMediaIDs == sourceIDs, decoded.transcriptRevision == revision,
                  decoded.completedWindows >= 0, decoded.completedWindows <= decoded.preparedAudio.windows.count,
                  !decoded.preparedAudio.windows.isEmpty, decoded.preparedAudio.durationSeconds.isFinite,
                  decoded.preparedAudio.durationSeconds > 0, decoded.preparedAudio.durationSeconds <= 14_400,
                  decoded.preparedAudio.windows.allSatisfy({
                      $0.startSeconds.isFinite && $0.startSeconds >= 0 && $0.durationSeconds.isFinite &&
                      $0.durationSeconds > 0 && $0.durationSeconds <= 600 &&
                      $0.startSeconds + $0.durationSeconds <= decoded.preparedAudio.durationSeconds + 0.01
                  }) else { throw TranscriptionError.invalidResume }
            for window in decoded.preparedAudio.windows {
                _ = try MediaProcessingService.checkedURL(relativePath: window.relativePath, rootDirectory: root)
            }
            saved = decoded
            jobID = resumeJobID
            try await storageService.updateJobStatus(id: jobID, status: .running, errorMessage: nil)
        } else {
            jobID = try await storageService.createJob(meetingID: meetingID, type: .transcription, status: .running)
        }

        do {
            var checkpoint: Checkpoint
            if let saved { checkpoint = saved }
            else {
                let prepared = try await MediaProcessingService(rootDirectory: root).prepare(media: records, meetingID: meetingID)
                checkpoint = Checkpoint(meetingID: meetingID, languageMode: languageMode,
                    sourceMediaIDs: sourceIDs, transcriptRevision: revision, preparedAudio: prepared,
                    completedWindows: 0, segments: [])
                try await persist(checkpoint, jobID: jobID)
            }
            for index in checkpoint.completedWindows..<checkpoint.preparedAudio.windows.count {
                try Task.checkCancellation()
                let window = checkpoint.preparedAudio.windows[index]
                let url = try MediaProcessingService.checkedURL(relativePath: window.relativePath, rootDirectory: root)
                let client = whisperClient
                let transcribed = try await memoryManager.runExclusive(family: .whisper) {
                    try await client.transcribe(mediaURL: url, languageMode: languageMode)
                }
                guard transcribed.allSatisfy({ segment in
                    segment.startSeconds.isFinite && segment.endSeconds.isFinite && segment.startSeconds >= 0 &&
                    segment.startSeconds <= window.durationSeconds && segment.endSeconds >= segment.startSeconds &&
                    segment.endSeconds <= window.durationSeconds + 0.05 &&
                    !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }) else { throw TranscriptionError.invalidEngineOutput }
                checkpoint.segments.append(contentsOf: transcribed.map { segment in
                    NewTranscriptSegment(startSeconds: window.startSeconds + segment.startSeconds,
                        endSeconds: window.startSeconds + min(segment.endSeconds, window.durationSeconds),
                        text: segment.text, languageTag: Self.languageTag(for: segment.text, languageMode: languageMode).rawValue,
                        speakerLabel: nil)
                })
                checkpoint.completedWindows = index + 1
                try await persist(checkpoint, jobID: jobID)
            }
            try Task.checkCancellation()
            guard !checkpoint.segments.isEmpty else { throw TranscriptionError.invalidEngineOutput }
            let latestMediaIDs = try await storageService.importedMedia(for: meetingID).map(\.id).sorted()
            guard latestMediaIDs == checkpoint.sourceMediaIDs else { throw TranscriptionError.invalidResume }
            let blob = String(decoding: try JSONEncoder().encode(checkpoint), as: UTF8.self)
            try await storageService.saveTranscriptionResult(meetingID: meetingID, jobID: jobID,
                segments: checkpoint.segments, checkpointBlob: blob, expectedTranscriptRevision: checkpoint.transcriptRevision)
            return try await storageService.transcriptSegments(meetingID: meetingID)
        } catch {
            do {
                try await storageService.updateJobStatus(id: jobID,
                    status: error is CancellationError ? .paused : .failed, errorMessage: error.localizedDescription)
            } catch let persistenceError {
                throw MediaProcessingError.conversionFailed("Job state could not be saved: \(persistenceError.localizedDescription)")
            }
            throw error
        }
    }

    func recoverInterruptedJobs() async throws -> [JobRecord] {
        let interrupted = try await storageService.jobs(statuses: [.running, .queued], type: .transcription)
        for job in interrupted {
            try await storageService.updateJobStatus(id: job.id, status: .paused,
                errorMessage: "Interrupted by app exit. Resume from the last completed audio window.")
        }
        return try await storageService.jobs(statuses: [.paused], type: .transcription)
    }

    private func persist(_ checkpoint: Checkpoint, jobID: String) async throws {
        let blob = String(decoding: try JSONEncoder().encode(checkpoint), as: UTF8.self)
        let completedDuration = checkpoint.preparedAudio.windows.prefix(checkpoint.completedWindows)
            .reduce(0) { $0 + $1.durationSeconds }
        try await storageService.upsertProcessingState(jobID: jobID, stage: "transcription",
            checkpointBlob: blob, checkpointOffsetSeconds: completedDuration)
        try await storageService.updateJobStatus(id: jobID, status: .running,
            progress: completedDuration / checkpoint.preparedAudio.durationSeconds, errorMessage: nil)
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
                (0x0041...0x005A).contains(scalar.value) || (0x0061...0x007A).contains(scalar.value)
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
