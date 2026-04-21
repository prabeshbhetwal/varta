import SwiftUI

struct TranslationTabView: View {
    @ObservedObject var viewModel: MeetingDetailViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Output Language", selection: $viewModel.selectedOutputLanguage) {
                    Text("English").tag(LanguageMode.english)
                    Text("Nepali").tag(LanguageMode.nepali)
                }
                .pickerStyle(.segmented)
                .frame(width: 260)

                Button("Translate Outputs") {
                    Task {
                        await viewModel.translateOutputsIfNeeded()
                    }
                }
                .disabled(viewModel.isBusy)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    outputBlock(title: "Concise Summary", content: viewModel.content(for: .summaryConcise))
                    outputBlock(title: "Detailed Summary", content: viewModel.content(for: .summaryDetailed))
                    outputBlock(title: "Bullet Summary", content: viewModel.content(for: .summaryBullets))
                    outputBlock(title: "Action Items", content: viewModel.content(for: .actionItems))
                    outputBlock(title: "Decisions", content: viewModel.content(for: .decisions))
                    outputBlock(title: "Unresolved Questions", content: viewModel.content(for: .unresolvedQuestions))
                    outputBlock(title: "Follow-up Email", content: viewModel.content(for: .followUpEmail))
                    outputBlock(title: "Calendar Candidates", content: viewModel.content(for: .calendarCandidates))
                }
                .padding(.vertical, 4)
            }
        }
        .padding(16)
    }

    private func outputBlock(title: String, content: String) -> some View {
        GroupBox(title) {
            Text(content.isEmpty ? "No output generated yet." : content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}
