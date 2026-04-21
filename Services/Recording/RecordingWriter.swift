@preconcurrency import AVFoundation
import Foundation

final class RecordingWriter: @unchecked Sendable {
    enum WriterError: Error {
        case inputNotReady
        case failedToCreateWriter
        case failedToStartWriter
        case failedToFinishWriting(String)
        case invalidSampleBuffer
        case incompatibleAudioFormat
    }

    private struct AudioFormatSignature: Equatable {
        let formatID: UInt32
        let formatFlags: UInt32
        let sampleRate: Float64
        let channels: UInt32
        let bitsPerChannel: UInt32
        let bytesPerFrame: UInt32
        let framesPerPacket: UInt32
    }

    private let queue = DispatchQueue(label: "com.varta.recording.writer", qos: .userInitiated)
    private var writer: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var firstPTS: CMTime = .invalid
    private var lastPTS: CMTime = .zero
    private var hasStartedSession = false
    private var expectedFormat: AudioFormatSignature?

    private(set) var outputURL: URL?

    func startWriting(to outputURL: URL) throws {
        self.outputURL = outputURL
        firstPTS = .invalid
        lastPTS = .zero
        hasStartedSession = false
        expectedFormat = nil
        audioInput = nil
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
    }

    func append(sampleBuffer: CMSampleBuffer) throws {
        try queue.sync {
            guard let writer else {
                throw WriterError.failedToCreateWriter
            }

            if writer.status == .failed {
                throw WriterError.failedToFinishWriting(writer.error?.localizedDescription ?? "unknown")
            }

            guard writer.status == .unknown || writer.status == .writing else {
                return
            }

            guard CMSampleBufferDataIsReady(sampleBuffer) else {
                throw WriterError.invalidSampleBuffer
            }

            guard let (formatDescription, signature) = audioFormat(from: sampleBuffer) else {
                throw WriterError.invalidSampleBuffer
            }

            if let expectedFormat {
                if expectedFormat != signature {
                    throw WriterError.incompatibleAudioFormat
                }
            } else {
                expectedFormat = signature
            }

            if audioInput == nil {
                let outputSettings = aacOutputSettings(from: signature)
                let input = AVAssetWriterInput(
                    mediaType: .audio,
                    outputSettings: outputSettings,
                    sourceFormatHint: formatDescription
                )
                input.expectsMediaDataInRealTime = true

                guard writer.canAdd(input) else {
                    throw WriterError.failedToCreateWriter
                }

                writer.add(input)
                guard writer.startWriting() else {
                    throw WriterError.failedToStartWriter
                }
                audioInput = input
            }

            guard let audioInput else {
                throw WriterError.failedToCreateWriter
            }

            let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard presentation != .invalid else {
                throw WriterError.invalidSampleBuffer
            }

            if !hasStartedSession {
                writer.startSession(atSourceTime: presentation)
                hasStartedSession = true
                firstPTS = presentation
            }

            if !audioInput.isReadyForMoreMediaData {
                throw WriterError.inputNotReady
            }

            if presentation < lastPTS {
                throw WriterError.inputNotReady
            }

            if !audioInput.append(sampleBuffer) {
                throw WriterError.failedToFinishWriting(writer.error?.localizedDescription ?? "append failed")
            }

            lastPTS = presentation
        }
    }

    func finishWriting() async throws -> Double {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard let writer = self.writer else {
                    continuation.resume(returning: 0)
                    return
                }

                if writer.status == .unknown {
                    cleanup()
                    continuation.resume(returning: 0)
                    return
                }

                audioInput?.markAsFinished()
                writer.finishWriting { [weak self] in
                    guard let self else {
                        continuation.resume(returning: 0)
                        return
                    }

                    let status = self.writer?.status ?? .unknown
                    let errorDescription = self.writer?.error?.localizedDescription ?? "unknown"
                    let duration: Double
                    if self.hasStartedSession {
                        duration = max(CMTimeGetSeconds(self.lastPTS - self.firstPTS), 0)
                    } else {
                        duration = 0
                    }

                    self.cleanup()

                    if status == .completed || status == .cancelled {
                        continuation.resume(returning: duration)
                    } else {
                        continuation.resume(throwing: WriterError.failedToFinishWriting(errorDescription))
                    }
                }
            }
        }
    }

    private func audioFormat(from sampleBuffer: CMSampleBuffer) -> (CMFormatDescription, AudioFormatSignature)? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let basicDescriptionPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else {
            return nil
        }

        let asbd = basicDescriptionPointer.pointee
        let signature = AudioFormatSignature(
            formatID: asbd.mFormatID,
            formatFlags: asbd.mFormatFlags,
            sampleRate: asbd.mSampleRate,
            channels: asbd.mChannelsPerFrame,
            bitsPerChannel: asbd.mBitsPerChannel,
            bytesPerFrame: asbd.mBytesPerFrame,
            framesPerPacket: asbd.mFramesPerPacket
        )

        return (formatDescription, signature)
    }

    private func aacOutputSettings(from signature: AudioFormatSignature) -> [String: Any] {
        let channelCount = max(Int(signature.channels), 1)
        let bitRate = max(channelCount * 64_000, 64_000)
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: signature.sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: bitRate,
        ]
    }

    private func cleanup() {
        writer = nil
        audioInput = nil
        expectedFormat = nil
        hasStartedSession = false
        firstPTS = .invalid
        lastPTS = .zero
    }
}

extension RecordingWriter.WriterError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .inputNotReady:
            return "Writer input is temporarily backpressured."
        case .failedToCreateWriter:
            return "Failed to create AVAssetWriter input."
        case .failedToStartWriter:
            return "Failed to start AVAssetWriter session."
        case .failedToFinishWriting(let details):
            return "Failed to finish writing audio: \(details)"
        case .invalidSampleBuffer:
            return "Received an invalid audio sample buffer from capture pipeline."
        case .incompatibleAudioFormat:
            return "Audio source format changed or mismatched during capture."
        }
    }
}
