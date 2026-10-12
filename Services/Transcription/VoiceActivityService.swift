import AVFoundation
import Foundation
#if VARTA_REQUIRE_NATIVE_ENGINES && !canImport(whisper)
#error("Native CI requires whisper.cpp VAD symbols and the prepared module.")
#endif
#if canImport(whisper)
import whisper
#endif

struct VoiceActivitySpan: Codable, Sendable, Equatable {
    let startFrame: Int64
    let endFrame: Int64
}

struct VoiceActivityDetection: Sendable {
    let frameCount: Int64
    let spans: [VoiceActivitySpan]
}

protocol VoiceActivityDetecting: Sendable {
    func configurationIdentity() throws -> String
    func detectSpeech(mediaURL: URL) async throws -> VoiceActivityDetection
}

enum VoiceActivityPolicy {
    static let modelSHA256 = "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987"
    static let maximumFrameCount: Int64 = 480_000
    static let identity = "whisper.cpp-v1.8.3/silero-v6.2.0/\(modelSHA256)/16k/window=512/threshold=0.5/min-speech=250/min-silence=100/pad=30/overlap=0/max-window=30/max-speech=30/sentinel-v1"

    static func probabilityCount(frameCount: Int64) throws -> Int {
        guard frameCount > 0, frameCount <= maximumFrameCount else {
            throw LocalModelError.invalidOutput("VAD requires a non-empty audio window of at most thirty seconds.")
        }
        return Int((frameCount + 511) / 512)
    }

    static func validateProbabilityCoverage(_ probabilities: [Float], frameCount: Int64) throws {
        guard probabilities.count == (try probabilityCount(frameCount: frameCount)),
              probabilities.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else {
            throw LocalModelError.inferenceFailed("VAD did not produce a valid probability for every audio chunk.")
        }
    }

