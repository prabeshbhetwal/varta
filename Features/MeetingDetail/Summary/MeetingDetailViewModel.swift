import AppKit
import AVFoundation
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
    @Published private(set) var summary: SummaryContent?
    @Published private(set) var isSummaryCurrent = false
    @Published private(set) var outputs: [GeneratedOutput] = []
    @Published private(set) var resumableJobs: [JobRecord] = []
    @Published private(set) var isGeneratingOutputs = false
    @Published private(set) var isTranslating = false
    @Published private(set) var isPreparingPlayback = false
    @Published var languageMode: LanguageMode = .mixed
    @Published var translationLanguage: LanguageMode = .nepali
    @Published private(set) var player: AVPlayer?

    let meetingID: String

    private let storageService: StorageService
    private let memoryManager: MemoryManager
    private var processingTask: Task<Void, Never>?
    private var playbackMediaIDs: [String] = []
    private var pendingSeekSeconds: Double?

    var isProcessing: Bool { isGeneratingTranscript || isGeneratingOutputs || isTranslating }

    init(meetingID: String, storageService: StorageService, memoryManager: MemoryManager) {
        self.meetingID = meetingID
        self.storageService = storageService
        self.memoryManager = memoryManager
    }

    func refresh() async {
        isLoadingContent = true
        errorMessage = nil
        do {
            segments = try await storageService.transcriptSegments(meetingID: meetingID)
            importedMedia = try await storageService.importedMedia(for: meetingID)
            summary = try await storageService.summary(meetingID: meetingID)
            isSummaryCurrent = try await storageService.summaryIsCurrent(meetingID: meetingID)
            outputs = try await storageService.generatedOutputs(meetingID: meetingID)
            resumableJobs = try await storageService.jobs(statuses: [.paused, .failed], type: .transcription)
                .filter { $0.meetingID == meetingID }
            meetingTitle = (try? await storageService.meetingTitle(meetingID: meetingID)) ?? ""
            appSupportDirectoryURL = await storageService.appSupportDirectory()
            recordingsFolderURL = await storageService.recordingsDirectory(meetingID: meetingID)
            if let first = importedMedia.first, let root = appSupportDirectoryURL {
                recordingsFolderURL = root.appendingPathComponent(first.relativePath).deletingLastPathComponent()
            }
        } catch {
            segments = []
            importedMedia = []
            meetingTitle = ""
            errorMessage = error.localizedDescription
        }

        isLoadingContent = false
    }

    func startTranscript(resumeJobID: String? = nil) {
        guard !isProcessing else { return }
        isGeneratingTranscript = true
        processingTask = Task { await generateTranscript(resumeJobID: resumeJobID) }
    }

    private func generateTranscript(resumeJobID: String?) async {

        isGeneratingTranscript = true
        errorMessage = nil
        successMessage = nil
        defer { isGeneratingTranscript = false }

        do {
            if let resumeJobID,
               let checkpoint = try await storageService.processingState(jobID: resumeJobID, stage: "transcription"),
               let blob = checkpoint.checkpointBlob {
                struct SavedLanguage: Decodable { let languageMode: LanguageMode }
                languageMode = try JSONDecoder().decode(SavedLanguage.self, from: Data(blob.utf8)).languageMode
            }
            let media = try await storageService.importedMedia(for: meetingID)
            guard !media.isEmpty else {
                throw NSError(
                    domain: "Varta.Transcript",
                    code: 4001,
                    userInfo: [NSLocalizedDescriptionKey: "No recording file is available for this meeting."]
                )
            }

            let configuration = await localModelConfiguration()
            let transcriptionService = TranscriptionService(
                storageService: storageService,
                memoryManager: memoryManager,
                whisperClient: WhisperCppBridge(configuration: WhisperCppConfiguration(models: configuration))
            )
            _ = try await transcriptionService.transcribeMeeting(
                meetingID: meetingID,
                languageMode: languageMode,
                resumeJobID: resumeJobID
            )
            await refresh()
            successMessage = "Transcript generated."
        } catch is CancellationError {
            await refresh()
            successMessage = "Transcription paused. Completed windows remain saved."
        } catch {
            let message = "Transcript generation failed: \(error.localizedDescription)"
            await refresh()
            errorMessage = message
        }
    }

    func startSummary() {
        guard !isProcessing else { return }
        isGeneratingOutputs = true
        processingTask = Task {
            isGeneratingOutputs = true
            errorMessage = nil
            successMessage = nil
            defer { isGeneratingOutputs = false }
            do {
                let client = MLXLanguageModelClient(configuration: await localModelConfiguration())
                let service = SummariserService(storageService: storageService, memoryManager: memoryManager, client: client)
                _ = try await service.summariseMeeting(meetingID: meetingID)
                await refresh()
                successMessage = "Summary and outputs generated. Review before using them."
            } catch is CancellationError {
                await refresh()
                successMessage = "Generation cancelled. Existing outputs preserved."
            } catch {
                let message = error.localizedDescription
                await refresh()
                errorMessage = message
            }
        }
    }

    func startTranslation() {
        guard !isProcessing else { return }
        isTranslating = true
        processingTask = Task {
            isTranslating = true
            errorMessage = nil
            successMessage = nil
            defer { isTranslating = false }
            do {
                let client = MLXLanguageModelClient(configuration: await localModelConfiguration())
                let service = TranslationService(storageService: storageService, memoryManager: memoryManager, client: client)
                _ = try await service.translateOutputs(meetingID: meetingID, targetLanguage: translationLanguage)
                await refresh()
                successMessage = "Translation ready for review."
            } catch is CancellationError {
                successMessage = "Translation cancelled. Existing outputs preserved."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelProcessing() { processingTask?.cancel() }

    func preparePlayback() async {
        guard !isPreparingPlayback else { return }
        if player != nil && playbackMediaIDs == importedMedia.map(\.id) { return }
        isPreparingPlayback = true
        defer { isPreparingPlayback = false }
        do {
            let root = await storageService.appSupportDirectory()
            let item = try await MediaProcessingService.playbackItem(media: importedMedia, rootDirectory: root)
            player?.pause()
            player = AVPlayer(playerItem: item)
            playbackMediaIDs = importedMedia.map(\.id)
        } catch {
            errorMessage = "Playback unavailable: \(error.localizedDescription)"
        }
    }

    func seek(to seconds: Double) async {
        guard seconds.isFinite && seconds >= 0 else { return }
        pendingSeekSeconds = seconds
        await preparePlayback()
        guard let pendingSeekSeconds else { return }
        _ = await player?.seek(to: CMTime(seconds: pendingSeekSeconds, preferredTimescale: 600))
        player?.play()
    }

    func stopPlayback() { player?.pause() }

    func output(_ type: GeneratedOutputType, language: LanguageMode = .english) -> String? {
        outputs.first { $0.type == type && $0.language == language }?.content
    }

    func calendarCandidates() throws -> [CalendarCandidate] {
        guard let content = output(.calendarCandidates) else { return [] }
        let candidates = try JSONDecoder().decode([CalendarCandidate].self, from: Data(content.utf8))
        for candidate in candidates { try candidate.validate() }
        return candidates
    }

    private func localModelConfiguration() async -> LocalModelConfiguration {
        let defaults = UserDefaults.standard
        let whisper = defaults.string(forKey: "varta.whisperModelPath").flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let languageModel = defaults.string(forKey: "varta.languageModelPath").flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        return LocalModelConfiguration(rootDirectory: await storageService.appSupportDirectory(), whisperOverride: whisper, languageModelOverride: languageModel)
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
