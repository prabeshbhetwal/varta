import Foundation

@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var meetings: [MeetingListItem] = []
    @Published var selectedMeetingID: String?
    @Published var isImporting = false
    @Published var errorMessage: String?

    private let storageService: StorageService
    private let importService: ImportPipelineService

    init(storageService: StorageService) {
        self.storageService = storageService

        let memoryManager = MemoryManager()
        let transcriptionService = TranscriptionService(storageService: storageService, memoryManager: memoryManager)
        let summariserService = SummariserService(storageService: storageService, memoryManager: memoryManager)
        self.importService = ImportPipelineService(
            storageService: storageService,
            transcriptionService: transcriptionService,
            summariserService: summariserService
        )
    }

    func refreshMeetings() async {
        do {
            meetings = try await storageService.listMeetings()
            if selectedMeetingID == nil {
                selectedMeetingID = meetings.first?.id
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importMediaFile(at url: URL) async {
        isImporting = true
        defer { isImporting = false }

        do {
            let meetingID = try await importService.importMedia(from: url, languageMode: .mixed)
            await refreshMeetings()
            selectedMeetingID = meetingID
        } catch {
            errorMessage = "Import failed: \(error.localizedDescription)"
        }
    }
}
