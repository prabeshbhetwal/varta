@preconcurrency import AVFoundation
import Foundation

final class RecordingWriter: @unchecked Sendable {
    enum WriterError: Error {
        case inputNotReady
        case failedToCreateWriter
        case failedToStartWriter
        case failedToFinishWriting(String)
        case invalidSampleBuffer
    }

    private let queue = DispatchQueue(label: "com.varta.recording.writer", qos: .userInitiated)
    private var writer: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var startUptimeNanos: UInt64 = 0
    private var lastPTS: CMTime = .zero

    private(set) var outputURL: URL?

    func startWriting(to outputURL: URL) throws {
        self.outputURL = outputURL
        startUptimeNanos = DispatchTime.now().uptimeNanoseconds
        lastPTS = .zero

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]

        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw WriterError.failedToCreateWriter
        }

        writer.add(input)
        guard writer.startWriting() else {
            throw WriterError.failedToStartWriter
        }

        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.audioInput = input
    }

    func append(sampleBuffer: CMSampleBuffer) throws {
        try queue.sync {
            guard let writer, let audioInput else {
                throw WriterError.failedToCreateWriter
            }

            guard writer.status == .writing else {
                if writer.status == .failed {
                    throw WriterError.failedToFinishWriting(writer.error?.localizedDescription ?? "unknown")
                }
                return
            }

            guard CMSampleBufferDataIsReady(sampleBuffer) else {
                throw WriterError.invalidSampleBuffer
            }

            if !audioInput.isReadyForMoreMediaData {
                // Backpressure drop keeps in-memory usage bounded.
                throw WriterError.inputNotReady
            }

            let nowNanos = DispatchTime.now().uptimeNanoseconds
            let elapsedNanos = nowNanos > startUptimeNanos ? nowNanos - startUptimeNanos : 0
            var presentation = CMTime(value: CMTimeValue(elapsedNanos), timescale: 1_000_000_000)

            if presentation <= lastPTS {
                presentation = lastPTS + CMTime(value: 1, timescale: 100)
            }
            lastPTS = presentation

            var timing = CMSampleTimingInfo(
                duration: CMSampleBufferGetDuration(sampleBuffer),
                presentationTimeStamp: presentation,
                decodeTimeStamp: .invalid
            )

            var adjusted: CMSampleBuffer?
            let status = CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: sampleBuffer,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleBufferOut: &adjusted
            )

            guard status == noErr, let adjusted else {
                throw WriterError.invalidSampleBuffer
            }

            if !audioInput.append(adjusted) {
                throw WriterError.failedToFinishWriting(writer.error?.localizedDescription ?? "append failed")
            }
        }
    }

    func finishWriting() async throws -> Double {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard let writer = self.writer, let audioInput = self.audioInput else {
                    continuation.resume(returning: 0)
                    return
                }

                audioInput.markAsFinished()
                writer.finishWriting { [weak self] in
                    guard let self else {
                        continuation.resume(returning: 0)
                        return
                    }

                    let status = self.writer?.status ?? .unknown
                    let errorDescription = self.writer?.error?.localizedDescription ?? "unknown"
                    self.writer = nil
                    self.audioInput = nil

                    if status == .completed {
                        let duration = CMTimeGetSeconds(self.lastPTS)
                        continuation.resume(returning: max(duration, 0))
                    } else {
                        continuation.resume(throwing: WriterError.failedToFinishWriting(errorDescription))
                    }
                }
            }
        }
    }
}