    static func spans(centiseconds: [(Float, Float)], frameCount: Int64) throws -> [VoiceActivitySpan] {
        let count = try probabilityCount(frameCount: frameCount)
        guard centiseconds.count <= count else {
            throw LocalModelError.invalidOutput("VAD returned more speech ranges than audio chunks.")
        }
        // The final 512-frame chunk is zero-padded; native timestamps round to centiseconds.
        let maximumCentiseconds = (Double(count * 512) / 160).rounded()
        var ranges: [VoiceActivitySpan] = []
        for (start, end) in centiseconds {
            guard start.isFinite, end.isFinite, start >= 0, end > start,
                  Double(end) <= maximumCentiseconds else {
                throw LocalModelError.invalidOutput("VAD returned an invalid speech timestamp.")
            }
            let startFrame = Int64((Double(start) * 160).rounded())
            let endFrame = min(Int64((Double(end) * 160).rounded()), frameCount)
            guard startFrame < frameCount, endFrame > startFrame else {
                throw LocalModelError.invalidOutput("VAD speech range lies outside the original audio window.")
            }
            ranges.append(VoiceActivitySpan(startFrame: startFrame, endFrame: endFrame))
        }
        ranges.sort { $0.startFrame == $1.startFrame ? $0.endFrame < $1.endFrame : $0.startFrame < $1.startFrame }
        var merged: [VoiceActivitySpan] = []
        for range in ranges {
            if let previous = merged.last, range.startFrame <= previous.endFrame {
                merged[merged.count - 1] = VoiceActivitySpan(startFrame: previous.startFrame,
                    endFrame: max(previous.endFrame, range.endFrame))
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}

enum VoiceActivityAudioReader {
    static func readComplete(_ audio: AVAudioFile, frameCount: Int64) throws -> [Float] {
        try Task.checkCancellation()
        _ = try VoiceActivityPolicy.probabilityCount(frameCount: frameCount)
        guard audio.length == frameCount, audio.framePosition == 0,
              audio.processingFormat.sampleRate == 16_000, audio.processingFormat.channelCount == 1,
              audio.processingFormat.commonFormat == .pcmFormatFloat32,
              let scratch = AVAudioPCMBuffer(pcmFormat: audio.processingFormat,
                frameCapacity: AVAudioFrameCount(min(frameCount, 4_096))) else {
            throw LocalModelError.invalidOutput("Audio PCM input differs: requested \(frameCount) frames, file \(audio.length), position \(audio.framePosition); expected fresh 16 kHz mono Float32 audio.")
        }
        var samples: [Float] = []
        samples.reserveCapacity(Int(frameCount))
        while samples.count < Int(frameCount) {
            try Task.checkCancellation()
            let requested = AVAudioFrameCount(min(Int(scratch.frameCapacity), Int(frameCount) - samples.count))
            let position = audio.framePosition
            scratch.frameLength = 0
            try audio.read(into: scratch, frameCount: requested)
            let received = Int(scratch.frameLength)
            guard received > 0, received <= Int(requested), audio.framePosition - position == Int64(received),
                  let channel = scratch.floatChannelData?[0] else {
                throw LocalModelError.invalidOutput("Audio PCM read incomplete: expected \(frameCount), collected \(samples.count), requested \(requested), received \(received), position \(audio.framePosition).")
            }
            try withExtendedLifetime(scratch) {
                let chunk = UnsafeBufferPointer(start: channel, count: received)
                if let index = chunk.firstIndex(where: { !$0.isFinite }) {
                    throw LocalModelError.invalidOutput("Audio PCM contains a non-finite sample at frame \(samples.count + index) of \(frameCount).")
                }
                samples.append(contentsOf: chunk)
            }
        }
        try Task.checkCancellation()
        guard samples.count == Int(frameCount), audio.framePosition == frameCount else {
            throw LocalModelError.invalidOutput("Audio PCM length differs: expected \(frameCount), read \(samples.count), final position \(audio.framePosition).")
        }
        return samples
    }
}

struct WhisperVoiceActivityDetector: VoiceActivityDetecting {
    let configuration: LocalModelConfiguration

    init(configuration: LocalModelConfiguration = LocalModelConfiguration()) {
        self.configuration = configuration
    }

    func configurationIdentity() throws -> String {
        #if canImport(whisper)
        _ = try configuration.vadModelURL()
        return VoiceActivityPolicy.identity
        #else
        throw LocalModelError.engineUnavailable("whisper.cpp Silero VAD")
        #endif
    }

    func detectSpeech(mediaURL: URL) async throws -> VoiceActivityDetection {
        try Task.checkCancellation()
        #if canImport(whisper)
        let modelURL = try configuration.vadModelURL()
        let audio = try AVAudioFile(forReading: mediaURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frameCount = audio.length
        let expectedCount = try VoiceActivityPolicy.probabilityCount(frameCount: frameCount)
        let samples = try VoiceActivityAudioReader.readComplete(audio, frameCount: frameCount)
        try Task.checkCancellation()
        var contextParameters = whisper_vad_default_context_params()
        contextParameters.n_threads = 2
        contextParameters.use_gpu = false
        guard let context = modelURL.path.withCString({ whisper_vad_init_from_file_with_params($0, contextParameters) }) else {
            throw LocalModelError.inferenceFailed("The verified Silero VAD model could not be loaded.")
        }
        defer { whisper_vad_free(context) }

        // v1.8.3 can return true after an early graph failure. Same-size resize preserves
        // NaN markers, so every real chunk must overwrite one before silence is accepted.
        let silence = [Float](repeating: 0, count: Int(frameCount))
        try Task.checkCancellation()
        let warmed = silence.withUnsafeBufferPointer {
            whisper_vad_detect_speech(context, $0.baseAddress, Int32(frameCount))
        }
        try Task.checkCancellation()
        guard warmed, Int(whisper_vad_n_probs(context)) == expectedCount,
              let warmProbabilities = whisper_vad_probs(context) else {
            throw LocalModelError.inferenceFailed("VAD probability storage could not be prepared.")
        }
        for index in 0..<expectedCount { warmProbabilities[index] = .nan }
        try Task.checkCancellation()
        let detected = samples.withUnsafeBufferPointer {
            whisper_vad_detect_speech(context, $0.baseAddress, Int32(frameCount))
        }
        try Task.checkCancellation()
        guard detected, Int(whisper_vad_n_probs(context)) == expectedCount,
              let probabilities = whisper_vad_probs(context) else {
            throw LocalModelError.inferenceFailed("VAD failed to process the complete audio window.")
        }
        try VoiceActivityPolicy.validateProbabilityCoverage(
            Array(UnsafeBufferPointer(start: probabilities, count: expectedCount)), frameCount: frameCount)

        var parameters = whisper_vad_default_params()
        parameters.threshold = 0.5
        parameters.min_speech_duration_ms = 250
        parameters.min_silence_duration_ms = 100
        parameters.max_speech_duration_s = 30
        parameters.speech_pad_ms = 30
        parameters.samples_overlap = 0
        guard let segments = whisper_vad_segments_from_probs(context, parameters) else {
            throw LocalModelError.inferenceFailed("VAD speech segmentation failed.")
        }
        defer { whisper_vad_free_segments(segments) }
        let count = Int(whisper_vad_segments_n_segments(segments))
        guard count >= 0, count <= expectedCount else {
            throw LocalModelError.invalidOutput("VAD speech range count is invalid.")
        }
        var timestamps: [(Float, Float)] = []
        for index in 0..<count {
            timestamps.append((whisper_vad_segments_get_segment_t0(segments, Int32(index)),
                whisper_vad_segments_get_segment_t1(segments, Int32(index))))
        }
        let spans = try VoiceActivityPolicy.spans(centiseconds: timestamps, frameCount: frameCount)
        try Task.checkCancellation()
        return VoiceActivityDetection(frameCount: frameCount, spans: spans)
        #else
        throw LocalModelError.engineUnavailable("whisper.cpp Silero VAD")
        #endif
    }
}
