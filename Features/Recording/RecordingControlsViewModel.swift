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

    func refreshSnapshot() async {
        snapshot = await recorderCoordinator.currentSnapshot()
    }

    func startMicrophoneRecording() {
        captureMicrophone = true
        captureSystemAudio = false
        startRecording()
    }

    func startRecording() {
        guard snapshot.state == .idle || snapshot.state == .failed || snapshot.state == .completed else {
            return
        }

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

            let savedMeetingID = beforeStop.meetingID
            await recorderCoordinator.stopRecording()
            let latest = await recorderCoordinator.currentSnapshot()
            snapshot = latest

            if latest.state == .completed {
                userMessage = "Recording saved locally and added to recordings."
                onRecordingSaved(savedMeetingID)
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
