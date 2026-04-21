import SwiftUI

struct RecordingControlsView: View {
    @StateObject private var viewModel: RecordingControlsViewModel

    init(recorderCoordinator: RecorderCoordinator) {
        _viewModel = StateObject(wrappedValue: RecordingControlsViewModel(recorderCoordinator: recorderCoordinator))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Native Recording")
                .font(.title2)
                .bold()

            HStack {
                Toggle("Microphone", isOn: $viewModel.captureMicrophone)
                Toggle("System Audio", isOn: $viewModel.captureSystemAudio)
            }

            HStack(spacing: 12) {
                Button("Start") {
                    viewModel.startRecording()
                }
                .disabled(viewModel.snapshot.state == .recording || viewModel.snapshot.state == .starting)

                Button("Pause") {
                    viewModel.pauseRecording()
                }
                .disabled(viewModel.snapshot.state != .recording)

                Button("Resume") {
                    viewModel.resumeRecording()
                }
                .disabled(viewModel.snapshot.state != .paused)

                Button("Stop", role: .destructive) {
                    viewModel.stopRecording()
                }
                .disabled(viewModel.snapshot.state == .idle || viewModel.snapshot.state == .stopping)
            }

            GroupBox("Status") {
                VStack(alignment: .leading, spacing: 6) {
                    statusRow("State", viewModel.snapshot.state.rawValue.capitalized)
                    statusRow("Meeting", viewModel.snapshot.meetingID ?? "-")
                    statusRow("Job", viewModel.snapshot.jobID ?? "-")
                    statusRow("Recorded", formatted(seconds: viewModel.snapshot.totalRecordedSeconds))
                    statusRow("Segments", "\(viewModel.snapshot.segmentCount)")
                    statusRow("Power", viewModel.snapshot.onBattery ? "Battery" : "AC")
                    statusRow("Thermal", thermalLabel(viewModel.snapshot.thermalState))
                    statusRow("Heavy Processing", viewModel.snapshot.canRunHeavyProcessing ? "Active" : "Paused")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let note = viewModel.snapshot.note, !note.isEmpty {
                Text(note)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }

            Spacer()
        }
        .padding(20)
        .frame(minWidth: 540, minHeight: 420)
        .task {
            viewModel.startPolling()
        }
        .onDisappear {
            viewModel.stopPolling()
        }
    }

    private func statusRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .textSelection(.enabled)
        }
    }

    private func formatted(seconds: Double) -> String {
        let total = max(Int(seconds), 0)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    private func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:
            return "Nominal"
        case .fair:
            return "Fair"
        case .serious:
            return "Serious"
        case .critical:
            return "Critical"
        @unknown default:
            return "Unknown"
        }
    }
}
