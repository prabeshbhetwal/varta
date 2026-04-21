import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject private var appModel: AppModel

    @StateObject private var viewModelHolder = HomeViewModelHolder()
    @State private var showingImporter = false
    @State private var showingRecordingControls = false

    private let supportedTypes: [UTType] = ["mp3", "m4a", "wav", "aiff", "mp4", "mov", "m4v"]
        .compactMap { UTType(filenameExtension: $0) }

    var body: some View {
        Group {
            if let storage = appModel.storageService {
                let viewModel = viewModelHolder.viewModel(storageService: storage)
                NavigationSplitView {
                    List(viewModel.meetings, selection: Binding(
                        get: { viewModel.selectedMeetingID },
                        set: { viewModel.selectedMeetingID = $0 }
                    )) { meeting in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(meeting.title)
                                .font(.headline)
                            Text(meeting.createdAt, style: .date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(meeting.id)
                    }
                    .overlay {
                        if viewModel.meetings.isEmpty {
                            ContentUnavailableView("No Imported Meetings", systemImage: "tray")
                        }
                    }
                } detail: {
                    if let meetingID = viewModel.selectedMeetingID {
                        MeetingDetailView(meetingID: meetingID, storageService: storage)
                    } else {
                        ContentUnavailableView("Select a Meeting", systemImage: "waveform")
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        if appModel.recorderCoordinator != nil {
                            Button {
                                showingRecordingControls = true
                            } label: {
                                Label("Recording", systemImage: "mic.circle")
                            }
                        }
                    }

                    ToolbarItem(placement: .primaryAction) {
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
                .alert("Import Error", isPresented: Binding(
                    get: { viewModel.errorMessage != nil },
                    set: { _ in viewModel.errorMessage = nil }
                )) {
                    Button("OK", role: .cancel) { }
                } message: {
                    Text(viewModel.errorMessage ?? "Unknown import error")
                }
                .sheet(isPresented: $showingRecordingControls) {
                    if let recorderCoordinator = appModel.recorderCoordinator {
                        RecordingControlsView(recorderCoordinator: recorderCoordinator)
                    } else {
                        Text("Recording services are unavailable.")
                            .padding(20)
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
