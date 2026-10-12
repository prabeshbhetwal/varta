import AVKit
import SwiftUI

struct TranscriptTabView: View {
    @ObservedObject var viewModel: MeetingDetailViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Transcription language", selection: $viewModel.languageMode) {
                    Text("English").tag(LanguageMode.english)
                    Text("Nepali").tag(LanguageMode.nepali)
                    Text("Mixed EN/NE").tag(LanguageMode.mixed)
                }.frame(maxWidth: 260)
                Button("Generate Transcript") { viewModel.startTranscript() }
                    .disabled(viewModel.isProcessing || viewModel.importedMedia.isEmpty)
                Button("Load Audio") { Task { await viewModel.preparePlayback() } }
                    .disabled(viewModel.isPreparingPlayback || viewModel.importedMedia.isEmpty)
            }
            ForEach(viewModel.resumableJobs) { job in
                HStack {
                    Text("Transcription \(job.status.rawValue) · \(Int(job.progress * 100))% saved")
                    Spacer()
                    Button("Resume") { viewModel.startTranscript(resumeJobID: job.id) }
                        .disabled(viewModel.isProcessing)
                }.font(.caption)
            }
            if let player = viewModel.player {
                VideoPlayer(player: player).frame(height: 100).accessibilityLabel("Recording playback")
            }
            List {
            if viewModel.segments.isEmpty {
                Text(viewModel.transcriptEmptyMessage())
                    .foregroundStyle(.secondary)
            }

            ForEach(viewModel.segments) { segment in
                TranscriptSegmentRow(segment: segment, onSeek: {
                    Task { await viewModel.seek(to: segment.startSeconds) }
                }) { correctedText in
                    Task {
                        await viewModel.updateSegmentCorrection(segmentID: segment.id, correctedText: correctedText)
                    }
                } onLockChanged: { isLocked in
                    Task {
                        await viewModel.setSegmentLock(segmentID: segment.id, isLocked: isLocked)
                    }
                }
            }
            }.listStyle(.inset)
            HStack {
                Button("Copy Transcript") { viewModel.copyTranscriptToClipboard() }
                Button("Export Transcript") { viewModel.exportTranscript() }
                Button("Show Audio in Finder") { viewModel.openRecordingsFolderInFinder() }
            }
        }.padding(12)
    }
}

private struct TranscriptSegmentRow: View {
    let segment: TranscriptSegment
    let onSeek: () -> Void
    let onSave: (String) -> Void
    let onLockChanged: (Bool) -> Void

    @State private var draftText: String

    init(
        segment: TranscriptSegment,
        onSeek: @escaping () -> Void,
        onSave: @escaping (String) -> Void,
        onLockChanged: @escaping (Bool) -> Void
    ) {
        self.segment = segment
        self.onSeek = onSeek
        self.onSave = onSave
        self.onLockChanged = onLockChanged
        _draftText = State(initialValue: segment.correctedText ?? segment.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("\(timecode(segment.startSeconds)) – \(timecode(segment.endSeconds))", action: onSeek)
                    .font(.caption)
                    .help("Play recording from this transcript segment")
                Spacer()
                Toggle("Locked", isOn: Binding(
                    get: { segment.isLocked },
                    set: { onLockChanged($0) }
                ))
                .accessibilityLabel("Lock transcript at \(timecode(segment.startSeconds))")
                .help("Lock prevents edits and preserves corrected text.")
            }

            TextEditor(text: $draftText)
                .accessibilityLabel("Transcript at \(timecode(segment.startSeconds))")
                .frame(minHeight: 80)
                .disabled(segment.isLocked)
                .font(.body)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(0.25), lineWidth: 1)
                )

            HStack {
                Text("Raw: \(segment.text)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Spacer()

                Button("Save Correction") {
                    onSave(draftText)
                }
                .disabled(segment.isLocked)
            }
        }
        .padding(.vertical, 6)
        .onChange(of: segment.effectiveText) { draftText = segment.effectiveText }
    }

    private func timecode(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded()), 0)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}
