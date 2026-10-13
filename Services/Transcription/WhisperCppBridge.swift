import AVFoundation
import Foundation
import CryptoKit
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

enum WhisperDecodingPolicy {
    static func normalizePaddedNativeEndpoint(_ segment: WhisperTranscribedSegment, isTerminal: Bool,
                                              within span: VoiceActivitySpan) -> WhisperTranscribedSegment {
        let duration = Double(span.endFrame - span.startFrame) / 16_000
        // Pinned decoder residual text can end at its padded 30-second context on shorter input.
        guard isTerminal, duration > 0, duration < 30, segment.endSeconds == 30,
              segment.startSeconds.isFinite, segment.startSeconds >= 0, segment.startSeconds < duration,
              !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return segment }
        return WhisperTranscribedSegment(startSeconds: segment.startSeconds, endSeconds: duration, text: segment.text)
    }

    static func validateSpeechSpans(_ spans: [VoiceActivitySpan], frameCount: Int64) throws {
        guard frameCount > 0, frameCount <= 480_000, !spans.isEmpty, spans.count <= 128 else {
            throw LocalModelError.invalidOutput("Whisper requires validated speech spans within a thirty-second audio window.")
        }
        var previousEnd: Int64 = 0
        for span in spans {
            guard span.startFrame >= previousEnd, span.endFrame > span.startFrame, span.endFrame <= frameCount else {
                throw LocalModelError.invalidOutput("Speech spans overlap or exceed the original audio window.")
            }
            previousEnd = span.endFrame
        }
    }

    static func mapDecodedSegments(_ segments: [WhisperTranscribedSegment], within span: VoiceActivitySpan) throws -> [WhisperTranscribedSegment] {
        let offset = Double(span.startFrame) / 16_000
        let duration = Double(span.endFrame - span.startFrame) / 16_000
        guard !segments.isEmpty else {
            throw LocalModelError.invalidOutput("Detected speech returned no transcript segments (crop \(String(format: "%.3f", duration)) seconds).")
        }
        for (index, segment) in segments.enumerated() {
            let blankText = segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard segment.startSeconds.isFinite && segment.endSeconds.isFinite && segment.startSeconds >= 0 &&
                  segment.startSeconds < duration && segment.endSeconds > segment.startSeconds &&
                  segment.endSeconds <= duration + 0.05 && !blankText else {
                throw LocalModelError.invalidOutput("Detected speech returned an invalid transcript segment \(index + 1) of \(segments.count): start \(String(format: "%.3f", segment.startSeconds)), end \(String(format: "%.3f", segment.endSeconds)), crop \(String(format: "%.3f", duration)) seconds, blank text \(blankText).")
            }
        }
        return segments.map {
            WhisperTranscribedSegment(startSeconds: offset + $0.startSeconds,
                endSeconds: offset + min($0.endSeconds, duration), text: $0.text)
        }
    }

    static func boundedContext(_ text: String) -> String {
        let normalized = text.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        var tail: [Character] = []
        var bytes = 0
        for character in normalized.reversed().prefix(1_024) {
            let size = String(character).utf8.count
            guard bytes + size <= 4_096 else { break }
            tail.append(character)
            bytes += size
        }
        return String(tail.reversed()).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func hasRepetitionLoop(_ segments: [WhisperTranscribedSegment]) -> Bool {
        let words = Array(segments.lazy.flatMap { $0.text.precomposedStringWithCanonicalMapping.lowercased().split(whereSeparator: \.isWhitespace) }
            .prefix(4_096).map { String($0).trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty })
        guard words.count >= 12 else { return false }
        // Four consecutive cycles; short stutters and non-consecutive restatements remain valid.
        for width in 3...min(32, words.count / 4) {
            for start in 0...(words.count - width * 4) {
                let phrase = words[start..<start + width]
                guard Set(phrase).count >= 3 else { continue }
                if (1..<4).allSatisfy({ cycle in
                    phrase == words[(start + cycle * width)..<(start + (cycle + 1) * width)]
                }) { return true }
            }
        }
        return false
    }
}

protocol WhisperCppClient: Sendable {
    func validateConfiguration() throws
    func configurationIdentity() throws -> String
    func transcribe(mediaURL: URL, languageMode: LanguageMode, promptContext: String, speechSpans: [VoiceActivitySpan]) async throws -> [WhisperTranscribedSegment]
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

