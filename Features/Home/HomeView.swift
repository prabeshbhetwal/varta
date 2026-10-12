import SwiftUI
import UniformTypeIdentifiers

private func formatted(seconds: Double) -> String {
    let total = max(Int(seconds), 0)
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    return hours > 0
        ? String(format: "%02d:%02d:%02d", hours, minutes, secs)
        : String(format: "%02d:%02d", minutes, secs)
}

struct HomeView: View {
    @EnvironmentObject private var appModel: AppModel

    @StateObject private var viewModelHolder = HomeViewModelHolder()
    @StateObject private var recordingVMHolder = RecordingToolbarViewModelHolder()

    var body: some View {
        Group {
            if let storage = appModel.storageService, let recorderCoordinator = appModel.recorderCoordinator,
               let memoryManager = appModel.memoryManager {
                let viewModel = viewModelHolder.viewModel(storageService: storage)
                let recordingVM = recordingVMHolder.viewModel(
                    recorderCoordinator: recorderCoordinator,
                    settingsStore: appModel.settingsStore,
                    onRecordingSaved: { meetingID in
                        Task {
                            await viewModel.refreshMeetings(select: meetingID)
                        }
                    }
                )
                HomeContentView(storageService: storage, memoryManager: memoryManager, viewModel: viewModel, recordingVM: recordingVM)
            } else {
                ProgressView("Preparing storage")
            }
        }
    }
}

private struct HomeContentView: View {
    let storageService: StorageService
    let memoryManager: MemoryManager
    @ObservedObject var viewModel: HomeViewModel
    @ObservedObject var recordingVM: RecordingControlsViewModel
    @State private var showsImporter = false

