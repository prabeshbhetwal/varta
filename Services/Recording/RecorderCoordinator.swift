import CoreGraphics
@preconcurrency import CoreMedia
import Foundation

actor RecorderCoordinator {
    enum RecorderError: LocalizedError {
        case missingAudioInput
        case noCoordinatorState
        case invalidRecordingConfiguration

        var errorDescription: String? {
            switch self {
            case .missingAudioInput: return "Choose at least one audio source before starting or resuming."
            case .noCoordinatorState: return "No recoverable recording session is available."
            case .invalidRecordingConfiguration: return "Recording cannot start or resume in its current state or beyond its four-hour limit."
            }
        }
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
        var runOriginPresentationSeconds: Double?
        var runTimelineBaseSeconds: Double = 0
        var lastFinalisedDurationSeconds: Double = 0
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
    private var routersBySource: [AudioSource: RecordingWriterRouter] = [:]
    private var isRotatingChunk = false
    private var captureClock: RecordingCaptureClock?
    private var pendingWriterFailure: String?
    private var microphoneCapture: MicrophoneCapture?
    private var systemAudioCapture: SystemAudioCapture?

    private var state: RecorderState = .idle
    private var note: String?
    private var thermalState: ProcessInfo.ThermalState = .nominal
    private var onBattery = false

    private var activeSession: ActiveSession?
    private var completedSession: ActiveSession?
    private var pendingCompletions: [(meetingID: String, jobID: String)] = []
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
        let session = activeSession ?? (state == .completed ? completedSession : nil)
        let recordedSeconds: Double
        if let activeSession {
            recordedSeconds = activeSession.totalRecordedSeconds + activeSegmentElapsedSeconds(activeSession)
        } else {
            recordedSeconds = session?.totalRecordedSeconds ?? 0
        }

        return RecorderStatusSnapshot(
            state: state,
            meetingID: session?.meetingID,
            jobID: session?.jobID,
            segmentCount: session?.segmentRelativePaths.count ?? 0,
            totalRecordedSeconds: recordedSeconds,
            startedAt: session?.startedAt,
            onBattery: onBattery,
            thermalState: thermalState,
            canRunHeavyProcessing: canRunHeavy,
            note: note
        )
    }

    func takeCompletedRecording() -> (meetingID: String, jobID: String)? {
        guard !pendingCompletions.isEmpty else { return nil }
        return pendingCompletions.removeFirst()
    }

    func restoreInterruptedRecording(jobID: String) async throws {
        guard state == .idle || state == .failed || state == .completed else { throw RecorderError.noCoordinatorState }
        completedSession = nil
        captureClock = nil
        state = .starting
        do {
        guard let job = try await jobQueue.recordingJob(id: jobID), job.jobType == .recording,
              job.status == .paused || job.status == .failed, let meetingID = job.meetingID else {
            throw RecorderError.noCoordinatorState
        }
        let payload = try await checkpointer.latestRecordingCheckpoint(jobID: jobID)
        let records = try await storageService.importedMedia(for: meetingID)
        let owned = records.filter { $0.relativePath.contains(jobID) || payload?.segmentRelativePaths.contains($0.relativePath) == true }
        let root = await storageService.appSupportDirectory()
        for record in owned { _ = try MediaProcessingService.checkedURL(relativePath: record.relativePath, rootDirectory: root) }
        let total = owned.compactMap { record -> Double? in
            guard let offset = record.timelineOffsetSeconds, let duration = record.durationSeconds else { return nil }
            return offset + duration
        }.max() ?? payload?.totalRecordedSeconds ?? 0
        guard total.isFinite, total >= 0, total <= 14_400 else { throw RecorderError.invalidRecordingConfiguration }
        activeSession = ActiveSession(meetingID: meetingID, jobID: jobID, startedAt: job.createdAt,
            captureMicrophone: payload?.captureMicrophone ?? owned.contains(where: { $0.source == "microphone" }),
            captureSystemAudio: payload?.captureSystemAudio ?? owned.contains(where: { $0.source == "system" }),
            totalRecordedSeconds: total, segmentRelativePaths: owned.map(\.relativePath),
            currentSegmentIndex: max(payload?.nextSegmentIndex ?? 0, (owned.compactMap(\.segmentIndex).max() ?? -1) + 1),
            currentSegmentStartedAt: nil)
        state = .paused
        note = "Recovered \(owned.count) completed audio files. Resume recording explicitly when ready."
        } catch {
            state = .failed
            note = "Recording recovery failed: \(error.localizedDescription)"
            throw error
        }
    }

    func startRecording(configuration: RecorderStartConfiguration) async throws {
        guard state == .idle || state == .failed || state == .completed else {
            throw RecorderError.invalidRecordingConfiguration
        }

        guard configuration.captureMicrophone || configuration.captureSystemAudio else {
            throw RecorderError.missingAudioInput
        }

        completedSession = nil
        captureClock = nil
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
            pendingWriterFailure = nil

            // Persist source choices before opening devices; the first chunk may never finish.
            try await saveCheckpoint(reason: .periodic)
            try await startNewSegment(captureMicrophone: configuration.captureMicrophone, captureSystemAudio: configuration.captureSystemAudio)
            startCheckpointLoop()
            state = .recording
            note = "Recording"
        } catch {
            let failedSession = activeSession
            var failure = error.localizedDescription
            do {
                try await stopInputsAndCloseWriter()
                try await saveCheckpoint(reason: .failure)
            } catch { failure += "; recovery persistence: \(error.localizedDescription)" }
            state = .stopping
            note = "Recording start failed: \(failure)"
            if let failedSession {
                do { try await jobQueue.failRecordingJob(jobID: failedSession.jobID, errorMessage: failure) }
                catch { note = "\(note ?? failure); job persistence: \(error.localizedDescription)" }
            }
            activeSession = nil
            state = .failed
            throw error
        }
    }

    func pauseRecording(reason: RecordingCheckpointPayload.Reason = .pause) async {
        await waitForRotation()
        guard state == .recording else {
            return
        }

        state = .stopping
        note = reason == .sleep ? "Paused for sleep" : "Paused"

        do {
            try await stopInputsAndCloseWriter()
            try await saveCheckpoint(reason: reason)
            if let jobID = activeSession?.jobID { try await jobQueue.pauseRecordingJob(jobID: jobID) }
            state = .paused
        } catch {
            await failPersistence(error)
        }
    }

    func resumeRecording(captureMicrophone: Bool? = nil, captureSystemAudio: Bool? = nil) async throws {
        guard state == .paused else {
            return
        }
        guard let activeSession else {
            throw RecorderError.noCoordinatorState
        }
        guard activeSession.totalRecordedSeconds < 14_400 else {
            throw RecorderError.invalidRecordingConfiguration
        }
        let micSetting = captureMicrophone ?? activeSession.captureMicrophone
        let systemSetting = captureSystemAudio ?? activeSession.captureSystemAudio
        guard micSetting || systemSetting else {
            note = RecorderError.missingAudioInput.localizedDescription
            throw RecorderError.missingAudioInput
        }

        state = .starting
        note = "Resuming recording"
        pendingWriterFailure = nil
        self.activeSession?.captureMicrophone = micSetting
        self.activeSession?.captureSystemAudio = systemSetting
        do {
            try await saveCheckpoint(reason: .wakeResume)
            try await startNewSegment(captureMicrophone: micSetting, captureSystemAudio: systemSetting)
        } catch {
            do { try await stopInputsAndCloseWriter() }
            catch { note = "Resume failed; finalisation failed: \(error.localizedDescription)" }
            state = .paused
            note = "\(note ?? "Resume failed"): \(error.localizedDescription)"
            throw error
        }

        do {
            try await jobQueue.updateRecordingProgress(jobID: activeSession.jobID, progress: estimatedProgress())
            try await saveCheckpoint(reason: .wakeResume)
        } catch {
            await failPersistence(error)
            throw error
        }

        state = .recording
        note = "Recording"
        startCheckpointLoop()
    }

    func stopRecording() async {
        await waitForRotation()
        guard state == .recording || state == .paused else {
            return
        }

        state = .stopping
        note = "Finalizing audio"

        checkpointTask?.cancel()
        checkpointTask = nil

        do {
            try await stopInputsAndCloseWriter()
            try await saveCheckpoint(reason: .stop)
        } catch {
            await failPersistence(error)
            return
        }

        guard let activeSession else {
            state = .idle
            note = nil
            return
        }

        guard !activeSession.segmentRelativePaths.isEmpty else {
            do { try await jobQueue.failRecordingJob(jobID: activeSession.jobID, errorMessage: "No playable audio was captured.") }
            catch { await failPersistence(error); return }
            self.activeSession = nil
            state = .failed
            note = "No playable audio was captured. Check microphone input and try again."
            return
        }

        do { try await jobQueue.completeRecordingJob(jobID: activeSession.jobID) }
        catch { await failPersistence(error); return }

        completedSession = activeSession
        pendingCompletions.append((activeSession.meetingID, activeSession.jobID))
        self.activeSession = nil
        state = .completed
        note = "Recording saved"
        isHandlingWriterFailure = false
        hasLoggedFormatMismatch = false
        hasLoggedInvalidBuffer = false
    }

    func stopRecordingAtDurationLimitIfNeeded() async -> Bool {
        guard state == .recording || state == .paused,
              captureClock?.hasReachedLimit() == true || (activeSession?.totalRecordedSeconds ?? 0) >= 14_400 else { return false }
        await stopRecording()
        return true
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
        do { try await resumeRecording() }
        catch { note = "Wake resume failed: \(error.localizedDescription)" }
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
        let clock = RecordingCaptureClock(durationLimit: max(0, 14_400 - activeSession.totalRecordedSeconds))

        var micCapture: AVFoundationMicrophoneCapture?
        var systemCapture: ScreenCaptureSystemAudioCapture?
        var localWriters: [AudioSource: RecordingWriter] = [:]
        var localRouters: [AudioSource: RecordingWriterRouter] = [:]

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
                let router = RecordingWriterRouter(writer: micWriter, captureClock: clock)
                localRouters[.microphone] = router

                let mic = AVFoundationMicrophoneCapture()
                mic.onSampleBuffer = { [weak self, router] sampleBuffer in
                    do {
                        try router.append(sampleBuffer: sampleBuffer)
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
                let router = RecordingWriterRouter(writer: systemWriter, captureClock: clock)
                localRouters[.system] = router

                let system = ScreenCaptureSystemAudioCapture()
                system.onSampleBuffer = { [weak self, router] sampleBuffer in
                    do {
                        try router.append(sampleBuffer: sampleBuffer)
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
        self.routersBySource = localRouters
        self.captureClock = clock
        microphoneCapture = micCapture
        systemAudioCapture = systemCapture

        activeSession.currentSegmentIndex += 1
        activeSession.currentSegmentStartedAt = Date()
        activeSession.runOriginPresentationSeconds = nil
        activeSession.runTimelineBaseSeconds = activeSession.totalRecordedSeconds
        self.activeSession = activeSession
        if let pendingWriterFailure {
            self.pendingWriterFailure = nil
            throw NSError(domain: "Varta.Recording", code: 1304,
                userInfo: [NSLocalizedDescriptionKey: pendingWriterFailure])
        }
    }

    private func handleWriterFailure(errorDescription: String) async {
        if state == .starting { pendingWriterFailure = errorDescription; return }
        await waitForRotation()
        guard state == .recording else {
            return
        }
        guard !isHandlingWriterFailure else {
            return
        }
        isHandlingWriterFailure = true

        state = .stopping
        checkpointTask?.cancel()
        checkpointTask = nil

        note = "Writer error: \(errorDescription)"
        do {
            try await stopInputsAndCloseWriter()
            try await saveCheckpoint(reason: .failure)
        } catch { note = "Writer error: \(errorDescription); recovery persistence: \(error.localizedDescription)" }
        if let jobID = activeSession?.jobID {
            do { try await jobQueue.failRecordingJob(jobID: jobID, errorMessage: note ?? errorDescription) }
            catch { note = "\(note ?? errorDescription); job persistence: \(error.localizedDescription)" }
        }
        state = .failed
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

    private func stopInputsAndCloseWriter() async throws {
        await microphoneCapture?.stop()
        await systemAudioCapture?.stop()
        microphoneCapture = nil
        systemAudioCapture = nil
        for router in routersBySource.values { router.replace(with: nil) }
        routersBySource = [:]
        let oldWriters = writersBySource
        self.writersBySource = [:]
        try await finalise(oldWriters, segmentIndex: max(0, (activeSession?.currentSegmentIndex ?? 1) - 1))
        activeSession?.currentSegmentStartedAt = nil
    }

    private func finalise(_ writers: [AudioSource: RecordingWriter], segmentIndex: Int) async throws {
        guard let session = activeSession else { return }
        var finished: [(AudioSource, URL, RecordingWriter.FinishedSegment)] = []
        var failures: [String] = []
        for (source, writer) in writers {
            do {
                let result = try await writer.finishSegment()
                guard let output = writer.outputURL,
                      hasPersistedAudioContent(at: output, durationSeconds: result.durationSeconds) else { continue }
                finished.append((source, output, result))
            } catch { failures.append("\(source.rawValue): \(error.localizedDescription)") }
        }
        let firstPTS = finished.compactMap { $0.2.firstPresentationTimeSeconds }.min()
        activeSession?.lastFinalisedDurationSeconds = finished.map { $0.2.durationSeconds }.max() ?? 0
        if activeSession?.runOriginPresentationSeconds == nil { activeSession?.runOriginPresentationSeconds = firstPTS }
        let origin = activeSession?.runOriginPresentationSeconds ?? firstPTS ?? 0
        let root = await storageService.appSupportDirectory()
        for (source, outputURL, result) in finished {
            do {
                let offset = session.runTimelineBaseSeconds + (result.firstPresentationTimeSeconds ?? origin) - origin
                guard offset.isFinite, offset >= 0, result.durationSeconds.isFinite,
                      offset + result.durationSeconds <= 14_400.001 else {
                    throw RecorderError.invalidRecordingConfiguration
                }
                let relativePath = String(outputURL.path.dropFirst(root.path.count + 1))
                try await storageService.registerImportedMedia(meetingID: session.meetingID,
                    relativePath: relativePath, originalFilename: outputURL.lastPathComponent,
                    format: "m4a", durationSeconds: result.durationSeconds, source: source.rawValue,
                    segmentIndex: segmentIndex, timelineOffsetSeconds: offset)
                activeSession?.segmentRelativePaths.append(relativePath)
                activeSession?.totalRecordedSeconds = max(activeSession?.totalRecordedSeconds ?? 0, offset + result.durationSeconds)
            } catch { failures.append("\(source.rawValue) persistence: \(error.localizedDescription)") }
        }
        if !failures.isEmpty {
            throw NSError(domain: "Varta.Recording", code: 1303,
                userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "; ") + ". Captured files remain on disk."])
        }
    }

    private func rotateChunk() async throws {
        guard state == .recording, !isRotatingChunk, let session = activeSession else { return }
        isRotatingChunk = true
        defer { isRotatingChunk = false }
        let index = session.currentSegmentIndex
        var newWriters: [AudioSource: RecordingWriter] = [:]
        for source in writersBySource.keys {
            let writer = RecordingWriter()
            try writer.startWriting(to: await makeRecordingFileURL(meetingID: session.meetingID, segmentIndex: index, source: source))
            newWriters[source] = writer
        }
        let oldWriters = writersBySource
        for (source, writer) in newWriters { routersBySource[source]?.replace(with: writer) }
        writersBySource = newWriters
        activeSession?.currentSegmentIndex += 1
        activeSession?.currentSegmentStartedAt = Date()
        try await finalise(oldWriters, segmentIndex: index - 1)
        try await saveCheckpoint(reason: .periodic)
        try await jobQueue.updateRecordingProgress(jobID: session.jobID, progress: estimatedProgress())
    }

    private func waitForRotation() async {
        while isRotatingChunk {
            do { try await Task.sleep(nanoseconds: 10_000_000) }
            catch { return }
        }
    }

    private func failPersistence(_ error: Error) async {
        state = .stopping
        checkpointTask?.cancel()
        checkpointTask = nil
        var message = "Recording persistence failed: \(error.localizedDescription). Captured files remain on disk."
        do { try await stopInputsAndCloseWriter() }
        catch { message += " Finalisation: \(error.localizedDescription)" }
        note = message
        if let jobID = activeSession?.jobID {
            do { try await jobQueue.failRecordingJob(jobID: jobID, errorMessage: message) }
            catch { note = "\(message) Job status could not be saved: \(error.localizedDescription)" }
        }
        state = .failed
    }

    private func hasPersistedAudioContent(at url: URL, durationSeconds: Double) -> Bool {
        guard durationSeconds.isFinite, durationSeconds > 0.05 else {
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
                if await self.stopRecordingAtDurationLimitIfNeeded() { return }
                do { try await self.rotateChunk() }
                catch { await self.failPersistence(error); return }
                if await self.stopRecordingAtDurationLimitIfNeeded() { return }
            }
        }
    }

    private func saveCheckpoint(reason: RecordingCheckpointPayload.Reason) async throws {
        guard let activeSession else {
            return
        }

        let payload = RecordingCheckpointPayload(
            meetingID: activeSession.meetingID,
            segmentRelativePaths: activeSession.segmentRelativePaths,
            totalRecordedSeconds: activeSession.totalRecordedSeconds,
            lastSegmentDurationSeconds: activeSession.lastFinalisedDurationSeconds,
            reason: reason,
            recordedAt: Date(), captureMicrophone: activeSession.captureMicrophone,
            captureSystemAudio: activeSession.captureSystemAudio, nextSegmentIndex: activeSession.currentSegmentIndex
        )

        try await checkpointer.saveRecordingCheckpoint(jobID: activeSession.jobID, payload: payload)
    }

    private func makeRecordingFileURL(meetingID: String, segmentIndex: Int, source: AudioSource) async throws -> URL {
        guard !meetingID.isEmpty, !meetingID.contains("/"), meetingID != ".", meetingID != ".." else {
            throw RecorderError.invalidRecordingConfiguration
        }
        let appSupport = await storageService.appSupportDirectory()
        let folder = appSupport
            .appendingPathComponent("Recordings", isDirectory: true)
            .appendingPathComponent(meetingID, isDirectory: true)

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let fileName = "segment-\(segmentIndex)-\(source.rawValue)-\(activeSession?.jobID ?? "unknown")-\(stamp)-\(UUID().uuidString.lowercased()).m4a"
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
