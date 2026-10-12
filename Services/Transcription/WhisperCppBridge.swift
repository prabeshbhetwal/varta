import AVFoundation
import Foundation
#if VARTA_REQUIRE_NATIVE_ENGINES && !canImport(whisper)
#error("Native CI requires the prepared whisper.cpp module.")
#endif
#if canImport(whisper)
import whisper
#endif

struct WhisperTranscribedSegment: Sendable {
    let startSeconds: Double
    let endSeconds: Double
    let text: String
}

protocol WhisperCppClient: Sendable {
    func validateConfiguration() throws
    func transcribe(mediaURL: URL, languageMode: LanguageMode) async throws -> [WhisperTranscribedSegment]
}

extension WhisperCppClient {
    func validateConfiguration() throws { }
}

struct WhisperCppConfiguration: Sendable {
    let modelManifestPath: URL?
    let backend: Backend
    let models: LocalModelConfiguration

    enum Backend: String, Sendable {
        case metal
    }

    init(modelManifestPath: URL? = nil, backend: Backend = .metal, models: LocalModelConfiguration? = nil) {
        self.modelManifestPath = modelManifestPath
        self.backend = backend
        self.models = models ?? LocalModelConfiguration(manifestURL: modelManifestPath)
    }
}

struct WhisperCppBridge: WhisperCppClient {
    let configuration: WhisperCppConfiguration

    init(configuration: WhisperCppConfiguration = WhisperCppConfiguration()) {
        self.configuration = configuration
    }

    func validateConfiguration() throws {
        #if canImport(whisper)
        _ = try configuration.models.whisperModelURL()
        #else
        throw LocalModelError.engineUnavailable("whisper.cpp engine and model adapter")
        #endif
    }

    func transcribe(mediaURL: URL, languageMode: LanguageMode) async throws -> [WhisperTranscribedSegment] {
        try validateConfiguration()
        try Task.checkCancellation()
        #if canImport(whisper)
        let modelURL = try configuration.models.whisperModelURL()
        let audio = try AVAudioFile(forReading: mediaURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard audio.processingFormat.sampleRate == 16_000, audio.processingFormat.channelCount == 1,
              audio.length > 0, audio.length <= 16_000 * 600,
              let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)) else {
            throw LocalModelError.inferenceFailed("Whisper requires a 16 kHz mono WAV window of at most ten minutes.")
        }
        try audio.read(into: buffer)
        guard let channels = buffer.floatChannelData else { throw LocalModelError.inferenceFailed("WAV samples are unavailable.") }
        let duration = Double(buffer.frameLength) / 16_000
        var contextParameters = whisper_context_default_params()
        contextParameters.use_gpu = true
        guard let context = modelURL.path.withCString({ whisper_init_from_file_with_params($0, contextParameters) }) else {
            throw LocalModelError.inferenceFailed("Whisper model could not be loaded with Metal enabled.")
        }
        defer { whisper_free(context) }
        try Task.checkCancellation()
        let cancellation = WhisperCancellation()
        return try await withTaskCancellationHandler {
            var parameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            parameters.n_threads = 2
            parameters.translate = false
            parameters.no_context = true
            parameters.print_progress = false
            parameters.print_realtime = false
            parameters.print_timestamps = false
            parameters.print_special = false
            parameters.suppress_blank = true
            parameters.suppress_nst = true
            parameters.abort_callback = { pointer in
                guard let pointer else { return false }
                return Unmanaged<WhisperCancellation>.fromOpaque(pointer).takeUnretainedValue().isCancelled
            }
            parameters.abort_callback_user_data = Unmanaged.passUnretained(cancellation).toOpaque()
            let language = languageMode == .mixed ? "auto" : languageMode.rawValue
            let status = language.withCString { language in
                parameters.language = language
                return whisper_full(context, parameters, channels[0], Int32(buffer.frameLength))
            }
            try Task.checkCancellation()
            guard status == 0 else { throw LocalModelError.inferenceFailed("Whisper returned status \(status).") }
            var segments: [WhisperTranscribedSegment] = []
            for index in 0..<whisper_full_n_segments(context) {
                guard let textPointer = whisper_full_get_segment_text(context, index) else { continue }
                let text = String(cString: textPointer).trimmingCharacters(in: .whitespacesAndNewlines)
                let start = Double(whisper_full_get_segment_t0(context, index)) / 100
                let end = min(Double(whisper_full_get_segment_t1(context, index)) / 100, duration)
                guard !text.isEmpty, start >= 0, end > start else { continue }
                segments.append(WhisperTranscribedSegment(startSeconds: start, endSeconds: end, text: text))
            }
            return segments
        } onCancel: {
            cancellation.cancel()
        }
        #else
        throw LocalModelError.engineUnavailable("whisper.cpp engine and model adapter")
        #endif
    }
}

private final class WhisperCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
