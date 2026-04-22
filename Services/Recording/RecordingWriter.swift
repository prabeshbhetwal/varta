@preconcurrency import AVFoundation
import Foundation

final class RecordingWriter: @unchecked Sendable {
    enum WriterError: Error {
        case inputNotReady
        case failedToCreateWriter
        case failedToStartWriter
        case failedToFinishWriting(String)
        case invalidSampleBuffer(String)
        case unsupportedAudioFormat(String)
    }

    private let queue = DispatchQueue(label: "com.varta.recording.writer", qos: .userInitiated)
    private var writer: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var expectedInputSignature: InputSignature?
    private var firstPTS: CMTime = .invalid
    private var lastPTS: CMTime = .zero
    private var hasStartedSession = false

    private(set) var outputURL: URL?

    private struct InputSignature: Equatable {
        let sampleRate: Double
        let channelCount: Int
    }

    private struct NormalizedBuffer {
        let sampleBuffer: CMSampleBuffer
        let formatDescription: CMAudioFormatDescription
        let asbd: AudioStreamBasicDescription

        var signature: InputSignature {
            InputSignature(sampleRate: asbd.mSampleRate, channelCount: Int(asbd.mChannelsPerFrame))
        }
    }

    func startWriting(to outputURL: URL) throws {
        self.outputURL = outputURL
        firstPTS = .invalid
        lastPTS = .zero
        hasStartedSession = false
        expectedInputSignature = nil
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
                throw WriterError.invalidSampleBuffer("CMSampleBuffer data is not ready.")
            }

            let normalizedBuffer = try normalize(sampleBuffer: sampleBuffer)
            if let expectedInputSignature, expectedInputSignature != normalizedBuffer.signature {
                throw WriterError.unsupportedAudioFormat(
                    "Audio format changed mid-stream. Expected \(expectedInputSignature.channelCount)ch @ \(expectedInputSignature.sampleRate)Hz, got \(normalizedBuffer.signature.channelCount)ch @ \(normalizedBuffer.signature.sampleRate)Hz."
                )
            }

