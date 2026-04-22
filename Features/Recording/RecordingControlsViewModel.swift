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
    @Published var captureSystemAudio = true
    @Published var errorMessage: String?
    @Published var userMessage: String?

    private let recorderCoordinator: RecorderCoordinator
    private let onRecordingSaved: (String?) -> Void
    private var pollingTask: Task<Void, Never>?

    init(
        recorderCoordinator: RecorderCoordinator,
        onRecordingSaved: @escaping (String?) -> Void = { _ in }
    ) {
        self.recorderCoordinator = recorderCoordinator
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
                let snapshot = await recorderCoordinator.currentSnapshot()
                if self.snapshot != snapshot {
                    self.snapshot = snapshot
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func startRecording() {
        Task {
            do {
                errorMessage = nil
                userMessage = "Starting recording…"
                try await recorderCoordinator.startRecording(
                    configuration: RecorderStartConfiguration(
                        captureMicrophone: captureMicrophone,
                        captureSystemAudio: captureSystemAudio
                    )
                )
                userMessage = "Recording in progress."
            } catch {
                Task { @MainActor in
                    self.userMessage = nil
                    self.errorMessage = friendlyMessage(for: error)
                }
            }
        }
    }

    func pauseRecording() {
        Task {
            await recorderCoordinator.pauseRecording()
        }
    }

    func resumeRecording() {
        Task {
            do {
                errorMessage = nil
                userMessage = "Resuming recording…"
                try await recorderCoordinator.resumeRecording(
                    captureMicrophone: captureMicrophone,
                    captureSystemAudio: captureSystemAudio
                )
                userMessage = "Recording resumed."
            } catch {
                Task { @MainActor in
                    self.userMessage = nil
                    self.errorMessage = friendlyMessage(for: error)
                }
            }
        }
    }

    func stopRecording() {
        let stateBeforeStop = snapshot.state
        guard stateBeforeStop == .recording || stateBeforeStop == .paused || stateBeforeStop == .starting else {
            return
        }

        let savedMeetingID = snapshot.meetingID
        errorMessage = nil
        userMessage = "Saving recording…"

        Task {
            await recorderCoordinator.stopRecording()
            let latest = await recorderCoordinator.currentSnapshot()

            await MainActor.run {
                if latest.state == .idle {
                    self.userMessage = "Recording saved locally and added to meetings."
                    self.onRecordingSaved(savedMeetingID)
                } else if latest.state == .failed {
                    self.userMessage = nil
                    self.errorMessage = latest.note ?? "Recording failed. Check permissions and try again."
                }
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