    func configurationIdentity() throws -> String {
        try validateConfiguration()
        let model = try configuration.models.whisperModelURL().standardizedFileURL.resolvingSymlinksInPath()
        let attributes = try FileManager.default.attributesOfItem(atPath: model.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let device = attributes[.systemNumber] as? NSNumber,
              let size = attributes[.size] as? NSNumber, size.uint64Value > 0,
              let modified = attributes[.modificationDate] as? Date,
              modified.timeIntervalSince1970.isFinite else {
            throw LocalModelError.invalidAsset("Whisper model metadata is unavailable for a resumable job.")
        }
        // shortcut: metadata detects ordinary model changes, not unchanged-metadata tampering; use a pinned content digest when certification is required.
        let metadata = ["whisper.cpp-v1.8.3/metal/span-decoder-v1/greedy/temperature0/context224",
            model.path, device.stringValue, inode.stringValue, size.stringValue,
            String(modified.timeIntervalSince1970)]
        return SHA256.hash(data: try JSONEncoder().encode(metadata)).map { String(format: "%02x", $0) }.joined()
    }

    func transcribe(mediaURL: URL, languageMode: LanguageMode, promptContext: String = "", speechSpans: [VoiceActivitySpan]) async throws -> [WhisperTranscribedSegment] {
        try validateConfiguration()
        try Task.checkCancellation()
        #if canImport(whisper)
        let modelURL = try configuration.models.whisperModelURL()
        let audio = try AVAudioFile(forReading: mediaURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard audio.processingFormat.sampleRate == 16_000, audio.processingFormat.channelCount == 1,
              audio.length > 0, audio.length <= 16_000 * 30 else {
            throw LocalModelError.inferenceFailed("Whisper requires a 16 kHz mono WAV window of at most thirty seconds.")
        }
        try WhisperDecodingPolicy.validateSpeechSpans(speechSpans, frameCount: audio.length)
        let samples = try VoiceActivityAudioReader.readComplete(audio, frameCount: audio.length)
        var contextParameters = whisper_context_default_params()
        contextParameters.use_gpu = true
        guard let context = modelURL.path.withCString({ whisper_init_from_file_with_params($0, contextParameters) }) else {
            throw LocalModelError.inferenceFailed("Whisper model could not be loaded with Metal enabled.")
        }
        defer { whisper_free(context) }
        try Task.checkCancellation()
        let cancellation = WhisperCancellation()
        var decodingPrompt = WhisperDecodingPolicy.boundedContext(promptContext)
        return try await withTaskCancellationHandler {
            var parameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            parameters.n_threads = 2
            parameters.translate = false
            // Reset hidden decoder history for every crop; carry only explicit current-job text.
            parameters.no_context = true
            parameters.temperature = 0
            parameters.temperature_inc = 0
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
            var segments: [WhisperTranscribedSegment] = []
            for span in speechSpans {
                try Task.checkCancellation()
                parameters.n_max_text_ctx = decodingPrompt.isEmpty ? 0 : 224
                let language = languageMode == .mixed ? "auto" : languageMode.rawValue
                // PCM and both C strings remain owned until this synchronous crop decode returns.
                let status = try samples.withUnsafeBufferPointer { pcm in
                    guard let baseAddress = pcm.baseAddress else {
                        throw LocalModelError.inferenceFailed("Complete PCM audio is unavailable.")
                    }
                    return decodingPrompt.withCString { prompt in
                        parameters.initial_prompt = decodingPrompt.isEmpty ? nil : prompt
                        return language.withCString { language in
                            parameters.language = language
                            return whisper_full(context, parameters, baseAddress.advanced(by: Int(span.startFrame)),
                                Int32(span.endFrame - span.startFrame))
                        }
                    }
                }
                try Task.checkCancellation()
                guard status == 0 else { throw LocalModelError.inferenceFailed("Whisper returned status \(status).") }
                var cropSegments: [WhisperTranscribedSegment] = []
                let nativeCount = whisper_full_n_segments(context)
                var nilTextCount = 0
                var blankTextCount = 0
                var nativeRanges: [String] = []
                for index in 0..<nativeCount {
                    let start = whisper_full_get_segment_t0(context, index)
                    let end = whisper_full_get_segment_t1(context, index)
                    if index < 8 { nativeRanges.append("\(start):\(end)") }
                    guard let textPointer = whisper_full_get_segment_text(context, index) else {
                        nilTextCount += 1
                        continue
                    }
                    let text = String(cString: textPointer).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else {
                        blankTextCount += 1
                        continue
                    }
                    let native = WhisperTranscribedSegment(startSeconds: Double(start) / 100,
                        endSeconds: Double(end) / 100, text: text)
                    let normalized = WhisperDecodingPolicy.normalizePaddedNativeEndpoint(native,
                        isTerminal: index == nativeCount - 1, within: span)
                    if normalized.endSeconds != native.endSeconds {
                        let diagnostic = "Whisper padded terminal endpoint: raw centiseconds \(start):\(end), crop frames \(span.startFrame)..<\(span.endFrame), bounded end \(String(format: "%.3f", normalized.endSeconds)) seconds.\n"
                        try? FileHandle.standardError.write(contentsOf: Data(diagnostic.utf8))
                    }
                    cropSegments.append(normalized)
                }
                let mapped: [WhisperTranscribedSegment]
                do {
                    mapped = try WhisperDecodingPolicy.mapDecodedSegments(cropSegments, within: span)
                } catch {
                    let diagnostic = "Whisper crop rejected: window frames \(audio.length), crop frames \(span.startFrame)..<\(span.endFrame), native segments \(nativeCount), collected \(cropSegments.count), nil text \(nilTextCount), blank text \(blankTextCount), raw centiseconds [\(nativeRanges.joined(separator: ","))]. \(error.localizedDescription)\n"
                    try? FileHandle.standardError.write(contentsOf: Data(diagnostic.utf8))
                    throw error
                }
                segments.append(contentsOf: mapped)
                decodingPrompt = WhisperDecodingPolicy.boundedContext(decodingPrompt + " " + mapped.map(\.text).joined(separator: " "))
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
