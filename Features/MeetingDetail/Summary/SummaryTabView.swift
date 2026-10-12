import SwiftUI

// Deprecated in transcript-first UI. Kept to avoid breaking build where referenced.
struct SummaryTabView: View {
    @ObservedObject var viewModel: MeetingDetailViewModel
    var body: some View {
        // Forward to MeetingDetailView's simplified content by embedding TranscriptOnlyView
        TranscriptOnlyView(viewModel: viewModel)
    }
}

// A lightweight transcript-only view used by SummaryTabView for compatibility.
private struct TranscriptOnlyView: View {
    @ObservedObject var viewModel: MeetingDetailViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recording Transcript").font(.title3).bold()
                Spacer()
                Button("Generate Transcript") {
                    Task { await viewModel.generateTranscript() }
                }.disabled(viewModel.isGeneratingTranscript)
            }
            Text("Transcription is unavailable in this development build. Your audio remains saved locally.")
                .foregroundStyle(.secondary)
            TranscriptTabView(viewModel: viewModel)
            HStack {
                Button("Copy Transcript") { viewModel.copyTranscriptToClipboard() }
                Button("Export Transcript") { viewModel.exportTranscript() }
                Button("Show Audio in Finder") { viewModel.openRecordingsFolderInFinder() }
            }
        }
        .padding(16)
    }
}
