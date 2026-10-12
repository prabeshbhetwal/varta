import SwiftUI

struct SummaryTabView: View {
    @ObservedObject var viewModel: MeetingDetailViewModel
    @State private var summaryStyle = "Concise"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Summary format", selection: $summaryStyle) {
                    Text("Concise").tag("Concise")
                    Text("Detailed").tag("Detailed")
                    Text("Bullets").tag("Bullets")
                }.pickerStyle(.segmented)
                Spacer()
                Button("Generate / Resume Summary & Outputs") { viewModel.startSummary() }
                    .disabled(viewModel.isProcessing || viewModel.segments.isEmpty)
                    .help("Resume saved processing when transcript and prompts are unchanged.")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let summary = viewModel.summary {
                        Text(summaryStyle == "Detailed" ? summary.detailed : summaryStyle == "Bullets" ? summary.bullets : summary.concise)
                            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    } else {
                        Text("Generate a transcript, review corrections, then generate a local summary.")
                            .foregroundStyle(.secondary)
                    }
                    if let actions = viewModel.output(.actionItems) {
                        GeneratedTextSection(title: "Action Items", content: actions)
                    }
                    if let decisions = viewModel.output(.decisions) {
                        GeneratedTextSection(title: "Decisions", content: decisions)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
    }
}

struct GeneratedTextSection: View {
    let title: String
    let content: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(content).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
    }
}
