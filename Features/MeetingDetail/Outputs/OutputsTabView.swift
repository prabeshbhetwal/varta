import SwiftUI

struct OutputsTabView: View {
    @ObservedObject var viewModel: MeetingDetailViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Structured Outputs")
                        .font(.title3)
                        .bold()
                    Spacer()
                    Button("Regenerate") {
                        Task {
                            await viewModel.regenerateSummary()
                        }
                    }
                    .disabled(viewModel.isBusy)
                }

                outputSection(title: "Action Items", type: .actionItems)
                outputSection(title: "Decisions", type: .decisions)
                outputSection(title: "Unresolved Questions", type: .unresolvedQuestions)
                outputSection(title: "Follow-up Email", type: .followUpEmail)
                outputSection(title: "Calendar Candidates", type: .calendarCandidates)
            }
            .padding(16)
        }
    }

    private func outputSection(title: String, type: GeneratedOutputType) -> some View {
        GroupBox(title) {
            Text(viewModel.content(for: type).isEmpty ? "Not generated yet." : viewModel.content(for: type))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}
