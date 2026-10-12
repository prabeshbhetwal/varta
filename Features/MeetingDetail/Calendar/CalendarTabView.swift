import SwiftUI

struct CalendarTabView: View {
    @ObservedObject var viewModel: MeetingDetailViewModel
    let storageService: StorageService

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Review each suggestion. Choose a date, confirm details, then create it in your default Apple Calendar.")
                    .foregroundStyle(.secondary)
                candidateContent
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
    }

    @ViewBuilder
    private var candidateContent: some View {
        if viewModel.summary != nil && !viewModel.isSummaryCurrent {
            Text("Transcript changed. Regenerate summary and outputs before reviewing calendar suggestions.")
                .foregroundStyle(.secondary)
        } else if let candidates = try? viewModel.calendarCandidates() {
            if candidates.isEmpty {
                Text("No calendar suggestions. Generate Summary & Outputs after reviewing the transcript.")
                    .foregroundStyle(.secondary)
            }
            ForEach(candidates) { candidate in
                CalendarCandidateReview(candidate: candidate, meetingID: viewModel.meetingID, storageService: storageService)
            }
        } else {
            Text("Stored calendar suggestions could not be validated. Regenerate outputs before creating events.")
                .foregroundStyle(.red)
        }
    }
}

private struct CalendarCandidateReview: View {
    let candidate: CalendarCandidate
    let meetingID: String
    let storageService: StorageService
    @State private var title: String
    @State private var startDate = Date()
    @State private var durationMinutes: Double
    @State private var detailsReviewed = false
    @State private var isCreating = false
    @State private var isCreated = false
    @State private var message: String?

    init(candidate: CalendarCandidate, meetingID: String, storageService: StorageService) {
        self.candidate = candidate
        self.meetingID = meetingID
        self.storageService = storageService
        _title = State(initialValue: candidate.title)
        _durationMinutes = State(initialValue: candidate.durationMinutes ?? 30)
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Event title", text: $title)
                Text("Suggested date: \(candidate.dateHint ?? "Not stated — choose a date")")
                    .font(.caption).textSelection(.enabled)
                DatePicker("Start date and time", selection: $startDate)
                HStack {
                    TextField("Duration (minutes)", value: $durationMinutes, format: .number)
                        .frame(maxWidth: 280)
                    if candidate.durationMinutes == nil { Text("30-minute default; review before saving.").font(.caption).foregroundStyle(.secondary) }
                }
                Text(candidate.reason).textSelection(.enabled)
                Text("Transcript evidence: “\(candidate.sourceQuote)”")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Toggle("I reviewed the title, date and duration", isOn: $detailsReviewed)
                HStack {
                    Button(isCreated ? "Event Created" : "Create in Apple Calendar") {
                        Task { await createEvent() }
                    }.disabled(!detailsReviewed || isCreating || isCreated)
                    if isCreating { ProgressView().controlSize(.small) }
                }
                if let message { Text(message).textSelection(.enabled).font(.caption) }
            }.padding(8)
        }
        .onChange(of: title) { detailsReviewed = false }
        .onChange(of: startDate) { detailsReviewed = false }
        .onChange(of: durationMinutes) { detailsReviewed = false }
    }

    @MainActor
    private func createEvent() async {
        guard detailsReviewed, !isCreating, !isCreated else { return }
        isCreating = true
        defer { isCreating = false }
        let draft = CalendarDraft(title: title, startDate: startDate, durationMinutes: durationMinutes, notes: candidate.reason + "\n\nTranscript evidence: " + candidate.sourceQuote)
        do {
            try await CalendarService(storageService: storageService).createEvent(meetingID: meetingID, candidateKey: candidate.id, draft: draft)
            isCreated = true
            message = "Created in your default calendar."
        } catch {
            message = error.localizedDescription
        }
    }
}
