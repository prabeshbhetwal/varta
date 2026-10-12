import SwiftUI

struct MeetingDetailView: View {
    let meetingID: String
    let storageService: StorageService

    @StateObject private var viewModel: MeetingDetailViewModel

    init(meetingID: String, storageService: StorageService, memoryManager: MemoryManager) {
        self.meetingID = meetingID
        self.storageService = storageService
        _viewModel = StateObject(
            wrappedValue: MeetingDetailViewModel(meetingID: meetingID, storageService: storageService, memoryManager: memoryManager)
        )
    }

    var body: some View {
        SummaryTabView(viewModel: viewModel)
        .task {
            await viewModel.refresh()
        }
        .alert("Recording Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil && viewModel.successMessage == nil },
            set: { _ in viewModel.errorMessage = nil }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(viewModel.errorMessage ?? "Unknown error")
        }
        .alert("Done", isPresented: Binding(
            get: { viewModel.successMessage != nil },
            set: { _ in viewModel.successMessage = nil }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(viewModel.successMessage ?? "")
        }
    }
}
