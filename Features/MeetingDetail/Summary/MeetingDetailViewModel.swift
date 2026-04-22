import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class MeetingDetailViewModel: ObservableObject {
    @Published private(set) var segments: [TranscriptSegment] = []
    @Published private(set) var importedMedia: [ImportedMediaRecord] = []
    @Published private(set) var appSupportDirectoryURL: URL?
    @Published private(set) var recordingsFolderURL: URL?
    @Published private(set) var isLoadingContent = false
    @Published private(set) var isGeneratingTranscript = false
    @Published var errorMessage: String?
    @Published var successMessage: String?
    @Published private(set) var meetingTitle: String = ""

    let meetingID: String

    private let storageService: StorageService
    private let transcriptionService: TranscriptionService

    init(meetingID: String, storageService: StorageService) {
        self.meetingID = meetingID
        self.storageService = storageService

        let memoryManager = MemoryManager()
        self.transcriptionService = TranscriptionService(storageService: storageService, memoryManager: memoryManager)
    }

    func refresh() async {
        isLoadingContent = true
        errorMessage = nil
        do {
            segments = try await storageService.transcriptSegments(meetingID: meetingID)
            importedMedia = try await storageService.importedMedia(for: meetingID)
            meetingTitle = (try? await storageService.meetingTitle(meetingID: meetingID)) ?? ""
            appSupportDirectoryURL = await storageService.appSupportDirectory()
            recordingsFolderURL = await storageService.recordingsDirectory(meetingID: meetingID)
        } catch {
            segments = []
            importedMedia = []
            meetingTitle = ""
            errorMessage = error.localizedDescription
        }

        isLoadingContent = false
    }

    func generateTranscript(preferredMediaID: String? = nil) async {
        guard !isGeneratingTranscript else {
            return
        }

        isGeneratingTranscript = true
        errorMessage = nil
        successMessage = nil
        defer { isGeneratingTranscript = false }

        do {
            let media = try await storageService.importedMedia(for: meetingID)
            guard !media.isEmpty else {
                throw NSError(
                    domain: "Varta.Transcript",
                    code: 4001,
                    userInfo: [NSLocalizedDescriptionKey: "No recording file is available for this meeting."]
                )
            }

            let mediaToTranscribe = mediaForTranscription(from: media, preferredMediaID: preferredMediaID)
            let mediaURL = await storageService.resolvedImportedMediaURL(relativePath: mediaToTranscribe.relativePath)
            guard FileManager.default.fileExists(atPath: mediaURL.path) else {
                throw NSError(
                    domain: "Varta.Transcript",
                    code: 4002,
                    userInfo: [NSLocalizedDescriptionKey: "Recording file is missing: \(mediaURL.lastPathComponent)"]
                )
            }

            _ = try await transcriptionService.transcribeMeeting(
                meetingID: meetingID,
                mediaURL: mediaURL,
                languageMode: .mixed
            )
            await refresh()
            successMessage = "Transcript generated."
        } catch {
            errorMessage = "Transcript generation failed: \(error.localizedDescription)"
        }
    }

    func transcriptEmptyMessage() -> String {
        if isLoadingContent {
            return "Loading transcript..."
        }
        return "No transcript yet. Generate transcript for this recording."
    }

    func transcriptText() -> String {
        segments
            .map { segment in
                "[\(timecode(segment.startSeconds)) - \(timecode(segment.endSeconds))] \(segment.effectiveText)"
            }
            .joined(separator: "\n")
    }

    func copyTranscriptToClipboard() {
        let transcript = transcriptText().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            errorMessage = "No transcript to copy."
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(transcript, forType: .string)
        successMessage = "Transcript copied."
    }

    func exportTranscript() {
        let transcript = transcriptText().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            errorMessage = "No transcript to export."
            return
        }

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType.plainText]
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = "varta-transcript-\(meetingID.prefix(8)).txt"
        savePanel.title = "Export Transcript"
        savePanel.message = "Choose where to save the transcript."

        guard savePanel.runModal() == .OK, let destinationURL = savePanel.url else {
            return
        }

        do {
            try transcript.write(to: destinationURL, atomically: true, encoding: .utf8)
            successMessage = "Transcript exported."
        } catch {
            errorMessage = "Failed to export transcript: \(error.localizedDescription)"
        }
    }

    func openRecordingsFolderInFinder() {
        guard let recordingsFolderURL else {
            return
        }

        guard FileManager.default.fileExists(atPath: recordingsFolderURL.path) else {
            errorMessage = "Recording folder not found for this meeting."
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([recordingsFolderURL])
    }

    func openImportedMediaInFinder(_ record: ImportedMediaRecord) {
        Task {
            let url = await storageService.resolvedImportedMediaURL(relativePath: record.relativePath)
            await MainActor.run {
                guard FileManager.default.fileExists(atPath: url.path) else {
                    self.errorMessage = "Recording file is missing: \(url.lastPathComponent)"
                    return
                }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    func updateSegmentCorrection(segmentID: Int64, correctedText: String) async {
        do {
            try await storageService.updateTranscriptCorrection(segmentID: segmentID, correctedText: correctedText)
            await refresh()
        } catch {
            errorMessage = "Could not save correction: \(error.localizedDescription)"
        }
    }

    func setSegmentLock(segmentID: Int64, isLocked: Bool) async {
        do {
            try await storageService.setTranscriptSegmentLock(segmentID: segmentID, isLocked: isLocked)
            await refresh()
        } catch {
            errorMessage = "Could not update lock: \(error.localizedDescription)"
        }
    }

    private func mediaForTranscription(from media: [ImportedMediaRecord], preferredMediaID: String?) -> ImportedMediaRecord {
        if let preferredMediaID,
           let selected = media.first(where: { $0.id == preferredMediaID }) {
            return selected
        }

        return media.sorted(by: { ($0.durationSeconds ?? 0) > ($1.durationSeconds ?? 0) }).first ?? media[0]
    }

    private func timecode(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded()), 0)
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", minutes, secs)
    }
    
    func meetingDisplayTitle() -> String {
        meetingTitle.isEmpty ? "Recording" : meetingTitle
    }
}
