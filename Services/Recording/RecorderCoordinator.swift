import CoreGraphics
@preconcurrency import CoreMedia
import Foundation

actor RecorderCoordinator {
    enum RecorderError: Error {
        case missingAudioInput
        case noCoordinatorState
        case invalidRecordingConfiguration
    }

    private struct ActiveSession {
        var meetingID: String
        var jobID: String
        var startedAt: Date
        var captureMicrophone: Bool
        var captureSystemAudio: Bool
        var totalRecordedSeconds: Double
        var segmentRelativePaths: [String]
        var currentSegmentIndex: Int
        var currentSegmentStartedAt: Date?
    }

    private enum ResumeIntent {
        case none
        case wake
    }

    private enum AudioSource: String, Sendable {
        case microphone
        case system
    }

    private let storageService: StorageService
    private let jobQueue: JobQueue
    private let checkpointer: Checkpointer
    private let memoryManager: MemoryManager

    private var writersBySource: [AudioSource: RecordingWriter] = [:]
    private var microphoneCapture: MicrophoneCapture?
    private var systemAudioCapture: SystemAudioCapture?

    private var state: RecorderState = .idle
    private var note: String?
    private var thermalState: ProcessInfo.ThermalState = .nominal
    private var onBattery = false

    private var activeSession: ActiveSession?
    private var checkpointTask: Task<Void, Never>?
    private var resumeIntent: ResumeIntent = .none
    private var isHandlingWriterFailure = false
    private var hasLoggedFormatMismatch = false
    private var hasLoggedInvalidBuffer = false

    init(
        storageService: StorageService,
        jobQueue: JobQueue,
        checkpointer: Checkpointer,
        memoryManager: MemoryManager
    ) {
        self.storageService = storageService
        self.jobQueue = jobQueue
        self.checkpointer = checkpointer
        self.memoryManager = memoryManager
    }

    func currentSnapshot() async -> RecorderStatusSnapshot {
        let canRunHeavy = await memoryManager.currentRuntimeMode() != .paused
        let recordedSeconds: Double
        if let activeSession {
            recordedSeconds = activeSession.totalRecordedSeconds + activeSegmentElapsedSeconds(activeSession)
        } else {
            recordedSeconds = 0
        }

        return RecorderStatusSnapshot(
            state: state,
            meetingID: activeSession?.meetingID,
            jobID: activeSession?.jobID,
            segmentCount: activeSession?.segmentRelativePaths.count ?? 0,
            totalRecordedSeconds: recordedSeconds,
            startedAt: activeSession?.startedAt,
            onBattery: onBattery,
            thermalState: thermalState,
            canRunHeavyProcessing: canRunHeavy,
            note: note
        )
    }

    func startRecording(configuration: RecorderStartConfiguration) async throws {
        guard state == .idle || state == .failed || state == .completed else {
            throw RecorderError.invalidRecordingConfiguration
        }

        guard configuration.captureMicrophone || configuration.captureSystemAudio else {
            throw RecorderError.invalidRecordingConfiguration
        }

        state = .starting
        note = "Preparing capture devices"

        do {
            let meetingID = try await resolveMeetingID(using: configuration)
            let job = try await jobQueue.beginRecordingJob(meetingID: meetingID)
            activeSession = ActiveSession(
                meetingID: meetingID,
                jobID: job.id,
                startedAt: Date(),
                captureMicrophone: configuration.captureMicrophone,
                captureSystemAudio: configuration.captureSystemAudio,
                totalRecordedSeconds: 0,
                segmentRelativePaths: [],
                currentSegmentIndex: 0,
                currentSegmentStartedAt: nil
            )
            isHandlingWriterFailure = false
            hasLoggedFormatMismatch = false
            hasLoggedInvalidBuffer = false

            try await startNewSegment(captureMicrophone: configuration.captureMicrophone, captureSystemAudio: configuration.captureSystemAudio)
            startCheckpointLoop()
            state = .recording
            note = "Recording"
        } catch {
            let failedSession = activeSession
            await stopInputsAndCloseWriter()
            await saveCheckpoint(reason: .failure)
            state = .failed
            note = "Recording start failed: \(error.localizedDescription)"
            if let failedSession {
                try? await jobQueue.failRecordingJob(jobID: failedSession.jobID, errorMessage: error.localizedDescription)
            }
            activeSession = nil
            throw error
        }
    }

    func pauseRecording(reason: RecordingCheckpointPayload.Reason = .pause) async {
        guard state == .recording else {
            return
        }

        state = .stopping
        note = reason == .sleep ? "Paused for sleep" : "Paused"

        await stopInputsAndCloseWriter()
        await saveCheckpoint(reason: reason)

        if let jobID = activeSession?.jobID {
            try? await jobQueue.pauseRecordingJob(jobID: jobID)
        }
        state = .paused
    }

    func resumeRecording(captureMicrophone: Bool? = nil, captureSystemAudio: Bool? = nil) async throws {
        guard state == .paused else {
            return
        }
        guard let activeSession else {
            throw RecorderError.noCoordinatorState
        }

        state = .starting
        note = "Resuming recording"
        let micSetting = captureMicrophone ?? activeSession.captureMicrophone
        let systemSetting = captureSystemAudio ?? activeSession.captureSystemAudio
        self.activeSession?.captureMicrophone = micSetting
        self.activeSession?.captureSystemAudio = systemSetting
        do {
            try await startNewSegment(captureMicrophone: micSetting, captureSystemAudio: systemSetting)
        } catch {
            state = .paused
            note = "Resume failed: \(error.localizedDescription)"
            throw error
        }

        try? await jobQueue.updateRecordingProgress(jobID: activeSession.jobID, progress: estimatedProgress())

        state = .recording
        note = "Recording"
    }

    func stopRecording() async {
        guard state == .recording || state == .paused else {
            return
        }

        state = .stopping
        note = "Finalizing audio"

        checkpointTask?.cancel()
        checkpointTask = nil

        await stopInputsAndCloseWriter()
        await saveCheckpoint(reason: .stop)

        guard let activeSession else {
            state = .idle
            note = nil
            return
        }

        guard !activeSession.segmentRelativePaths.isEmpty else {
            try? await jobQueue.failRecordingJob(jobID: activeSession.jobID, errorMessage: "No playable audio was captured.")
            self.activeSession = nil
            state = .failed
            note = "No playable audio was captured. Check microphone input and try again."
            return
        }

        try? await jobQueue.completeRecordingJob(jobID: activeSession.jobID)

        self.activeSession = nil
        state = .completed
        note = "Recording saved"
        isHandlingWriterFailure = false
        hasLoggedFormatMismatch = false
        hasLoggedInvalidBuffer = false
    }

    func handleWillSleep() async {
        guard state == .recording else {
            return
        }

        resumeIntent = .wake
        await pauseRecording(reason: .sleep)
    }

    func handleDidWake() async {
        guard resumeIntent == .wake else {
            return
        }

        resumeIntent = .none
        try? await resumeRecording()
        await saveCheckpoint(reason: .wakeResume)
    }

    func handleThermalStateChange(_ state: ProcessInfo.ThermalState) {
        thermalState = state
        if state == .critical {
            note = "Thermal critical: heavy processing paused, recording continues"
        } else if self.state == .recording {
            note = "Recording"
        }
    }

    func handlePowerStateChange(onBattery: Bool) {
        self.onBattery = onBattery
        if onBattery, state == .recording {
            note = "Recording on battery: concurrency reduced"
        } else if state == .recording {
            note = "Recording"
        }
    }

    private func resolveMeetingID(using configuration: RecorderStartConfiguration) async throws -> String {
        if let meetingID = configuration.meetingID {
            return meetingID
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let title = configuration.meetingTitle ?? "Recording \(formatter.string(from: Date()))"
        return try await storageService.createMeeting(title: title, languageMode: .mixed)
    }

    private func startNewSegment(captureMicrophone: Bool, captureSystemAudio: Bool) async throws {
        guard var activeSession else {
            throw RecorderError.noCoordinatorState
        }

        let segmentIndex = activeSession.currentSegmentIndex

        var micCapture: AVFoundationMicrophoneCapture?
        var systemCapture: ScreenCaptureSystemAudioCapture?
        var localWriters: [AudioSource: RecordingWriter] = [:]

        do {
            if captureMicrophone {
                let micWriter = RecordingWriter()
                let micDestination = try await makeRecordingFileURL(
                    meetingID: activeSession.meetingID,
                    segmentIndex: segmentIndex,
                    source: .microphone
                )
                try micWriter.startWriting(to: micDestination)
                localWriters[.microphone] = micWriter

                let mic = AVFoundationMicrophoneCapture()
                mic.onSampleBuffer = { [weak self, micWriter] sampleBuffer in
                    do {
                        try micWriter.append(sampleBuffer: sampleBuffer)
                    } catch RecordingWriter.WriterError.inputNotReady {
                        // Backpressure drop keeps in-memory usage bounded.
                    } catch RecordingWriter.WriterError.unsupportedAudioFormat(_) {
                        Task { await self?.handleIncompatibleAudioFormat(for: .microphone) }
                    } catch RecordingWriter.WriterError.invalidSampleBuffer(_) {
                        Task { await self?.handleInvalidSampleBuffer(for: .microphone) }
                    } catch {
                        Task { await self?.handleWriterFailure(errorDescription: "[microphone] \(error.localizedDescription)") }
                    }
                }

                try await mic.start()
                micCapture = mic
            }

            if captureSystemAudio {
                guard CGPreflightScreenCaptureAccess() else {
                    throw NSError(
                        domain: "Varta.Recording",
                        code: 1302,
                        userInfo: [NSLocalizedDescriptionKey: "Screen Recording permission is required for system audio capture"]
                    )
                }

                let systemWriter = RecordingWriter()
                let systemDestination = try await makeRecordingFileURL(
                    meetingID: activeSession.meetingID,
                    segmentIndex: segmentIndex,
                    source: .system
                )
                try systemWriter.startWriting(to: systemDestination)
                localWriters[.system] = systemWriter

                let system = ScreenCaptureSystemAudioCapture()
                system.onSampleBuffer = { [weak self, systemWriter] sampleBuffer in
                    do {
                        try systemWriter.append(sampleBuffer: sampleBuffer)
                    } catch RecordingWriter.WriterError.inputNotReady {
                        // Backpressure drop keeps in-memory usage bounded.
                    } catch RecordingWriter.WriterError.unsupportedAudioFormat(_) {
                        Task { await self?.handleIncompatibleAudioFormat(for: .system) }
                    } catch RecordingWriter.WriterError.invalidSampleBuffer(_) {
                        Task { await self?.handleInvalidSampleBuffer(for: .system) }
                    } catch {
                        Task { await self?.handleWriterFailure(errorDescription: "[system] \(error.localizedDescription)") }
                    }
                }

                try await system.start()
                systemCapture = system
            }
        } catch {
            if let micCapture {
                await micCapture.stop()
            }
            if let systemCapture {
                await systemCapture.stop()
            }
            for (_, localWriter) in localWriters {
                do {
                    _ = try await localWriter.finishWriting()
                } catch {
                    // Best-effort cleanup for partially started segment.
                }
            }
            throw error
        }

        self.writersBySource = localWriters
        microphoneCapture = micCapture
        systemAudioCapture = systemCapture

        activeSession.currentSegmentIndex += 1
        activeSession.currentSegmentStartedAt = Date()
        self.activeSession = activeSession
    }

    private func handleWriterFailure(errorDescription: String) async {
        guard state == .recording || state == .starting else {
            return
        }
        guard !isHandlingWriterFailure else {
            return
        }
        isHandlingWriterFailure = true

        state = .failed
        checkpointTask?.cancel()
        checkpointTask = nil

        await stopInputsAndCloseWriter()
        await saveCheckpoint(reason: .failure)
        note = "Writer error: \(errorDescription)"
        if let jobID = activeSession?.jobID {
            try? await jobQueue.failRecordingJob(jobID: jobID, errorMessage: errorDescription)
        }
        isHandlingWriterFailure = false
    }

    private func handleIncompatibleAudioFormat(for source: AudioSource) async {
        guard !hasLoggedFormatMismatch else {
            return
        }

        hasLoggedFormatMismatch = true
        note = "[\(source.rawValue)] Audio format mismatch detected; dropping mismatched buffers."
    }

    private func handleInvalidSampleBuffer(for source: AudioSource) async {
        guard !hasLoggedInvalidBuffer else {
            return
        }
        hasLoggedInvalidBuffer = true
        note = "[\(source.rawValue)] Capture produced an invalid sample buffer; continuing."
    }

    private func stopInputsAndCloseWriter() async {
        await microphoneCapture?.stop()
        await systemAudioCapture?.stop()
        microphoneCapture = nil
        systemAudioCapture = nil

        guard !writersBySource.isEmpty else {
            return
        }
        guard let meetingID = activeSession?.meetingID else {
            writersBySource = [:]
            return
        }

        var maxSegmentDuration: Double = 0
        var registeredPaths: [String] = []

        for (source, writer) in writersBySource {
            do {
                let segmentDuration = try await writer.finishWriting()
                maxSegmentDuration = max(maxSegmentDuration, segmentDuration)

                if let outputURL = writer.outputURL {
                    guard hasPersistedAudioContent(at: outputURL, durationSeconds: segmentDuration) else {
                        if source == .system {
                            note = "System audio stream produced no playable samples for this segment."
                        }
                        continue
                    }

                    let appSupport = await storageService.appSupportDirectory()
                    let relativePath = outputURL.path.replacingOccurrences(of: appSupport.path + "/", with: "")
                    registeredPaths.append(relativePath)

                    try? await storageService.registerImportedMedia(
                        meetingID: meetingID,
                        relativePath: relativePath,
                        originalFilename: outputURL.lastPathComponent,
                        format: "m4a",
                        durationSeconds: segmentDuration
                    )
                }
            } catch {
                note = "Failed to finalize writer: \(error.localizedDescription)"
            }
        }

        if var activeSession {
            activeSession.totalRecordedSeconds += maxSegmentDuration
            activeSession.currentSegmentStartedAt = nil
            activeSession.segmentRelativePaths.append(contentsOf: registeredPaths)
            self.activeSession = activeSession
        }

        self.writersBySource = [:]
    }

    private func hasPersistedAudioContent(at url: URL, durationSeconds: Double) -> Bool {
        guard durationSeconds > 0.05 else {
            return false
        }

        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? NSNumber
        else {
            return false
        }

        return size.intValue > 1024
    }

    private func startCheckpointLoop() {
        checkpointTask?.cancel()

        checkpointTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let nanos: UInt64 = await self.onBattery ? 20_000_000_000 : 10_000_000_000
                do {
                    try await Task.sleep(nanoseconds: nanos)
                } catch {
                    return
                }
                await self.saveCheckpoint(reason: .periodic)

                if let jobID = await self.activeSession?.jobID {
                    try? await self.jobQueue.updateRecordingProgress(jobID: jobID, progress: await self.estimatedProgress())
                }
            }
        }
    }

    private func saveCheckpoint(reason: RecordingCheckpointPayload.Reason) async {
        guard let activeSession else {
            return
        }

        let payload = RecordingCheckpointPayload(
            meetingID: activeSession.meetingID,
            segmentRelativePaths: activeSession.segmentRelativePaths,
            totalRecordedSeconds: activeSession.totalRecordedSeconds + activeSegmentElapsedSeconds(activeSession),
            lastSegmentDurationSeconds: activeSegmentElapsedSeconds(activeSession),
            reason: reason,
            recordedAt: Date()
        )

        try? await checkpointer.saveRecordingCheckpoint(jobID: activeSession.jobID, payload: payload)
    }

    private func makeRecordingFileURL(meetingID: String, segmentIndex: Int, source: AudioSource) async throws -> URL {
        let appSupport = await storageService.appSupportDirectory()
        let folder = appSupport
            .appendingPathComponent("Recordings", isDirectory: true)
            .appendingPathComponent(meetingID, isDirectory: true)

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let fileName = "segment-\(segmentIndex)-\(source.rawValue)-\(stamp).m4a"
        return folder.appendingPathComponent(fileName)
    }

    private func estimatedProgress() -> Double {
        guard let activeSession else {
            return 0
        }

        let target: Double = 4 * 60 * 60
        let current = activeSession.totalRecordedSeconds + activeSegmentElapsedSeconds(activeSession)
        return min(current / target, 0.999)
    }

    private func activeSegmentElapsedSeconds(_ activeSession: ActiveSession) -> Double {
        guard let started = activeSession.currentSegmentStartedAt, state == .recording || state == .starting else {
            return 0
        }

        return max(Date().timeIntervalSince(started), 0)
    }
}
