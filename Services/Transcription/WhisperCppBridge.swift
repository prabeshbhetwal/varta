import Foundation

struct WhisperTranscribedSegment: Sendable {
    let startSeconds: Double
    let endSeconds: Double
    let text: String
}

protocol WhisperCppClient: Sendable {
    func transcribe(mediaURL: URL, languageMode: LanguageMode) async throws -> [WhisperTranscribedSegment]
}

struct WhisperCppConfiguration: Sendable {
    let modelManifestPath: URL?
    let backend: Backend

    enum Backend: String, Sendable {
        case metal
    }

    init(modelManifestPath: URL? = nil, backend: Backend = .metal) {
        self.modelManifestPath = modelManifestPath
        self.backend = backend
    }
}

struct WhisperCppBridge: WhisperCppClient {
    let configuration: WhisperCppConfiguration

    init(configuration: WhisperCppConfiguration = WhisperCppConfiguration()) {
        self.configuration = configuration
    }

    func transcribe(mediaURL: URL, languageMode: LanguageMode) async throws -> [WhisperTranscribedSegment] {
        // The native framework is a placeholder; never fabricate meeting content.
        throw NSError(
            domain: "Varta.Transcription",
            code: 4100,
            userInfo: [NSLocalizedDescriptionKey:
                "Transcription is unavailable: the whisper.cpp engine and model are not integrated yet. Your audio and existing transcript are preserved."]
        )
    }
}
