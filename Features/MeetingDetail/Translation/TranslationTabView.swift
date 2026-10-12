import SwiftUI

struct TranslationTabView: View {
    @ObservedObject var viewModel: MeetingDetailViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Output language", selection: $viewModel.translationLanguage) {
                    Text("English").tag(LanguageMode.english)
                    Text("Nepali").tag(LanguageMode.nepali)
                }.pickerStyle(.segmented)
                Button("Prepare Translation") { viewModel.startTranslation() }
                    .disabled(viewModel.isProcessing || viewModel.outputs.isEmpty || !viewModel.isSummaryCurrent)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(viewModel.outputs.filter { $0.language == viewModel.translationLanguage && $0.type != .calendarCandidates }) { output in
                        GeneratedTextSection(title: output.type.rawValue.replacingOccurrences(of: "_", with: " ").capitalized, content: output.content)
                    }
                    if !viewModel.outputs.contains(where: { $0.language == viewModel.translationLanguage }) {
                        Text("Choose a language, then prepare translated outputs locally.").foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(12)
    }
}
