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

    private let recorderCoordinator: RecorderCoordinator
    private var pollingTask: Task<Void, Never>?

    init(recorderCoordinator: RecorderCoordinator) {
        self.recorderCoordinator = recorderCoordinator
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
            while !Task.isCancelled {
                let snapshot = await recorderCoordinator.currentSnapshot()
                await MainActor.run {
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
                try await recorderCoordinator.startRecording(
                    configuration: RecorderStartConfiguration(
                        captureMicrophone: captureMicrophone,
                        captureSystemAudio: captureSystemAudio
                    )
                )
            } catch {
                errorMessage = error.localizedDescription
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
                try await recorderCoordinator.resumeRecording(
                    captureMicrophone: captureMicrophone,
                    captureSystemAudio: captureSystemAudio
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func stopRecording() {
        Task {
            await recorderCoordinator.stopRecording()
        }
    }
}
