import SwiftUI

struct RecordingControlsView: View {
    @StateObject private var viewModel: RecordingControlsViewModel

    init(
        recorderCoordinator: RecorderCoordinator,
        onRecordingSaved: @escaping (String?) -> Void = { _ in }
    ) {
        _viewModel = StateObject(
            wrappedValue: RecordingControlsViewModel(
                recorderCoordinator: recorderCoordinator,
                onRecordingSaved: onRecordingSaved
            )
        )
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
            .disabled(viewModel.snapshot.state == .recording || viewModel.snapshot.state == .starting || viewModel.snapshot.state == .stopping)

            statusBanner

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
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)

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

            if let userMessage = viewModel.userMessage, !userMessage.isEmpty {
                Text(userMessage)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage = viewModel.errorMessage {
                GroupBox("Action Needed") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(errorMessage)
                        Text("Check Microphone and Screen Recording permissions in Settings, then try again.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .tint(.red)
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 540, height: 420)
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

    private var statusBanner: some View {
        let state = viewModel.snapshot.state
        let label: String
        let icon: String
        let tint: Color

        switch state {
        case .idle:
            label = "Ready to record"
            icon = "record.circle"
            tint = .secondary
        case .starting:
            label = "Starting capture…"
            icon = "arrow.triangle.2.circlepath"
            tint = .orange
        case .recording:
            label = "Recording"
            icon = "waveform.badge.mic"
            tint = .red
        case .paused:
            label = "Paused"
            icon = "pause.circle"
            tint = .yellow
        case .stopping:
            label = "Saving recording…"
            icon = "square.and.arrow.down"
            tint = .blue
        case .failed:
            label = "Recording failed"
            icon = "exclamationmark.triangle"
            tint = .red
        }

        return Label(label, systemImage: icon)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
