import SwiftUI

struct TranscriptTabView: View {
    @ObservedObject var viewModel: MeetingDetailViewModel

    var body: some View {
        List {
            if viewModel.segments.isEmpty {
                Text(viewModel.transcriptEmptyMessage())
                    .foregroundStyle(.secondary)
            }

            ForEach(viewModel.segments) { segment in
                TranscriptSegmentRow(segment: segment) { correctedText in
                    Task {
                        await viewModel.updateSegmentCorrection(segmentID: segment.id, correctedText: correctedText)
                    }
                } onLockChanged: { isLocked in
                    Task {
                        await viewModel.setSegmentLock(segmentID: segment.id, isLocked: isLocked)
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}

private struct TranscriptSegmentRow: View {
    let segment: TranscriptSegment
    let onSave: (String) -> Void
    let onLockChanged: (Bool) -> Void

    @State private var draftText: String

    init(
        segment: TranscriptSegment,
        onSave: @escaping (String) -> Void,
        onLockChanged: @escaping (Bool) -> Void
    ) {
        self.segment = segment
        self.onSave = onSave
        self.onLockChanged = onLockChanged
        _draftText = State(initialValue: segment.correctedText ?? segment.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(timecode(segment.startSeconds)) - \(timecode(segment.endSeconds))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Locked", isOn: Binding(
                    get: { segment.isLocked },
                    set: { onLockChanged($0) }
                ))
                .labelsHidden()
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
    }

    private func timecode(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded()), 0)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}
