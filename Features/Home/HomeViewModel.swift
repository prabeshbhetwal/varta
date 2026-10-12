import Foundation

@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var meetings: [MeetingListItem] = []
    @Published var selectedMeetingID: String?
    @Published var isImporting = false
    @Published var isDeleting = false
    @Published var errorMessage: String?
    @Published var searchQuery = ""
    @Published private(set) var searchResults: [TranscriptSearchResult] = []
    @Published var selectedSearchResult: TranscriptSearchResult?
    @Published private(set) var recoverableRecordingJobs: [JobRecord] = []
    @Published private(set) var meetingContentRevisions: [String: Int] = [:]

    private let storageService: StorageService
    private let importService: ImportPipelineService

    init(storageService: StorageService) {
        self.storageService = storageService

        self.importService = ImportPipelineService(storageService: storageService)
    }

    func refreshMeetings() async {
        do {
            meetings = try await storageService.listMeetings()
            recoverableRecordingJobs = try await storageService.jobs(statuses: [.paused, .failed], type: .recording)
            if selectedMeetingID == nil || !meetings.contains(where: { $0.id == selectedMeetingID }) {
                selectedMeetingID = meetings.first?.id
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshMeetings(select meetingID: String?) async {
        await refreshMeetings()

        guard let meetingID else {
            return
        }

        if meetings.contains(where: { $0.id == meetingID }) {
            selectedMeetingID = meetingID
            meetingContentRevisions[meetingID, default: 0] += 1
        }
    }

    func importMediaFile(at url: URL) async {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        do {
            let meetingID = try await importService.importMedia(from: url, languageMode: .mixed)
            await refreshMeetings()
            selectedMeetingID = meetingID
        } catch {
            errorMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    func searchTranscripts() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            selectedSearchResult = nil
            return
        }
        do {
            let results = try await storageService.searchTranscript(query: query)
            try Task.checkCancellation()
            guard query == searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            searchResults = results
        } catch is CancellationError {
        } catch {
            errorMessage = "Search failed: \(error.localizedDescription)"
        }
    }

    func selectSearchResult(_ result: TranscriptSearchResult) {
        selectedSearchResult = result
        selectedMeetingID = result.meetingID
    }

    func deleteMeeting(meetingID: String) async {
        guard !isDeleting else {
            return
        }

        isDeleting = true
        defer { isDeleting = false }

        do {
            try await storageService.deleteMeetingAndFiles(meetingID: meetingID)
            errorMessage = nil
            await refreshMeetings()
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
            await refreshMeetings()
        }
    }

    func selectedMeetingTitle() -> String? {
        guard let selectedMeetingID else {
            return nil
        }

        return meetings.first(where: { $0.id == selectedMeetingID })?.title
    }
}
