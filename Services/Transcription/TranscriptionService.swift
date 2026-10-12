import AVFoundation
import Foundation

actor TranscriptionService {
    private struct Checkpoint: Codable, Sendable {
        let meetingID: String
        let languageMode: LanguageMode
        let sourceMediaIDs: [String]
        let transcriptRevision: Int
        let voiceActivityIdentity: String?
        let whisperIdentity: String?
        let preparedAudio: PreparedMeetingAudio
        var completedWindows: Int
        var segments: [NewTranscriptSegment]
    }

    enum TranscriptionError: LocalizedError {
        case alreadyRunning
        case invalidResume
        case reviewedTranscript
        case invalidEngineOutput
        case repetitionLoop
        case invalidVoiceActivity

        var errorDescription: String? {
            switch self {
            case .alreadyRunning: return "Transcription is already running for this meeting."
            case .invalidResume: return "The saved transcription checkpoint no longer matches this meeting or its transcription/voice activity models and policy. Start a new transcription; existing audio and content remain preserved."
            case .reviewedTranscript: return "Transcription contains corrections or locked segments. Preserve those edits before retranscribing."
            case .invalidEngineOutput: return "Whisper returned invalid transcript timestamps or text. Prior transcript remains preserved."
            case .repetitionLoop: return "Whisper output still contains a repetition loop after a clean retry. Prior transcript and completed audio windows remain preserved."
            case .invalidVoiceActivity: return "Voice activity detection returned incomplete or invalid audio ranges. Prior transcript and completed windows remain preserved."
            }
        }
    }

    private let storageService: StorageService
    private let memoryManager: MemoryManager
    private let whisperClient: WhisperCppClient
    private let voiceActivityDetector: VoiceActivityDetecting
    private var isTranscribing = false
    private(set) var lastCompletionHadNoSpeech = false

    init(
        storageService: StorageService,
        memoryManager: MemoryManager,
        whisperClient: WhisperCppClient = WhisperCppBridge(),
        voiceActivityDetector: VoiceActivityDetecting = WhisperVoiceActivityDetector()
    ) {
        self.storageService = storageService
        self.memoryManager = memoryManager
        self.whisperClient = whisperClient
        self.voiceActivityDetector = voiceActivityDetector
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
        try Task.checkCancellation()
        try whisperClient.validateConfiguration()
        let whisperIdentity = try whisperClient.configurationIdentity()
        let voiceActivityIdentity = try voiceActivityDetector.configurationIdentity()
        guard !voiceActivityIdentity.isEmpty, voiceActivityIdentity.utf8.count <= 1_024,
              !whisperIdentity.isEmpty, whisperIdentity.utf8.count <= 1_024 else {
            throw TranscriptionError.invalidVoiceActivity
        }
        isTranscribing = true
        lastCompletionHadNoSpeech = false
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
                  decoded.voiceActivityIdentity == voiceActivityIdentity,
                  decoded.whisperIdentity == whisperIdentity,
                  decoded.completedWindows >= 0, decoded.completedWindows <= decoded.preparedAudio.windows.count,
                  !decoded.preparedAudio.windows.isEmpty, decoded.preparedAudio.durationSeconds.isFinite,
                  decoded.preparedAudio.durationSeconds > 0, decoded.preparedAudio.durationSeconds <= 14_400,
                  decoded.preparedAudio.windows.allSatisfy({
                      $0.startSeconds.isFinite && $0.startSeconds >= 0 && $0.durationSeconds.isFinite &&
                      $0.durationSeconds > 0 && $0.durationSeconds <= 600 &&
                      $0.startSeconds + $0.durationSeconds <= decoded.preparedAudio.durationSeconds + 0.01
                  }) else { throw TranscriptionError.invalidResume }
            try Self.validatePreparedAudio(decoded.preparedAudio, meetingID: meetingID, rootDirectory: root)
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
                try Self.validatePreparedAudio(prepared, meetingID: meetingID, rootDirectory: root)
                checkpoint = Checkpoint(meetingID: meetingID, languageMode: languageMode,
                    sourceMediaIDs: sourceIDs, transcriptRevision: revision,
                    voiceActivityIdentity: voiceActivityIdentity, whisperIdentity: whisperIdentity, preparedAudio: prepared,
                    completedWindows: 0, segments: [])
                try await persist(checkpoint, jobID: jobID)
            }
            for index in checkpoint.completedWindows..<checkpoint.preparedAudio.windows.count {
                try Task.checkCancellation()
                let window = checkpoint.preparedAudio.windows[index]
                let url = try MediaProcessingService.checkedURL(relativePath: window.relativePath, rootDirectory: root)
                let client = whisperClient
                let detector = voiceActivityDetector
                let frameCount = Int64((window.durationSeconds * 16_000).rounded())
                let promptContext = WhisperDecodingPolicy.boundedContext(checkpoint.segments.suffix(16).map(\.text).joined(separator: " "))
                let transcribed = try await memoryManager.runExclusive(family: .whisper) {
                    guard try detector.configurationIdentity() == voiceActivityIdentity,
                          try client.configurationIdentity() == whisperIdentity else {
                        throw TranscriptionError.invalidResume
                    }
                    let detection = try await detector.detectSpeech(mediaURL: url)
                    try Task.checkCancellation()
                    try Self.validateVoiceActivity(detection, expectedFrameCount: frameCount)
                    guard !detection.spans.isEmpty else { return [WhisperTranscribedSegment]() }
                    return try await Self.decodeWindow(client: client, mediaURL: url, languageMode: languageMode,
                        promptContext: promptContext, durationSeconds: window.durationSeconds,
                        speechSpans: detection.spans)
                }
                try Task.checkCancellation()
                guard try voiceActivityDetector.configurationIdentity() == voiceActivityIdentity,
                      try whisperClient.configurationIdentity() == whisperIdentity else {
                    throw TranscriptionError.invalidResume
                }
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
            guard try voiceActivityDetector.configurationIdentity() == voiceActivityIdentity,
                  try whisperClient.configurationIdentity() == whisperIdentity else {
                throw TranscriptionError.invalidResume
            }
            let latestMediaIDs = try await storageService.importedMedia(for: meetingID).map(\.id).sorted()
            guard latestMediaIDs == checkpoint.sourceMediaIDs else { throw TranscriptionError.invalidResume }
            let blob = String(decoding: try JSONEncoder().encode(checkpoint), as: UTF8.self)
            do {
                try await storageService.saveTranscriptionResult(meetingID: meetingID, jobID: jobID,
                    segments: checkpoint.segments, checkpointBlob: blob, expectedTranscriptRevision: checkpoint.transcriptRevision,
                    expectedSourceMediaIDs: checkpoint.sourceMediaIDs,
                    processedDurationSeconds: checkpoint.preparedAudio.durationSeconds)
            } catch StorageService.StorageError.sourceMediaChanged {
                throw TranscriptionError.invalidResume
            }
            lastCompletionHadNoSpeech = checkpoint.segments.isEmpty
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

    nonisolated static func decodeWindow(client: WhisperCppClient, mediaURL: URL, languageMode: LanguageMode,
        promptContext: String, durationSeconds: Double, speechSpans: [VoiceActivitySpan]? = nil) async throws -> [WhisperTranscribedSegment] {
        guard durationSeconds.isFinite, durationSeconds > 0, durationSeconds <= 30 else {
            throw TranscriptionError.invalidEngineOutput
        }
        let spans = speechSpans ?? [VoiceActivitySpan(startFrame: 0, endFrame: Int64((durationSeconds * 16_000).rounded()))]
        try validateVoiceActivity(VoiceActivityDetection(frameCount: Int64((durationSeconds * 16_000).rounded()), spans: spans),
            expectedFrameCount: Int64((durationSeconds * 16_000).rounded()))
        guard !spans.isEmpty else { throw TranscriptionError.invalidVoiceActivity }
        func validate(_ segments: [WhisperTranscribedSegment]) throws {
            try Task.checkCancellation()
            guard !segments.isEmpty, segments.allSatisfy({ segment in
                segment.startSeconds.isFinite && segment.endSeconds.isFinite && segment.startSeconds >= 0 &&
                segment.startSeconds <= durationSeconds && segment.endSeconds >= segment.startSeconds &&
                segment.endSeconds <= durationSeconds + 0.05 &&
                    !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                    spans.contains(where: {
                        segment.startSeconds >= Double($0.startFrame) / 16_000 - 0.000_1 &&
                        segment.endSeconds <= Double($0.endFrame) / 16_000 + 0.05
                    })
            }) else { throw TranscriptionError.invalidEngineOutput }
        }
        try Task.checkCancellation()
        var result = try await client.transcribe(mediaURL: mediaURL, languageMode: languageMode,
            promptContext: promptContext, speechSpans: spans)
        try validate(result)
        if WhisperDecodingPolicy.hasRepetitionLoop(result) {
            try Task.checkCancellation()
            result = try await client.transcribe(mediaURL: mediaURL, languageMode: languageMode,
                promptContext: "", speechSpans: spans)
            try validate(result)
            guard !WhisperDecodingPolicy.hasRepetitionLoop(result) else { throw TranscriptionError.repetitionLoop }
        }
        return result
    }

    nonisolated static func validateVoiceActivity(_ detection: VoiceActivityDetection, expectedFrameCount: Int64) throws {
        guard expectedFrameCount > 0, expectedFrameCount <= 16_000 * 30,
              detection.frameCount == expectedFrameCount, detection.spans.count <= 128 else {
            throw TranscriptionError.invalidVoiceActivity
        }
        var previousEnd: Int64 = 0
        for span in detection.spans {
            guard span.startFrame >= previousEnd, span.endFrame > span.startFrame,
                  span.endFrame <= expectedFrameCount else { throw TranscriptionError.invalidVoiceActivity }
            previousEnd = span.endFrame
        }
    }

    nonisolated static func validatePreparedAudio(_ prepared: PreparedMeetingAudio, meetingID: String, rootDirectory: URL) throws {
        guard prepared.durationSeconds.isFinite, prepared.durationSeconds > 0, prepared.durationSeconds <= 14_400,
              !prepared.windows.isEmpty, prepared.windows.count <= 480 else { throw TranscriptionError.invalidResume }
        let totalFrames = Int64((prepared.durationSeconds * 16_000).rounded())
        let root = rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
        var folder: String?
        var cursor: Int64 = 0
        for (index, window) in prepared.windows.enumerated() {
            try Task.checkCancellation()
            let components = window.relativePath.split(separator: "/").map(String.init)
            guard components.count == 4, components[0] == "Imports", components[1] == meetingID,
                  components[2].hasPrefix("prepared-"),
                  UUID(uuidString: String(components[2].dropFirst("prepared-".count))) != nil,
                  components[3] == "window-\(index).wav",
                  folder == nil || folder == components[2],
                  window.startSeconds.isFinite, window.durationSeconds.isFinite,
                  window.durationSeconds > 0, window.durationSeconds <= 30 else { throw TranscriptionError.invalidResume }
            let startFrames = window.startSeconds * 16_000
            let durationFrames = window.durationSeconds * 16_000
            guard abs(startFrames - Double(cursor)) < 0.01,
                  abs(durationFrames - durationFrames.rounded()) < 0.01 else { throw TranscriptionError.invalidResume }
            let count = Int64(durationFrames.rounded())
            guard count > 0, cursor + count <= totalFrames,
                  index == prepared.windows.count - 1 || count == 480_000 else { throw TranscriptionError.invalidResume }
            let url = try MediaProcessingService.checkedURL(relativePath: window.relativePath, rootDirectory: root)
            guard url.path == root.appendingPathComponent(window.relativePath).standardizedFileURL.path else {
                throw TranscriptionError.invalidResume
            }
            let audio = try AVAudioFile(forReading: url)
            guard audio.length == count, audio.processingFormat.sampleRate == 16_000,
                  audio.processingFormat.channelCount == 1 else { throw TranscriptionError.invalidResume }
            folder = components[2]
            cursor += count
        }
        guard cursor == totalFrames else { throw TranscriptionError.invalidResume }
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
