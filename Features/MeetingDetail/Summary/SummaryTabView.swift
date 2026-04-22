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
            if viewModel.segments.isEmpty {
                ContentUnavailableView("Transcript not generated yet", systemImage: "text.quote")
            } else {
                List(viewModel.segments) { seg in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(seg.effectiveText)
                        Text("[\(timecode(seg.startSeconds)) - \(timecode(seg.endSeconds))]")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(16)
        .task { await viewModel.refresh() }
    }

    private func timecode(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded()), 0)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}
