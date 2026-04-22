import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var appModel: AppModel

    @StateObject private var viewModelHolder = HomeViewModelHolder()
    @StateObject private var recordingVMHolder = RecordingToolbarViewModelHolder()

    var body: some View {
        Group {
            if let storage = appModel.storageService {
                let viewModel = viewModelHolder.viewModel(storageService: storage)
                let recordingVM = recordingVMHolder.viewModel(
                    recorderCoordinator: appModel.recorderCoordinator,
                    onRecordingSaved: { meetingID in
                        Task {
                            await viewModel.refreshMeetings(select: meetingID)
                        }
                    }
                )
                let selectedMeetingBinding = Binding<String?>(
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
                    }
                )
                NavigationSplitView {
                    List(viewModel.meetings, selection: selectedMeetingBinding) { meeting in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(meeting.title)
                                .font(.headline)
                            Text(meeting.createdAt, style: .date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(Optional(meeting.id))
                    }
                    .overlay {
                        if viewModel.meetings.isEmpty {
                            if appModel.recorderCoordinator != nil {
                                ContentUnavailableView {
                                    Label("No Recordings Yet", systemImage: "waveform.badge.plus")
                                } description: {
                                    Text("Start a recording to create your first transcript source.")
                                } actions: {
                                    Button("Record") {
                                        recordingVM.captureMicrophone = true
                                        recordingVM.captureSystemAudio = false
                                        recordingVM.startRecording()
                                    }
                                    .keyboardShortcut("r", modifiers: [])
                                }
                            } else {
                                ContentUnavailableView {
                                    Label("No Recordings Yet", systemImage: "waveform.badge.plus")
                                } description: {
                                    Text("Recording services are unavailable.")
                                }
                            }
                        }
                    }
                    .navigationTitle("Recordings")
                } detail: {
                    if let meetingID = viewModel.selectedMeetingID {
                        MeetingDetailView(meetingID: meetingID, storageService: storage)
                            .id(meetingID)
                    } else {
                        ContentUnavailableView("Select a Recording", systemImage: "list.bullet.rectangle")
                    }
                }
                .navigationSplitViewColumnWidth(min: 260, ideal: 320)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        switch recordingVM.snapshot.state {
                        case .idle, .failed:
                            Button {
                                recordingVM.captureMicrophone = true
                                recordingVM.captureSystemAudio = false
                                recordingVM.startRecording()
                            } label: {
                                Label("Record", systemImage: "record.circle")
                            }
                            .help("Start recording")
                        case .starting, .recording:
                            Button {
                                recordingVM.pauseRecording()
                            } label: {
                                Label("Pause", systemImage: "pause.fill")
                            }
                            .help("Pause recording")

                            Button {
                                recordingVM.stopRecording()
                            } label: {
                                Label("Stop", systemImage: "stop.fill")
                            }
                            .help("Stop recording")
                        case .paused:
                            Button {
                                recordingVM.resumeRecording()
                            } label: {
                                Label("Resume", systemImage: "play.fill")
                            }
                            .help("Resume recording")

                            Button {
                                recordingVM.stopRecording()
                            } label: {
                                Label("Stop", systemImage: "stop.fill")
                            }
                            .help("Stop recording")
                        case .stopping:
                            ProgressView()
                                .help("Saving recording")
                        }
                    }
                }
                .task {
                    await viewModel.refreshMeetings()
                    recordingVM.startPolling()
                }
                .onDisappear {
                    recordingVM.stopPolling()
                }
            } else {
                ProgressView("Preparing storage")
            }
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

    func viewModel(recorderCoordinator: RecorderCoordinator?, onRecordingSaved: @escaping (String?) -> Void) -> RecordingControlsViewModel {
        guard let recorderCoordinator else {
            // Provide a dummy coordinator by fatalError to indicate misuse; caller should guard nil.
            fatalError("RecorderCoordinator unavailable")
        }
        let identifier = ObjectIdentifier(recorderCoordinator)
        if let cachedViewModel, cachedCoordinatorID == identifier {
            return cachedViewModel
        }
        let created = RecordingControlsViewModel(recorderCoordinator: recorderCoordinator, onRecordingSaved: onRecordingSaved)
        created.captureMicrophone = true
        created.captureSystemAudio = false
        cachedCoordinatorID = identifier
        cachedViewModel = created
        return created
    }
}
