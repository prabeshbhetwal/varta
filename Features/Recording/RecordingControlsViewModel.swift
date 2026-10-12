import Foundation

@MainActor
final class RecordingControlsViewModel: ObservableObject {
    @Published private(set) var snapshot = RecorderStatusSnapshot(
        state: .idle,
        meetingID: nil,
        jobID: nil,
        segmentCount: 0,
        totalRecordedSeconds: 0,
        startedAt: nil,
        onBattery: false,
        thermalState: .nominal,
        canRunHeavyProcessing: true,
        note: nil
    )

    @Published var captureMicrophone = true
    @Published var captureSystemAudio = false
    @Published var errorMessage: String?
    @Published var userMessage: String?

    private let recorderCoordinator: RecorderCoordinator
    private let settingsStore: SettingsStore?
    private let onRecordingSaved: (String?) -> Void
    private var pollingTask: Task<Void, Never>?

    init(
        recorderCoordinator: RecorderCoordinator,
        settingsStore: SettingsStore? = nil,
        onRecordingSaved: @escaping (String?) -> Void = { _ in }
    ) {
        self.recorderCoordinator = recorderCoordinator
        self.settingsStore = settingsStore
        self.onRecordingSaved = onRecordingSaved
    }

    deinit {
        pollingTask?.cancel()
    }

    func startPolling() {
        guard pollingTask == nil else {
            return
        }

        pollingTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 150_000_000)
            while !Task.isCancelled {
                await self.refreshSnapshot()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func refreshSnapshot() async {
        let latest = await recorderCoordinator.currentSnapshot()
        if snapshot != latest { snapshot = latest }
        while let completion = await recorderCoordinator.takeCompletedRecording() {
            userMessage = "Recording saved locally and added to recordings."
            onRecordingSaved(completion.meetingID)
        }
    }

    func startMicrophoneRecording() {
        captureMicrophone = true
        captureSystemAudio = false
        startRecording()
    }

    func restoreInterruptedRecording(jobID: String, storageService: StorageService) async {
        guard snapshot.state == .idle || snapshot.state == .failed || snapshot.state == .completed else { return }
        do {
            errorMessage = nil
            let checkpoint = try await Checkpointer(storageService: storageService).latestRecordingCheckpoint(jobID: jobID)
            guard let meetingID = try await storageService.job(id: jobID)?.meetingID else { throw RecorderCoordinator.RecorderError.noCoordinatorState }
            let files = try await storageService.importedMedia(for: meetingID)
            let sources = Self.recoveredAudioSources(checkpoint: checkpoint, media: files, jobID: jobID)
            captureMicrophone = sources.microphone
            captureSystemAudio = sources.system
            try await recorderCoordinator.restoreInterruptedRecording(jobID: jobID)
            await refreshSnapshot()
            userMessage = "Recording session recovered. Choose audio sources, then Resume or Stop; capture remains paused."
        } catch {
            errorMessage = "Recording recovery failed: \(error.localizedDescription)"
        }
    }

    nonisolated static func recoveredAudioSources(checkpoint: RecordingCheckpointPayload?, media: [ImportedMediaRecord], jobID: String) -> (microphone: Bool, system: Bool) {
        let owned = media.filter { $0.relativePath.contains(jobID) || checkpoint?.segmentRelativePaths.contains($0.relativePath) == true }
        func containsSource(_ source: String) -> Bool {
            owned.contains { record in
                record.source == source || (record.source == nil && URL(fileURLWithPath: record.relativePath).deletingPathExtension().lastPathComponent.hasSuffix("-" + source))
            }
        }
        return (checkpoint?.captureMicrophone ?? containsSource("microphone"), checkpoint?.captureSystemAudio ?? containsSource("system"))
    }

    func startRecording() {
        guard snapshot.state == .idle || snapshot.state == .failed || snapshot.state == .completed else {
            return
        }

        Task {
            do {
                errorMessage = nil
                userMessage = "Starting recording…"
                let prefix = try await settingsStore?.string(for: .defaultMeetingTitlePrefix)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = prefix.flatMap { $0.isEmpty ? nil : $0 + " " + Date().formatted(date: .numeric, time: .shortened) }
                try await recorderCoordinator.startRecording(
                    configuration: RecorderStartConfiguration(
                        meetingTitle: title,
                        captureMicrophone: captureMicrophone,
                        captureSystemAudio: captureSystemAudio
                    )
                )
                await refreshSnapshot()
                if snapshot.state == .recording {
                    userMessage = nil
                } else if snapshot.state == .failed {
                    userMessage = nil
                    errorMessage = snapshot.note ?? "Recording failed to start."
                }
            } catch {
                await refreshSnapshot()
                userMessage = nil
                errorMessage = friendlyMessage(for: error)
            }
        }
    }

    func pauseRecording() {
        Task {
            await recorderCoordinator.pauseRecording()
            await refreshSnapshot()
            userMessage = snapshot.state == .paused ? "Recording paused." : nil
        }
    }

    func resumeRecording() {
        guard captureMicrophone || captureSystemAudio else {
            errorMessage = RecorderCoordinator.RecorderError.missingAudioInput.localizedDescription
            return
        }
        Task {
            do {
                errorMessage = nil
                userMessage = "Resuming recording…"
                try await recorderCoordinator.resumeRecording(
                    captureMicrophone: captureMicrophone,
                    captureSystemAudio: captureSystemAudio
                )
                await refreshSnapshot()
                userMessage = nil
            } catch {
                await refreshSnapshot()
                userMessage = nil
                errorMessage = friendlyMessage(for: error)
            }
        }
    }

    func stopRecording() {
        errorMessage = nil
        userMessage = "Saving recording…"

        Task {
            let beforeStop = await recorderCoordinator.currentSnapshot()
            snapshot = beforeStop
            guard beforeStop.state == .recording || beforeStop.state == .paused || beforeStop.state == .starting else {
                userMessage = nil
                return
            }

            await recorderCoordinator.stopRecording()
            await refreshSnapshot()
            let latest = snapshot

            if latest.state == .completed {
                userMessage = "Recording saved locally and added to recordings."
            } else if latest.state == .failed {
                userMessage = nil
                errorMessage = latest.note ?? "Recording failed. Check permissions and try again."
            }
        }
    }

    private func friendlyMessage(for error: Error) -> String {
        let raw = error.localizedDescription
        if raw.localizedCaseInsensitiveContains("screen recording permission") {
            return "System audio capture needs Screen Recording permission. Grant permission in Settings and try again."
        }
        if raw.localizedCaseInsensitiveContains("microphone") {
            return "Microphone capture failed. Check microphone permission and input device."
        }
        return raw
    }
}
