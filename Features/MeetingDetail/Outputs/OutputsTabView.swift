import SwiftUI

struct OutputsTabView: View {
    @ObservedObject var viewModel: MeetingDetailViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let questions = viewModel.output(.unresolvedQuestions) {
                    GeneratedTextSection(title: "Unresolved Questions", content: questions)
                }
                if let email = viewModel.output(.followUpEmail) {
                    GeneratedTextSection(title: "Follow-up Email Draft", content: email)
                }
                if viewModel.output(.unresolvedQuestions) == nil && viewModel.output(.followUpEmail) == nil {
                    Text("Generate Summary & Outputs to prepare questions and an email draft.")
                        .foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
    }
}
