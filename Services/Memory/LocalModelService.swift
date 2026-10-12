import Foundation
#if VARTA_REQUIRE_NATIVE_ENGINES && (!canImport(MLXLLM) || !canImport(MLXLMCommon) || !canImport(MLX))
#error("Native CI requires all declared MLX model modules.")
#endif
#if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(MLX)
import MLX
import MLXLLM
import MLXLMCommon
#endif

enum LocalModelError: LocalizedError {
    case manifestMissing
    case invalidManifest
    case missingAsset(String)
    case engineUnavailable(String)
    case inferenceFailed(String)
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case .manifestMissing: return "The local model manifest is missing from this app build."
        case .invalidManifest: return "The model manifest must select whisper.cpp/Metal and local MLX Llama models."
        case .missingAsset(let path): return "Required local model file is missing or unreadable: \(path). Choose local assets in Settings."
        case .engineUnavailable(let engine): return "\(engine) is not linked in this app build. Follow the native setup guide and rebuild; existing meeting data is preserved."
        case .inferenceFailed(let message): return "Local inference failed: \(message). Existing outputs are preserved."
        case .invalidOutput(let message): return "Model output could not be validated: \(message). Existing outputs are preserved."
        }
    }
}

struct LocalModelConfiguration: Sendable {
    let rootDirectory: URL
    let manifestURL: URL?
    let whisperOverride: URL?
    let languageModelOverride: URL?

    init(rootDirectory: URL? = nil, manifestURL: URL? = nil, whisperOverride: URL? = nil, languageModelOverride: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        self.rootDirectory = rootDirectory ?? support.appendingPathComponent("Varta")
        self.manifestURL = manifestURL ?? Bundle.main.url(forResource: "model-manifest", withExtension: "json")
        self.whisperOverride = whisperOverride
        self.languageModelOverride = languageModelOverride
    }

    private struct Manifest: Decodable {
        struct Engine: Decodable { let engine: String; let model: String; let path: String; let backend: String? }
        let whisper: Engine
        let summariser: Engine
    }

    private func manifest() throws -> Manifest {
        guard let manifestURL else { throw LocalModelError.manifestMissing }
        let size = try manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size < 64_000 else { throw LocalModelError.invalidManifest }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.whisper.engine == "whisper.cpp", manifest.whisper.backend == "metal",
              manifest.summariser.engine == "mlx-swift",
              manifest.whisper.model == "ggml-large-v3-q5_0",
              manifest.summariser.model == "llama-3.1-8b-instruct-4bit" else {
            throw LocalModelError.invalidManifest
        }
        return manifest
    }

    private func resolve(_ relativePath: String) throws -> URL {
        guard !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains("..") else {
            throw LocalModelError.invalidManifest
        }
        return rootDirectory.appendingPathComponent(relativePath)
    }

    func whisperModelURL() throws -> URL {
        let manifest = try manifest()
        let url = try whisperOverride ?? resolve(manifest.whisper.path)
        try Self.requireFile(url)
        return url
    }

    func languageModelDirectory() throws -> URL {
        let manifest = try manifest()
        let directory = try languageModelOverride ?? resolve(manifest.summariser.path)
        for name in ["config.json", "tokenizer.json", "tokenizer_config.json"] {
            try Self.requireFile(directory.appendingPathComponent(name))
        }
        let weights = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "safetensors" }
        guard !weights.isEmpty else { throw LocalModelError.missingAsset(directory.appendingPathComponent("*.safetensors").path) }
        for weight in weights { try Self.requireFile(weight) }
        return directory
    }

    private static func requireFile(_ url: URL) throws {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true, (values?.fileSize ?? 0) > 0,
              FileManager.default.isReadableFile(atPath: url.path) else {
            throw LocalModelError.missingAsset(url.path)
        }
    }
}

protocol LocalLanguageModelClient: Sendable {
    func generate(prompt: String) async throws -> String
    func unload() async
}

actor MLXLanguageModelClient: LocalLanguageModelClient {
    private let configuration: LocalModelConfiguration
    #if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(MLX)
    private var container: ModelContainer?
    #endif

    init(configuration: LocalModelConfiguration = LocalModelConfiguration()) {
        self.configuration = configuration
    }

    func generate(prompt: String) async throws -> String {
        guard !prompt.isEmpty, prompt.utf8.count <= 120_000 else {
            throw LocalModelError.invalidOutput("Prompt is empty or exceeds the bounded context window.")
        }
        try Task.checkCancellation()
        let directory = try configuration.languageModelDirectory()
        #if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(MLX)
        if container == nil {
            // Directory configuration keeps both tokenizer and weights offline.
            container = try await LLMModelFactory.shared.loadContainer(configuration: ModelConfiguration(
                directory: directory, extraEOSTokens: ["<|end_of_text|>", "<|eom_id|>", "<|eot_id|>"]
            ))
        }
        guard let container else { throw LocalModelError.inferenceFailed("Llama model did not load.") }
        let output = try await container.perform(values: prompt) { context, prompt in
            try Task.checkCancellation()
            let input = try await context.processor.prepare(input: UserInput(prompt: prompt))
            var reachedLimit = false
            let result = try MLXLMCommon.generate(input: input, parameters: GenerateParameters(temperature: 0), context: context) { tokens in
                if tokens.count >= 2_048 { reachedLimit = true }
                return Task.isCancelled || reachedLimit ? .stop : .more
            }
            try Task.checkCancellation()
            guard !reachedLimit else { throw LocalModelError.invalidOutput("Generation reached its token limit; no partial content was saved.") }
            return result.output
        }
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalModelError.invalidOutput("Llama returned an empty response.")
        }
        return output
        #else
        _ = directory
        throw LocalModelError.engineUnavailable("MLX Swift LM")
        #endif
    }

    func unload() async {
        #if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(MLX)
        guard container != nil else { return }
        container = nil
        Stream().synchronize()
        GPU.clearCache()
        #endif
    }
}
