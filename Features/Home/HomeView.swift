import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject private var appModel: AppModel

    @StateObject private var viewModelHolder = HomeViewModelHolder()
    @State private var showingImporter = false
    @State private var showingRecordingControls = false
    @State private var showingDeleteConfirmation = false

    private let supportedTypes: [UTType] = ["mp3", "m4a", "wav", "aiff", "mp4", "mov", "m4v"]
        .compactMap { UTType(filenameExtension: $0) }

    var body: some View {
        Group {
            if let storage = appModel.storageService {
                let viewModel = viewModelHolder.viewModel(storageService: storage)
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
                            ContentUnavailableView {
                                Label("No Recordings Yet", systemImage: "waveform.badge.plus")
                            } description: {
                                Text("Import audio/video or start a recording to create your first transcript source.")
                            } actions: {
                                HStack(spacing: 10) {
                                    Button("Import File") {
                                        showingImporter = true
                                    }

                                    if appModel.recorderCoordinator != nil {
                                        Button("Start Recording") {
                                            showingRecordingControls = true
                                        }
                                    }
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
                        if appModel.recorderCoordinator != nil {
                            Button {
                                showingRecordingControls = true
                            } label: {
                                Label("New Recording", systemImage: "record.circle")
                            }
                            .help("Start a new local recording")
                        }

                        Button {
                            Task {
                                await viewModel.refreshMeetings()
                            }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .help("Refresh meetings list")

                        Button {
                            showingImporter = true
                        } label: {
                            if viewModel.isImporting {
                                ProgressView()
                            } else {
                                Label("Import File", systemImage: "square.and.arrow.down")
                            }
                        }
                        .disabled(viewModel.isImporting)
                        .help("Import audio or video into a meeting")

                        Button(role: .destructive) {
                            showingDeleteConfirmation = true
                        } label: {
                            Label("Delete Meeting", systemImage: "trash")
                        }
                        .disabled(viewModel.selectedMeetingID == nil || viewModel.isDeleting)
                        .help("Delete selected meeting and local files")
                    }
                }
                .task {
                    await viewModel.refreshMeetings()
                }
                .fileImporter(
                    isPresented: $showingImporter,
                    allowedContentTypes: supportedTypes,
                    allowsMultipleSelection: false
                ) { result in
                    guard case .success(let urls) = result, let firstURL = urls.first else {
                        return
                    }

                    Task {
                        await viewModel.importMediaFile(at: firstURL)
                    }
                }
                .confirmationDialog(
                    "Delete Meeting?",
                    isPresented: $showingDeleteConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Delete Meeting", role: .destructive) {
                        guard let selectedMeetingID = viewModel.selectedMeetingID else {
                            return
                        }
                        Task {
                            await viewModel.deleteMeeting(meetingID: selectedMeetingID)
                        }
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This permanently deletes \"\(viewModel.selectedMeetingTitle() ?? "Selected Recording")\", including local recordings and transcript data from this Mac.")
                }
                .alert("Action Error", isPresented: Binding(
                    get: { viewModel.errorMessage != nil && !showingDeleteConfirmation },
                    set: { _ in viewModel.errorMessage = nil }
                )) {
                    Button("OK", role: .cancel) { }
                } message: {
                    Text(viewModel.errorMessage ?? "Unknown import error")
                }
                .sheet(isPresented: $showingRecordingControls) {
                    if let recorderCoordinator = appModel.recorderCoordinator {
                        RecordingControlsView(
                            recorderCoordinator: recorderCoordinator,
                            onRecordingSaved: { meetingID in
                                Task {
                                    await viewModel.refreshMeetings(select: meetingID)
                                }
                            }
                        )
                    } else {
                        Text("Recording services are unavailable.")
                            .padding(20)
                    }
                }
                .onChange(of: showingRecordingControls) {
                    guard !showingRecordingControls else {
                        return
                    }

                    Task {
                        await viewModel.refreshMeetings()
                    }
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
