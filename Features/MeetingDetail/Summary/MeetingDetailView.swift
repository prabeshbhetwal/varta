import SwiftUI

private enum MeetingDetailTab: String, CaseIterable, Identifiable {
    case summary
    case transcript
    case translation
    case outputs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .summary:
            return "Summary"
        case .transcript:
            return "Transcript"
        case .translation:
            return "Translation"
        case .outputs:
            return "Outputs"
        }
    }
}

struct MeetingDetailView: View {
    let meetingID: String
    let storageService: StorageService

    @StateObject private var holder = MeetingDetailViewModelHolder()
    @State private var selectedTab: MeetingDetailTab = .summary

    var body: some View {
        let viewModel = holder.viewModel(meetingID: meetingID, storageService: storageService)

        VStack(spacing: 0) {
            Picker("Section", selection: $selectedTab) {
                ForEach(MeetingDetailTab.allCases) { tab in
                    Text(tab.title)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            switch selectedTab {
            case .summary:
                SummaryTabView(viewModel: viewModel)
            case .transcript:
                TranscriptTabView(viewModel: viewModel)
            case .translation:
                TranslationTabView(viewModel: viewModel)
            case .outputs:
                OutputsTabView(viewModel: viewModel)
            }
        }
        .task(id: meetingID) {
            await viewModel.refresh()
        }
        .alert("Meeting Detail Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { _ in viewModel.errorMessage = nil }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(viewModel.errorMessage ?? "Unknown error")
        }
    }
}

@MainActor
private final class MeetingDetailViewModelHolder: ObservableObject {
    private var cache: [String: MeetingDetailViewModel] = [:]

    func viewModel(meetingID: String, storageService: StorageService) -> MeetingDetailViewModel {
        if let existing = cache[meetingID] {
            return existing
        }

        let created = MeetingDetailViewModel(meetingID: meetingID, storageService: storageService)
        cache[meetingID] = created
        return created
    }
}