            if audioInput == nil {
                let settings = aacOutputSettings(
                    sampleRate: normalizedBuffer.asbd.mSampleRate,
                    channelCount: Int(normalizedBuffer.asbd.mChannelsPerFrame)
                )
                guard writer.canApply(outputSettings: settings, forMediaType: .audio) else {
                    throw WriterError.failedToCreateWriter
                }
                let input = AVAssetWriterInput(
                    mediaType: .audio,
                    outputSettings: settings
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
                expectedInputSignature = normalizedBuffer.signature
            }

            guard let audioInput else {
                throw WriterError.failedToCreateWriter
            }

            let normalizedSampleBuffer = normalizedBuffer.sampleBuffer
            let presentation = CMSampleBufferGetPresentationTimeStamp(normalizedSampleBuffer)
            guard presentation != .invalid else {
                throw WriterError.invalidSampleBuffer("Missing presentation timestamp.")
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

            if !audioInput.append(normalizedSampleBuffer) {
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

    private func aacOutputSettings(sampleRate: Double, channelCount: Int) -> [String: Any] {
        let sanitizedChannels = max(1, min(channelCount, 2))
        let sanitizedSampleRate: Double
        if sampleRate.isFinite {
            sanitizedSampleRate = min(max(sampleRate, 8_000), 96_000)
        } else {
            sanitizedSampleRate = 48_000
        }
        let bitRate = max(sanitizedChannels * 64_000, 64_000)
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sanitizedSampleRate,
            AVNumberOfChannelsKey: sanitizedChannels,
            AVEncoderBitRateKey: bitRate,
        ]
    }

    private func normalize(sampleBuffer: CMSampleBuffer) throws -> NormalizedBuffer {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let basicDescriptionPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else {
            throw WriterError.invalidSampleBuffer("Missing audio format description.")
        }

        guard CMFormatDescriptionGetMediaType(formatDescription) == kCMMediaType_Audio else {
            throw WriterError.invalidSampleBuffer("Received non-audio sample buffer.")
        }

        let asbd = basicDescriptionPointer.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM else {
            throw WriterError.unsupportedAudioFormat("Only linear PCM input is supported, format id=\(asbd.mFormatID).")
        }

        guard asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 else {
            throw WriterError.invalidSampleBuffer("Invalid sample rate or channel count in audio format.")
        }
        guard asbd.mChannelsPerFrame <= 2 else {
            throw WriterError.unsupportedAudioFormat("Only mono or stereo input is supported, got \(asbd.mChannelsPerFrame) channels.")
        }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else {
            throw WriterError.invalidSampleBuffer("Audio buffer contains zero frames.")
        }

        guard CMSampleBufferGetTotalSampleSize(sampleBuffer) > 0 else {
            throw WriterError.invalidSampleBuffer("Audio buffer contains no sample data.")
        }

        let extractedAudio = try extractAudioBufferList(sampleBuffer: sampleBuffer, asbd: asbd)
        let normalizedData = try normalizeAudioData(
            buffers: extractedAudio.buffers,
            asbd: asbd,
            frameCount: frameCount
        )

        return try makeSampleBuffer(
            data: normalizedData,
            originalSampleBuffer: sampleBuffer,
            sampleRate: asbd.mSampleRate,
            channelCount: Int(asbd.mChannelsPerFrame),
            frameCount: frameCount
        )
    }

    private func extractAudioBufferList(
        sampleBuffer: CMSampleBuffer,
        asbd: AudioStreamBasicDescription
    ) throws -> (buffers: [AudioBuffer], blockBuffer: CMBlockBuffer?) {
        var audioBufferListSize = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &audioBufferListSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: nil
        )
        guard status == noErr, audioBufferListSize > 0 else {
            throw WriterError.invalidSampleBuffer("AudioBufferList size query failed with OSStatus \(status).")
        }

        let minimumBufferCount = ((asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0)
            ? max(Int(asbd.mChannelsPerFrame), 1)
            : 1
        let minimumSize = MemoryLayout<AudioBufferList>.size + max(0, minimumBufferCount - 1) * MemoryLayout<AudioBuffer>.size
        audioBufferListSize = max(audioBufferListSize, minimumSize)

        let allocated = UnsafeMutableRawPointer.allocate(
            byteCount: audioBufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer {
            allocated.deallocate()
        }
        allocated.initializeMemory(as: UInt8.self, repeating: 0, count: audioBufferListSize)

        let audioBufferList = allocated.assumingMemoryBound(to: AudioBufferList.self)
        var blockBuffer: CMBlockBuffer?
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: audioBufferListSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else {
            throw WriterError.invalidSampleBuffer("AudioBufferList extraction failed with OSStatus \(status).")
        }

        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard buffers.contains(where: { $0.mData != nil && $0.mDataByteSize > 0 }) else {
            throw WriterError.invalidSampleBuffer("AudioBufferList extraction produced no readable audio buffers.")
        }

        return (Array(buffers), blockBuffer)
    }

    private func normalizeAudioData(
        buffers: [AudioBuffer],
        asbd: AudioStreamBasicDescription,
        frameCount: Int
    ) throws -> Data {
        let channelCount = Int(asbd.mChannelsPerFrame)
        let bitsPerChannel = Int(asbd.mBitsPerChannel)
        let bytesPerSample = max(bitsPerChannel / 8, 1)
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInteger = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let isBigEndian = (asbd.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0

        guard channelCount == 1 || channelCount == 2 else {
            throw WriterError.unsupportedAudioFormat("Only mono or stereo input is supported, got \(channelCount) channels.")
        }
        guard (isFloat && bitsPerChannel == 32) || (isSignedInteger && bitsPerChannel == 16) else {
            throw WriterError.unsupportedAudioFormat("Unsupported PCM layout: \(bitsPerChannel)-bit \(isFloat ? "float" : "integer").")
        }

        var output = Data(count: frameCount * channelCount * MemoryLayout<Int16>.size)
        try output.withUnsafeMutableBytes { outputBytes in
            guard let outputBase = outputBytes.baseAddress else {
                throw WriterError.invalidSampleBuffer("Could not allocate normalized audio output.")
            }
            let outputSamples = outputBase.assumingMemoryBound(to: Int16.self)

            for frame in 0..<frameCount {
                for channel in 0..<channelCount {
                    let sourceBufferIndex = isNonInterleaved ? channel : 0
                    guard sourceBufferIndex < buffers.count,
                          let sourceData = buffers[sourceBufferIndex].mData
                    else {
                        throw WriterError.invalidSampleBuffer("Missing audio data for channel \(channel).")
                    }

                    let byteOffset = isNonInterleaved
                        ? frame * bytesPerSample
                        : (frame * channelCount + channel) * bytesPerSample

                    guard byteOffset + bytesPerSample <= Int(buffers[sourceBufferIndex].mDataByteSize) else {
                        throw WriterError.invalidSampleBuffer("Audio buffer is shorter than expected.")
                    }

                    let sourcePointer = sourceData.advanced(by: byteOffset)
                    let sample: Int16
                    if isFloat {
                        var value = sourcePointer.loadUnaligned(as: Float.self)
                        value = min(max(value, -1), 1)
                        sample = Int16((value * Float(Int16.max)).rounded())
                    } else {
                        let rawSample = sourcePointer.loadUnaligned(as: Int16.self)
                        sample = isBigEndian ? Int16(bigEndian: rawSample) : Int16(littleEndian: rawSample)
                    }

                    outputSamples[frame * channelCount + channel] = sample
                }
            }
        }

        return output
    }

    private func makeSampleBuffer(
        data: Data,
        originalSampleBuffer: CMSampleBuffer,
        sampleRate: Double,
        channelCount: Int,
        frameCount: Int
    ) throws -> NormalizedBuffer {
        var normalizedASBD = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channelCount * MemoryLayout<Int16>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channelCount * MemoryLayout<Int16>.size),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: UInt32(MemoryLayout<Int16>.size * 8),
            mReserved: 0
        )

        var normalizedFormatDescription: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &normalizedASBD,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &normalizedFormatDescription
        )
        guard status == noErr, let normalizedFormatDescription else {
            throw WriterError.invalidSampleBuffer("Could not create normalized audio format description. OSStatus \(status).")
        }

        var blockBuffer: CMBlockBuffer?
        status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else {
            throw WriterError.invalidSampleBuffer("Could not create normalized audio block buffer. OSStatus \(status).")
        }

        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                throw WriterError.invalidSampleBuffer("Normalized audio data is empty.")
            }

            let replaceStatus = CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
            guard replaceStatus == noErr else {
                throw WriterError.invalidSampleBuffer("Could not copy normalized audio data. OSStatus \(replaceStatus).")
            }
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate.rounded())),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(originalSampleBuffer),
            decodeTimeStamp: .invalid
        )
        let sampleSize = channelCount * MemoryLayout<Int16>.size
        var normalizedSampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: normalizedFormatDescription,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: [sampleSize],
            sampleBufferOut: &normalizedSampleBuffer
        )
        guard status == noErr, let normalizedSampleBuffer else {
            throw WriterError.invalidSampleBuffer("Could not create normalized sample buffer. OSStatus \(status).")
        }

        return NormalizedBuffer(
            sampleBuffer: normalizedSampleBuffer,
            formatDescription: normalizedFormatDescription,
            asbd: normalizedASBD
        )
    }

    private func cleanup() {
        writer = nil
        audioInput = nil
        expectedInputSignature = nil
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
        case .invalidSampleBuffer(let details):
            return "Received an invalid audio sample buffer from capture pipeline: \(details)"
        case .unsupportedAudioFormat(let details):
            return "Unsupported audio format from capture pipeline: \(details)"
        }
    }
}
