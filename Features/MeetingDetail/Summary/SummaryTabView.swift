import SwiftUI

struct SummaryTabView: View {
    @ObservedObject var viewModel: MeetingDetailViewModel

    @State private var glossaryTerm = ""
    @State private var glossaryReplacement = ""
    @State private var glossaryLanguage: LanguageMode = .mixed

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Local Summary")
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

                GroupBox("Concise") {
                    Text(viewModel.summary?.concise ?? "No summary yet.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }

                GroupBox("Detailed") {
                    Text(viewModel.summary?.detailed ?? "No summary yet.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }

                GroupBox("Bullets") {
                    Text(viewModel.summary?.bullets ?? "No summary yet.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }

                Divider()

                Text("Glossary")
                    .font(.headline)

                HStack {
                    TextField("Term", text: $glossaryTerm)
                    TextField("Replacement", text: $glossaryReplacement)
                    Picker("Language", selection: $glossaryLanguage) {
                        Text("Mixed").tag(LanguageMode.mixed)
                        Text("English").tag(LanguageMode.english)
                        Text("Nepali").tag(LanguageMode.nepali)
                    }
                    .frame(width: 140)

                    Button("Add") {
                        let term = glossaryTerm
                        let replacement = glossaryReplacement
                        let language = glossaryLanguage

                        Task {
                            await viewModel.addGlossaryTerm(term: term, replacement: replacement, languageCode: language)
                            glossaryTerm = ""
                            glossaryReplacement = ""
                        }
                    }
                    .disabled(glossaryTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || glossaryReplacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if viewModel.glossaryTerms.isEmpty {
                    Text("No glossary terms configured.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.glossaryTerms) { term in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(term.term)
                                    .bold()
                                Text("→ \(term.replacement) [\(term.languageCode.rawValue)]")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Delete", role: .destructive) {
                                Task {
                                    await viewModel.deleteGlossaryTerm(id: term.id)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .padding(16)
        }
    }
}