    var body: some View {
        NavigationSplitView {
            List(selection: selectedMeetingBinding) {
                if !viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ForEach(viewModel.searchResults) { result in
                        Button { viewModel.selectSearchResult(result) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(result.title).font(.headline)
                                Text(result.text).font(.caption).lineLimit(3)
                                Text(formatted(seconds: result.startSeconds)).font(.caption.monospaced())
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                } else {
                    ForEach(viewModel.meetings) { meeting in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(meeting.title).font(.headline)
                            Text(meeting.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                        }.tag(Optional(meeting.id))
                    }
                }
                if !viewModel.recoverableRecordingJobs.isEmpty {
                    Section("Interrupted Recordings") {
                        ForEach(viewModel.recoverableRecordingJobs) { job in
                            Button {
                                Task {
                                    await recordingVM.restoreInterruptedRecording(jobID: job.id, storageService: storageService)
                                    if let meetingID = job.meetingID { viewModel.selectedMeetingID = meetingID }
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Recover recording")
                                    Text(viewModel.meetings.first { $0.id == job.meetingID }?.title ?? "Interrupted meeting")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.disabled(recordingVM.snapshot.state != .idle && recordingVM.snapshot.state != .failed && recordingVM.snapshot.state != .completed)
                        }
                    }
                }
            }
            .overlay {
                if !viewModel.searchQuery.isEmpty && viewModel.searchResults.isEmpty {
                    ContentUnavailableView("No Transcript Matches", systemImage: "magnifyingglass", description: Text("Search generated transcripts, including saved corrections."))
                } else if viewModel.meetings.isEmpty {
                    ContentUnavailableView {
                        Label("No Recordings Yet", systemImage: "waveform.badge.plus")
                    } description: {
                        Text("Start a recording to create your first transcript source.")
                    } actions: {
                        Button("Record") {
                            recordingVM.startRecording()
                        }
                        .keyboardShortcut("r", modifiers: .command)
                    }
                }
            }
            .searchable(text: $viewModel.searchQuery, prompt: "Search transcripts")
            .task(id: viewModel.searchQuery) { await viewModel.searchTranscripts() }
            .navigationTitle("Recordings")
        } detail: {
            if let meetingID = viewModel.selectedMeetingID {
                MeetingDetailView(meetingID: meetingID, storageService: storageService, memoryManager: memoryManager,
                                  requestedSegmentID: viewModel.selectedSearchResult?.meetingID == meetingID ? viewModel.selectedSearchResult?.id : nil,
                                  requestedSeekSeconds: viewModel.selectedSearchResult?.meetingID == meetingID ? viewModel.selectedSearchResult?.startSeconds : nil)
                    .id(meetingID)
            } else {
                ContentUnavailableView("Select a Recording", systemImage: "list.bullet.rectangle")
            }
        }
        .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        .toolbar {
            RecordingToolbarControls(viewModel: recordingVM)
            ToolbarItem {
                Button {
                    showsImporter = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .disabled(viewModel.isImporting)
                .keyboardShortcut("i", modifiers: .command)
            }
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.audio, .movie]) { result in
            switch result {
            case .success(let url):
                Task { await viewModel.importMediaFile(at: url) }
            case .failure(let error):
                viewModel.errorMessage = error.localizedDescription
            }
        }
        .alert("Varta", isPresented: Binding(
            get: { viewModel.errorMessage != nil || recordingVM.errorMessage != nil },
            set: { _ in viewModel.errorMessage = nil; recordingVM.errorMessage = nil }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(viewModel.errorMessage ?? recordingVM.errorMessage ?? "Unknown error")
        }
        .safeAreaInset(edge: .bottom) {
            RecordingStatusFooter(viewModel: recordingVM)
        }
        .task {
            await viewModel.refreshMeetings()
            await recordingVM.refreshSnapshot()
            recordingVM.startPolling()
        }
        .onDisappear {
            recordingVM.stopPolling()
        }
    }

    private var selectedMeetingBinding: Binding<String?> {
        Binding<String?>(
            get: {
                guard let selectedMeetingID = viewModel.selectedMeetingID else {
                    return nil
                }
                if viewModel.meetings.contains(where: { $0.id == selectedMeetingID }) {
                    return selectedMeetingID
                }
                return nil
            },
            set: { newMeetingID in
                guard viewModel.selectedMeetingID != newMeetingID else {
                    return
                }
                viewModel.selectedMeetingID = newMeetingID
                viewModel.selectedSearchResult = nil
            }
        )
    }
}

private struct RecordingToolbarControls: ToolbarContent {
    @ObservedObject var viewModel: RecordingControlsViewModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            switch viewModel.snapshot.state {
            case .idle, .failed, .completed:
                Menu {
                    Toggle("Microphone", isOn: $viewModel.captureMicrophone)
                    Toggle("System Audio", isOn: $viewModel.captureSystemAudio)
                } label: {
                    Label("Audio Sources", systemImage: "slider.horizontal.3")
                }
                Button {
                    viewModel.startRecording()
                } label: {
                    Label("Record", systemImage: "record.circle")
                }
                .help("Start recording")
                .disabled(!viewModel.captureMicrophone && !viewModel.captureSystemAudio)
            case .starting:
                ProgressView()
                    .controlSize(.small)
                    .help("Starting recording")

            case .recording:
                Text(formatted(seconds: viewModel.snapshot.totalRecordedSeconds))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Button {
                    viewModel.pauseRecording()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .help("Pause recording")

                Button {
                    viewModel.stopRecording()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .help("Stop recording")
            case .paused:
                Text(formatted(seconds: viewModel.snapshot.totalRecordedSeconds))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Button {
                    viewModel.resumeRecording()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .help("Resume recording")

                Button {
                    viewModel.stopRecording()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .help("Stop recording")
            case .stopping:
                Text(formatted(seconds: viewModel.snapshot.totalRecordedSeconds))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                ProgressView()
                    .controlSize(.small)
                    .help("Saving recording")
            }
        }
    }
}

private struct RecordingStatusFooter: View {
    @ObservedObject var viewModel: RecordingControlsViewModel

    var body: some View {
        Group {
            if let errorMessage = viewModel.errorMessage, !errorMessage.isEmpty {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if showsLiveControls {
                HStack(spacing: 12) {
                    Label(statusLabel, systemImage: statusIcon)
                        .font(.subheadline.weight(.semibold))

                    Text(formatted(seconds: viewModel.snapshot.totalRecordedSeconds))
                        .font(.system(.body, design: .monospaced))
                        .monospacedDigit()

                    Spacer()

                    if viewModel.snapshot.state == .recording {
                        Button("Pause") {
                            viewModel.pauseRecording()
                        }
                    } else if viewModel.snapshot.state == .paused {
                        Button("Resume") {
                            viewModel.resumeRecording()
                        }
                    }

                    Button("Stop", role: .destructive) {
                        viewModel.stopRecording()
                    }
                    .disabled(viewModel.snapshot.state == .stopping || viewModel.snapshot.state == .starting)
                }
                .foregroundStyle(.primary)
            } else if let userMessage = viewModel.userMessage, !userMessage.isEmpty {
                Label(userMessage, systemImage: statusIcon)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var showsLiveControls: Bool {
        switch viewModel.snapshot.state {
        case .starting, .recording, .paused, .stopping:
            return true
        case .idle, .failed, .completed:
            return false
        }
    }

    private var statusLabel: String {
        switch viewModel.snapshot.state {
        case .starting:
            return "Starting"
        case .recording:
            return "Recording"
        case .paused:
            return "Paused"
        case .stopping:
            return "Saving"
        case .completed:
            return "Saved"
        case .failed:
            return "Failed"
        case .idle:
            return "Ready"
        }
    }

    private var statusIcon: String {
        switch viewModel.snapshot.state {
        case .starting:
            return "arrow.triangle.2.circlepath"
        case .recording:
            return "record.circle"
        case .paused:
            return "pause.circle"
        case .stopping:
            return "square.and.arrow.down"
        case .completed:
            return "checkmark.circle"
        case .failed:
            return "exclamationmark.triangle"
        default:
            return "info.circle"
        }
    }
}

@MainActor
private final class HomeViewModelHolder: ObservableObject {
    private var cachedStorageID: ObjectIdentifier?
    private var cachedViewModel: HomeViewModel?

    func viewModel(storageService: StorageService) -> HomeViewModel {
        let identifier = ObjectIdentifier(storageService)
        if let cachedViewModel, cachedStorageID == identifier {
            return cachedViewModel
        }

        let created = HomeViewModel(storageService: storageService)
        cachedStorageID = identifier
        cachedViewModel = created
        return created
    }
}

@MainActor
final class RecordingToolbarViewModelHolder: ObservableObject {
    private var cachedCoordinatorID: ObjectIdentifier?
    private var cachedViewModel: RecordingControlsViewModel?

    func viewModel(recorderCoordinator: RecorderCoordinator, settingsStore: SettingsStore?, onRecordingSaved: @escaping (String?) -> Void) -> RecordingControlsViewModel {
        let identifier = ObjectIdentifier(recorderCoordinator)
        if let cachedViewModel, cachedCoordinatorID == identifier {
            return cachedViewModel
        }
        let created = RecordingControlsViewModel(recorderCoordinator: recorderCoordinator, settingsStore: settingsStore, onRecordingSaved: onRecordingSaved)
        created.captureMicrophone = true
        created.captureSystemAudio = false
        cachedCoordinatorID = identifier
        cachedViewModel = created
        return created
    }
}
