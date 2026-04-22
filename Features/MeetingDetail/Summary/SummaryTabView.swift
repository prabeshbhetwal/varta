import AVFoundation
import SwiftUI

struct SummaryTabView: View {
    @ObservedObject var viewModel: MeetingDetailViewModel
    @StateObject private var playbackController = RecordingPlaybackController()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Recording Transcript")
                    .font(.title3)
                    .bold()
                Spacer()
                Button("Generate Transcript") {
                    let preferredMediaID = playbackController.selectionForDisplay(media: viewModel.importedMedia)
                    Task {
                        await viewModel.generateTranscript(preferredMediaID: preferredMediaID)
                    }
                }
                .disabled(viewModel.importedMedia.isEmpty || viewModel.isGeneratingTranscript)
            }

            HStack(spacing: 10) {
                Button("Copy Transcript") {
                    viewModel.copyTranscriptToClipboard()
                }
                .disabled(viewModel.segments.isEmpty)

                Button("Export Transcript") {
                    viewModel.exportTranscript()
                }
                .disabled(viewModel.segments.isEmpty)
            }

            GroupBox("Playback") {
                VStack(alignment: .leading, spacing: 10) {
                    if viewModel.importedMedia.isEmpty {
                        Text("No recording files available for playback.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("File", selection: Binding<String?>(
                            get: { playbackController.selectionForDisplay(media: viewModel.importedMedia) },
                            set: { playbackController.select(mediaID: $0) }
                        )) {
                            Text("Select File")
                                .tag(String?.none)

                            ForEach(viewModel.importedMedia) { media in
                                Text(media.originalFilename ?? URL(fileURLWithPath: media.relativePath).lastPathComponent)
                                    .tag(Optional(media.id))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)

                        HStack(spacing: 10) {
                            Button {
                                playbackController.play(
                                    media: viewModel.importedMedia,
                                    appSupportDirectoryURL: viewModel.appSupportDirectoryURL
                                )
                            } label: {
                                Label("Play", systemImage: "play.fill")
                            }
                            .disabled(playbackController.selectedMediaID == nil)

                            Button {
                                playbackController.pause()
                            } label: {
                                Label("Pause", systemImage: "pause.fill")
                            }
                            .disabled(!playbackController.isPlaying)

                            Button {
                                playbackController.stop()
                            } label: {
                                Label("Stop", systemImage: "stop.fill")
                            }
                            .disabled(playbackController.currentTime <= 0 && !playbackController.isPlaying)
                        }
                        .buttonStyle(.bordered)

                        Slider(
                            value: Binding(
                                get: { playbackController.currentTime },
                                set: { playbackController.seek(to: $0) }
                            ),
                            in: 0...max(playbackController.duration, 1),
                            onEditingChanged: { _ in }
                        )
                        .disabled(playbackController.duration <= 0)

                        HStack {
                            Text(formatTime(playbackController.currentTime))
                            Spacer()
                            Text(formatTime(playbackController.duration))
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }

                    if let message = playbackController.message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Local Recording Storage") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(viewModel.recordingsFolderURL?.path ?? "Unavailable")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    HStack(spacing: 10) {
                        Button("Open Recording Folder") {
                            viewModel.openRecordingsFolderInFinder()
                        }
                        Text("\(viewModel.importedMedia.count) file(s)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            TranscriptTabView(viewModel: viewModel)
        }
        .padding(16)
        .onAppear {
            playbackController.configure(media: viewModel.importedMedia)
        }
        .onChange(of: viewModel.importedMedia.map(\.id)) {
            playbackController.configure(media: viewModel.importedMedia)
        }
        .onDisappear {
            playbackController.stop()
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded()), 0)
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", minutes, secs)
    }
}

@MainActor
private final class RecordingPlaybackController: NSObject, ObservableObject {
    @Published var selectedMediaID: String?
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published var message: String?

    private var player: AVAudioPlayer?
    private var loadedMediaID: String?
    private var progressTask: Task<Void, Never>?

    deinit {
        progressTask?.cancel()
    }

    func selectionForDisplay(media: [ImportedMediaRecord]) -> String? {
        guard let selectedMediaID else {
            return nil
        }
        return media.contains(where: { $0.id == selectedMediaID }) ? selectedMediaID : nil
    }

    func configure(media: [ImportedMediaRecord]) {
        if let selectedMediaID, media.contains(where: { $0.id == selectedMediaID }) {
            return
        }

        selectedMediaID = media.first?.id
        loadedMediaID = nil
        message = nil
        stop()
    }

    func select(mediaID: String?) {
        guard selectedMediaID != mediaID else {
            return
        }

        selectedMediaID = mediaID
        loadedMediaID = nil
        message = nil
        stop()
    }

    func play(media: [ImportedMediaRecord], appSupportDirectoryURL: URL?) {
        guard let selectedMediaID else {
            message = "Select a recording file to play."
            return
        }
        guard let mediaRecord = media.first(where: { $0.id == selectedMediaID }) else {
            message = "Selected file is no longer available."
            return
        }
        guard let appSupportDirectoryURL else {
            message = "Storage location is unavailable."
            return
        }

        let fileURL = appSupportDirectoryURL.appendingPathComponent(mediaRecord.relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            message = "File not found: \(fileURL.lastPathComponent)"
            return
        }

        do {
            if loadedMediaID != selectedMediaID {
                let player = try AVAudioPlayer(contentsOf: fileURL)
                guard player.duration > 0 else {
                    message = "This file contains no playable audio: \(fileURL.lastPathComponent)"
                    stop()
                    return
                }
                _ = player.prepareToPlay()
                self.player = player
                loadedMediaID = selectedMediaID
                duration = player.duration
                currentTime = player.currentTime
            }

            guard let player else {
                message = "Unable to initialize playback."
                return
            }

            guard player.play() else {
                message = "Playback could not start for \(mediaRecord.originalFilename ?? fileURL.lastPathComponent)."
                stop()
                return
            }
            isPlaying = true
            message = "Playing \(mediaRecord.originalFilename ?? fileURL.lastPathComponent)"
            startProgressTask()
        } catch {
            message = "Playback failed: \(error.localizedDescription)"
            stop()
        }
    }

    func pause() {
        guard let player else {
            return
        }

        player.pause()
        isPlaying = false
        currentTime = player.currentTime
        progressTask?.cancel()
    }

    func stop() {
        player?.stop()
        if let player {
            player.currentTime = 0
        }

        isPlaying = false
        currentTime = 0
        progressTask?.cancel()
    }

    func seek(to seconds: Double) {
        guard let player else {
            return
        }
        let clamped = min(max(seconds, 0), max(player.duration, 0))
        player.currentTime = clamped
        currentTime = clamped
    }

    private func startProgressTask() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }
                guard let player = self.player else {
                    return
                }

                self.currentTime = player.currentTime
                self.duration = player.duration

                if !player.isPlaying && self.isPlaying {
                    self.isPlaying = false
                    if self.currentTime >= max(self.duration - 0.1, 0) {
                        self.currentTime = self.duration
                        self.message = "Playback complete."
                    }
                    return
                }

                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }
}
