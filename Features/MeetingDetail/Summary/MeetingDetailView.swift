import SwiftUI

struct MeetingDetailView: View {
    let meetingID: String
    let storageService: StorageService
    let contentRevision: Int
    let requestedSegmentID: Int64?
    let requestedSeekSeconds: Double?

    @StateObject private var viewModel: MeetingDetailViewModel
    @State private var selectedTab = "summary"

    init(meetingID: String, storageService: StorageService, memoryManager: MemoryManager, contentRevision: Int = 0, requestedSegmentID: Int64? = nil, requestedSeekSeconds: Double? = nil) {
        self.meetingID = meetingID
        self.storageService = storageService
        self.contentRevision = contentRevision
        self.requestedSegmentID = requestedSegmentID
        self.requestedSeekSeconds = requestedSeekSeconds
        _viewModel = StateObject(
            wrappedValue: MeetingDetailViewModel(meetingID: meetingID, storageService: storageService, memoryManager: memoryManager)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(viewModel.meetingDisplayTitle()).font(.title2).bold()
                Spacer()
                if viewModel.isProcessing {
                    ProgressView().controlSize(.small)
                    Button("Cancel Processing") { viewModel.cancelProcessing() }
                }
            }
            if let message = viewModel.successMessage {
                Text(message).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if viewModel.summary != nil && !viewModel.isSummaryCurrent {
                Label("Transcript changed; generate summary and outputs again.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
            TabView(selection: $selectedTab) {
                SummaryTabView(viewModel: viewModel)
                    .tabItem { Label("Summary", systemImage: "text.alignleft") }.tag("summary")
                TranscriptTabView(viewModel: viewModel)
                    .tabItem { Label("Transcript", systemImage: "waveform") }.tag("transcript")
                TranslationTabView(viewModel: viewModel)
                    .tabItem { Label("Translation", systemImage: "character.bubble") }.tag("translation")
                OutputsTabView(viewModel: viewModel)
                    .tabItem { Label("Outputs", systemImage: "list.bullet.clipboard") }.tag("outputs")
                CalendarTabView(viewModel: viewModel, storageService: storageService)
                    .tabItem { Label("Calendar", systemImage: "calendar") }.tag("calendar")
            }
        }
        .padding(16)
        .onAppear { viewModel.activatePlayback() }
        .task(id: requestedSegmentID) {
            await viewModel.refresh()
            guard let seconds = requestedSeekSeconds else { return }
            selectedTab = "transcript"
            await viewModel.seek(to: seconds)
        }
        .task(id: contentRevision) {
            guard contentRevision > 0 else { return }
            await viewModel.refreshMedia()
        }
        .onDisappear {
            viewModel.stopPlayback()
            viewModel.cancelProcessing()
        }
        .alert("Varta", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { _ in viewModel.errorMessage = nil }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(viewModel.errorMessage ?? "Unknown error")
        }
    }
}
