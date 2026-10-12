@preconcurrency import AVFoundation
import Foundation

struct MediaTimelineEntry: Codable, Sendable {
    let mediaID: String
    let relativePath: String
    let startSeconds: Double
    let durationSeconds: Double
}

struct PreparedAudioWindow: Codable, Sendable {
    let relativePath: String
    let startSeconds: Double
    let durationSeconds: Double
}

struct PreparedMeetingAudio: Codable, Sendable {
    let timeline: [MediaTimelineEntry]
    let windows: [PreparedAudioWindow]
    let durationSeconds: Double
}

enum MediaProcessingError: LocalizedError {
    case noAudio
    case invalidMedia(String)
    case durationExceeded
    case insufficientDiskSpace
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudio: return "No readable audio tracks were found."
        case .invalidMedia(let path): return "Media file is missing, invalid, or outside meeting storage: \(path)"
        case .durationExceeded: return "Meeting audio exceeds the supported four-hour timeline. Split the import first."
        case .insufficientDiskSpace: return "Not enough free disk space to prepare meeting audio."
        case .conversionFailed(let message): return "Audio preparation failed: \(message)"
        }
    }
}

actor MediaProcessingService {
    private let rootDirectory: URL
    private let windowDuration: Double

    init(rootDirectory: URL, windowDuration: Double = 30) {
        self.rootDirectory = rootDirectory
        self.windowDuration = windowDuration
    }

    func prepare(media: [ImportedMediaRecord], meetingID: String) async throws -> PreparedMeetingAudio {
        guard windowDuration.isFinite, windowDuration > 0, windowDuration <= 600,
              !meetingID.isEmpty, !meetingID.contains("/"), meetingID != ".", meetingID != ".." else {
            throw MediaProcessingError.invalidMedia(meetingID)
        }
        let assembled = try await Self.assemble(media: media, rootDirectory: rootDirectory)
        let duration = assembled.timeline.map { $0.startSeconds + $0.durationSeconds }.max() ?? 0
        guard duration > 0 else { throw MediaProcessingError.noAudio }
        guard duration <= 4 * 60 * 60 else { throw MediaProcessingError.durationExceeded }
        if let capacity = try rootDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, capacity < Int64(duration * 32_000) + 10_000_000 {
            throw MediaProcessingError.insufficientDiskSpace
        }
        let folder = rootDirectory.appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent(meetingID, isDirectory: true)
            .appendingPathComponent("prepared-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let reader = try AVAssetReader(asset: assembled.composition)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let tracks = assembled.composition.tracks(withMediaType: .audio)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        output.audioMix = assembled.mix
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MediaProcessingError.conversionFailed("Unsupported audio layout.") }
        reader.add(output)
        guard reader.startReading() else {
            throw MediaProcessingError.conversionFailed(reader.error?.localizedDescription ?? "Reader could not start.")
        }
        defer { reader.cancelReading() }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096),
              let samples = buffer.int16ChannelData else {
            throw MediaProcessingError.conversionFailed("Could not allocate PCM conversion buffer.")
        }
        let totalFrames = Int64((duration * 16_000).rounded())
        let framesPerWindow = Int64((windowDuration * 16_000).rounded())
        var frameCursor: Int64 = 0
        var windowFrames: Int64 = 0
        var windowStart: Int64 = 0
        var file: AVAudioFile?
        var fileURL: URL?
        var windows: [PreparedAudioWindow] = []

        func finishWindow() {
            file = nil // Finalise the WAV header before exposing its checkpoint path.
            if let fileURL, windowFrames > 0 {
                let relativePath = String(fileURL.path.dropFirst(rootDirectory.path.count + 1))
                windows.append(PreparedAudioWindow(relativePath: relativePath,
                    startSeconds: Double(windowStart) / 16_000, durationSeconds: Double(windowFrames) / 16_000))
            }
            fileURL = nil
            windowFrames = 0
            windowStart = frameCursor
        }

        func writeFrames(count: Int, block: CMBlockBuffer?, byteOffset: Int) throws {
            var consumed = 0
            while consumed < count, frameCursor < totalFrames {
                try Task.checkCancellation()
                if file == nil {
                    let url = folder.appendingPathComponent("window-\(windows.count).wav")
                    file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
                    fileURL = url
                }
                let amount = min(Int64(count - consumed), 4_096, framesPerWindow - windowFrames, totalFrames - frameCursor)
                guard amount > 0 else { break }
                buffer.frameLength = AVAudioFrameCount(amount)
                if let block {
                    let status = CMBlockBufferCopyDataBytes(block, atOffset: byteOffset + consumed * 2,
                        dataLength: Int(amount) * 2, destination: samples[0])
                    guard status == kCMBlockBufferNoErr else {
                        throw MediaProcessingError.conversionFailed("PCM copy failed (\(status)).")
                    }
                } else {
                    samples[0].update(repeating: 0, count: Int(amount))
                }
                try file?.write(from: buffer)
                consumed += Int(amount)
                frameCursor += amount
                windowFrames += amount
                if windowFrames == framesPerWindow { finishWindow() }
            }
        }

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else {
                throw MediaProcessingError.conversionFailed("Audio reader produced a buffer without PCM data.")
            }
            let frameCount = CMSampleBufferGetNumSamples(sample)
            guard frameCount > 0, CMBlockBufferGetDataLength(block) == frameCount * 2 else {
                throw MediaProcessingError.conversionFailed("Unexpected mono PCM buffer size.")
            }
            let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            guard timestamp.isFinite, timestamp >= 0 else {
                throw MediaProcessingError.conversionFailed("Audio reader produced an invalid timestamp.")
            }
            let sampleStart = Int64((timestamp * 16_000).rounded())
            if sampleStart > frameCursor {
                try writeFrames(count: Int(sampleStart - frameCursor), block: nil, byteOffset: 0)
            }
            let skip = max(0, Int(frameCursor - sampleStart))
            if skip < frameCount {
                try writeFrames(count: frameCount - skip, block: block, byteOffset: skip * 2)
            }
        }
        guard reader.status == .completed else {
            throw MediaProcessingError.conversionFailed(reader.error?.localizedDescription ?? "Audio reader stopped before completion.")
        }
        if frameCursor < totalFrames {
            try writeFrames(count: Int(totalFrames - frameCursor), block: nil, byteOffset: 0)
        }
        finishWindow()
        guard !windows.isEmpty else { throw MediaProcessingError.noAudio }
        return PreparedMeetingAudio(timeline: assembled.timeline, windows: windows, durationSeconds: Double(totalFrames) / 16_000)
    }

    static func playbackItem(media: [ImportedMediaRecord], rootDirectory: URL) async throws -> AVPlayerItem {
        let assembled = try await assemble(media: media, rootDirectory: rootDirectory)
        let item = AVPlayerItem(asset: assembled.composition)
        item.audioMix = assembled.mix
        return item
    }

    static func checkedURL(relativePath: String, rootDirectory: URL) throws -> URL {
        let root = rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains(".."),
              candidate.path.hasPrefix(root.path + "/"), values?.isRegularFile == true,
              (values?.fileSize ?? 0) > 0, FileManager.default.isReadableFile(atPath: candidate.path) else {
            throw MediaProcessingError.invalidMedia(relativePath)
        }
        return candidate
    }

    private static func assemble(media: [ImportedMediaRecord], rootDirectory: URL) async throws
        -> (composition: AVMutableComposition, mix: AVMutableAudioMix, timeline: [MediaTimelineEntry]) {
        guard !media.isEmpty else { throw MediaProcessingError.noAudio }
        let composition = AVMutableComposition()
        var timeline: [MediaTimelineEntry] = []
        var mixParameters: [AVMutableAudioMixInputParameters] = []
        var trackPool: [(track: AVMutableCompositionTrack, endSeconds: Double)] = []
        var intervals: [(Double, Double)] = []
        var cursor: Double = 0
        var legacyOffsets: [Int: Double] = [:]
        var legacyEnds: [Int: Double] = [:]
        // Legacy recorder files lack offsets; group simultaneous sources by their segment index.
        let ordered = media.sorted {
            let lhs = $0.segmentIndex ?? legacySegmentIndex($0.originalFilename ?? $0.relativePath)
            let rhs = $1.segmentIndex ?? legacySegmentIndex($1.originalFilename ?? $1.relativePath)
            if let lhs, let rhs, lhs != rhs { return lhs < rhs }
            if lhs != nil && rhs == nil { return true }
            if lhs == nil && rhs != nil { return false }
            return $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt
        }
        for record in ordered {
            try Task.checkCancellation()
            let url = try checkedURL(relativePath: record.relativePath, rootDirectory: rootDirectory)
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            let duration = CMTimeGetSeconds(try await asset.load(.duration))
            guard !tracks.isEmpty, duration.isFinite, duration > 0 else {
                throw MediaProcessingError.invalidMedia(record.relativePath)
            }
            let index = record.segmentIndex ?? legacySegmentIndex(record.originalFilename ?? record.relativePath)
            let offset: Double
            if let explicit = record.timelineOffsetSeconds {
                guard explicit.isFinite, explicit >= 0 else { throw MediaProcessingError.invalidMedia(record.relativePath) }
                offset = explicit
            } else if let index {
                if let existing = legacyOffsets[index] { offset = existing }
                else {
                    offset = max(cursor, legacyEnds.values.max() ?? 0)
                    legacyOffsets[index] = offset
                }
                legacyEnds[index] = max(legacyEnds[index] ?? 0, offset + duration)
            } else {
                offset = cursor
            }
            cursor = max(cursor, offset + duration)
            guard cursor <= 4 * 60 * 60 else { throw MediaProcessingError.durationExceeded }
            timeline.append(MediaTimelineEntry(mediaID: record.id, relativePath: record.relativePath,
                startSeconds: offset, durationSeconds: duration))
            for track in tracks {
                let range = try await track.load(.timeRange)
                let sourceStart = CMTimeGetSeconds(range.start)
                let sourceEnd = min(CMTimeGetSeconds(range.end), duration)
                guard sourceStart.isFinite, sourceEnd.isFinite, sourceStart >= 0, sourceEnd > sourceStart else {
                    throw MediaProcessingError.invalidMedia(record.relativePath)
                }
                let trackStart = offset + sourceStart
                let trackEnd = offset + sourceEnd
                let destination: AVMutableCompositionTrack
                if let index = trackPool.firstIndex(where: { $0.endSeconds <= trackStart + 0.000_001 }) {
                    destination = trackPool[index].track
                    trackPool[index].endSeconds = trackEnd
                } else {
                    guard let added = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                        throw MediaProcessingError.conversionFailed("Could not create a timeline audio track.")
                    }
                    destination = added
                    trackPool.append((added, trackEnd))
                    mixParameters.append(AVMutableAudioMixInputParameters(track: added))
                }
                try destination.insertTimeRange(CMTimeRange(start: range.start,
                    duration: CMTime(seconds: sourceEnd - sourceStart, preferredTimescale: 16_000)),
                    of: track, at: CMTime(seconds: trackStart, preferredTimescale: 16_000))
                intervals.append((trackStart, trackEnd))
            }
        }
        let audioEnd = CMTimeGetSeconds(composition.duration)
        if cursor > audioEnd {
            composition.insertEmptyTimeRange(CMTimeRange(start: composition.duration,
                duration: CMTime(seconds: cursor - audioEnd, preferredTimescale: 16_000)))
        }
        // Normalise simultaneous sources without attenuating sequential chunks by the total file count.
        let events = intervals.flatMap { [(time: $0.0, change: 1), (time: $0.1, change: -1)] }
            .sorted { $0.time == $1.time ? $0.change < $1.change : $0.time < $1.time }
        var active = 0
        var maximumActive = 1
        for event in events { active += event.change; maximumActive = max(maximumActive, active) }
        for parameter in mixParameters { parameter.setVolume(1 / Float(maximumActive), at: .zero) }
        let mix = AVMutableAudioMix()
        mix.inputParameters = mixParameters
        return (composition, mix, timeline)
    }

    private static func legacySegmentIndex(_ filename: String) -> Int? {
        let name = URL(fileURLWithPath: filename).lastPathComponent
        let pieces = name.split(separator: "-")
        guard pieces.count >= 3, pieces[0] == "segment", ["microphone", "system"].contains(String(pieces[2])) else { return nil }
        return Int(pieces[1])
    }
}
