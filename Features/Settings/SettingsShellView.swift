import AppKit
import EventKit
import SwiftUI

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case models
    case glossary
    case prompts
    case permissions
    case onboarding

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            return "General"
        case .models: return "Local Models"
        case .glossary: return "Glossary"
        case .prompts: return "Prompts"
        case .permissions:
            return "Permissions"
        case .onboarding:
            return "Onboarding"
        }
    }
}

struct SettingsShellView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var selectedSection: SettingsSection? = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selectedSection) { section in
                Text(section.title)
                    .tag(section)
            }
        } detail: {
            switch selectedSection {
            case .general:
                GeneralSettingsView()
            case .models:
                LocalModelSettingsView()
            case .glossary:
                GlossarySettingsView()
            case .prompts:
                PromptSettingsView()
            case .permissions:
                PermissionSettingsView()
            case .onboarding:
                OnboardingSettingsView()
            case .none:
                Text("Select a settings section")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 860, minHeight: 560)
    }
}

private struct GeneralSettingsView: View {
    @EnvironmentObject private var appModel: AppModel

    @State private var defaultMeetingTitlePrefix = ""
    @State private var hasLoadedValues = false
    @State private var storagePath = "Loading…"
    @State private var storageFolderURL: URL?
    @State private var saveMessage: String?

    var body: some View {
        Form {
            Section("Defaults") {
                TextField("Default meeting title prefix", text: $defaultMeetingTitlePrefix)
                Button("Save Default") {
                    Task {
                        do {
                            guard let store = appModel.settingsStore else { return }
                            try await store.set(defaultMeetingTitlePrefix, for: .defaultMeetingTitlePrefix)
                            saveMessage = "Default saved."
                        } catch { saveMessage = error.localizedDescription }
                    }
                }.disabled(!hasLoadedValues)
                if let saveMessage { Text(saveMessage).font(.caption).textSelection(.enabled) }
            }

            Section("Local Storage") {
                Text(storagePath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Button("Open Varta Folder in Finder") {
                    openStorageFolderInFinder()
                }
                .disabled(storageFolderURL == nil)
            }
        }
        .formStyle(.grouped)
        .padding(24)
        .task {
            await loadValuesIfNeeded()
            await loadStoragePathIfNeeded()
        }
    }

    private func loadValuesIfNeeded() async {
        guard !hasLoadedValues else {
            return
        }

        let store = appModel.settingsStore
        defaultMeetingTitlePrefix = (try? await store?.string(for: .defaultMeetingTitlePrefix)) ?? ""
        hasLoadedValues = true
    }

    private func loadStoragePathIfNeeded() async {
        guard storageFolderURL == nil else {
            return
        }
        guard let storageService = appModel.storageService else {
            storagePath = "Unavailable"
            return
        }

        let folderURL = await storageService.appSupportDirectory()
        storageFolderURL = folderURL
        storagePath = folderURL.path
    }

    private func openStorageFolderInFinder() {
        guard let folderURL = storageFolderURL else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([folderURL])
    }
}

private struct PermissionSettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var calendarState = "Not requested"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsPermissionStatusRow(title: "Microphone", state: appModel.permissions.microphoneState.rawValue)
            SettingsPermissionStatusRow(title: "Screen Recording", state: appModel.permissions.screenRecordingState.rawValue)
            SettingsPermissionStatusRow(title: "Calendar", state: calendarState)
            Text("Calendar write permission is requested only when you create a reviewed suggestion.")
                .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Request Microphone") {
                    Task {
                        await appModel.permissions.requestMicrophonePermission()
                    }
                }
                Button("Request Screen Recording") {
                    appModel.permissions.requestScreenRecordingPermission()
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            appModel.permissions.refreshMicrophone()
            appModel.permissions.refreshScreenRecording()
            calendarState = String(describing: EKEventStore.authorizationStatus(for: .event))
        }
    }
}

private struct LocalModelSettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @AppStorage("varta.whisperModelPath") private var whisperPath = ""
    @AppStorage("varta.languageModelPath") private var languageModelPath = ""
    @State private var status: String?

    var body: some View {
        Form {
            Section("Whisper transcription") {
                Text("Select a local whisper.cpp large-v3 Q5 model file.").foregroundStyle(.secondary)
                Text(whisperPath.isEmpty ? "Using model manifest location" : whisperPath)
                    .font(.caption.monospaced()).textSelection(.enabled)
                Button("Choose Whisper Model…") { chooseModel(isDirectory: false) }
            }
            Section("MLX summary and translation") {
                Text("Select a local Llama 3.1 8B Instruct 4-bit folder containing configuration, tokenizer and safetensors files.")
                    .foregroundStyle(.secondary)
                Text(languageModelPath.isEmpty ? "Using model manifest location" : languageModelPath)
                    .font(.caption.monospaced()).textSelection(.enabled)
                Button("Choose MLX Model Folder…") { chooseModel(isDirectory: true) }
            }
            Section("Validation") {
                Button("Validate Local Assets") { Task { await validateModels() } }
                if let status { Text(status).textSelection(.enabled) }
                Text("Assets remain on this Mac. Validation checks files; generation separately checks the linked engine and model compatibility.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).padding(24)
    }

    private func chooseModel(isDirectory: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = isDirectory
        panel.canChooseFiles = !isDirectory
        panel.allowsMultipleSelection = false
        panel.title = isDirectory ? "Choose Local MLX Model Folder" : "Choose Local Whisper Model"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if isDirectory { languageModelPath = url.path } else { whisperPath = url.path }
        status = nil
    }

    private func validateModels() async {
        guard let storage = appModel.storageService else { status = "Local storage unavailable."; return }
        let configuration = LocalModelConfiguration(
            rootDirectory: await storage.appSupportDirectory(),
            whisperOverride: whisperPath.isEmpty ? nil : URL(fileURLWithPath: whisperPath),
            languageModelOverride: languageModelPath.isEmpty ? nil : URL(fileURLWithPath: languageModelPath, isDirectory: true)
        )
        do {
            _ = try configuration.whisperModelURL()
            _ = try configuration.languageModelDirectory()
            status = "Required local asset files found. Inference has not been tested."
        } catch { status = error.localizedDescription }
    }
}

private struct GlossarySettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var terms: [GlossaryTerm] = []
    @State private var term = ""
    @State private var replacement = ""
    @State private var language: LanguageMode = .mixed
    @State private var pendingRemoval: GlossaryTerm?
    @State private var message: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Glossary replacements apply to reviewed text during summary generation; original transcript text remains available.")
                .foregroundStyle(.secondary)
            TextField("Term", text: $term)
            TextField("Replacement", text: $replacement)
            Picker("Language", selection: $language) {
                Text("English").tag(LanguageMode.english)
                Text("Nepali").tag(LanguageMode.nepali)
                Text("Any / mixed").tag(LanguageMode.mixed)
            }
            Button("Save Term") { Task { await saveTerm() } }
                .disabled(isSaving || term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let message { Text(message).font(.caption).textSelection(.enabled) }
            List(terms) { item in
                HStack {
                    VStack(alignment: .leading) {
                        Text(item.term + " → " + item.replacement)
                        Text(item.languageCode.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit") { term = item.term; replacement = item.replacement; language = item.languageCode }
                    Button("Remove", role: .destructive) { pendingRemoval = item }
                }
            }
        }.padding(24)
        .task { await loadTerms() }
        .confirmationDialog("Remove glossary term?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })) {
            Button("Remove Term", role: .destructive) {
                guard let item = pendingRemoval else { return }
                Task {
                    do {
                        try await appModel.storageService?.deleteGlossaryTerm(id: item.id)
                        await loadTerms()
                    } catch { message = error.localizedDescription }
                    pendingRemoval = nil
                }
            }
        } message: {
            Text(pendingRemoval?.term ?? "")
        }
    }

    private func loadTerms() async {
        do { terms = try await appModel.storageService?.glossaryTerms() ?? [] }
        catch { message = error.localizedDescription }
    }

    private func saveTerm() async {
        guard !isSaving, let storage = appModel.storageService else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await storage.addGlossaryTerm(term: term, replacement: replacement, languageCode: language)
            await loadTerms()
            message = "Term saved."
            term = ""
            replacement = ""
        } catch { message = error.localizedDescription }
    }
}

private struct PromptSettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var selectedTemplate: PromptTemplate = .windowSummary
    @State private var draft = ""
    @State private var original = ""
    @State private var directory: URL?
    @State private var message: String?
    @State private var isLoading = false
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Prompt template", selection: $selectedTemplate) {
                ForEach(PromptTemplate.allCases, id: \.rawValue) { Text($0.filename).tag($0) }
            }.disabled(isLoading || isSaving || draft != original)
            Text("Save or discard changes before switching prompts. Each save keeps a dated copy in Prompts/History.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $draft).font(.body.monospaced()).accessibilityLabel("Prompt contents")
                .disabled(isLoading || isSaving)
            HStack {
                Button("Save Prompt") { savePrompt() }
                    .disabled(directory == nil || isLoading || isSaving || draft == original)
                Button("Discard Changes") { Task { await loadPrompt() } }
                    .disabled(isLoading || isSaving || draft == original)
                if isLoading { ProgressView().controlSize(.small) }
            }
            if let message { Text(message).font(.caption).textSelection(.enabled) }
        }.padding(24)
        .task(id: selectedTemplate) { await loadPrompt() }
    }

    private func loadPrompt() async {
        guard let storage = appModel.storageService else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let root = await storage.appSupportDirectory()
            let text = try PromptTemplateService.loadPrompt(for: selectedTemplate, appSupportDirectoryURL: root)
            guard text.utf8.count <= 64_000 else { throw LocalModelError.invalidOutput("Prompt exceeds 64 KB; edit it in a text editor before loading.") }
            directory = root.appendingPathComponent("Prompts", isDirectory: true)
            draft = text
            original = text
            message = nil
        } catch { message = error.localizedDescription }
    }

    private func savePrompt() {
        guard let directory, !isSaving else { return }
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, draft.utf8.count <= 64_000 else {
            message = "Prompt must contain text and remain under 64 KB."
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let destination = directory.appendingPathComponent(selectedTemplate.filename)
            if FileManager.default.fileExists(atPath: destination.path) {
                let current = try String(contentsOf: destination, encoding: .utf8)
                guard current == original else {
                    message = "Prompt changed elsewhere. Discard changes to reload before saving."
                    return
                }
                let history = directory.appendingPathComponent("History", isDirectory: true)
                try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
                let stamp = Int(Date().timeIntervalSince1970)
                let backup = history.appendingPathComponent("\(selectedTemplate.rawValue)-\(stamp)-\(UUID().uuidString).txt")
                try current.write(to: backup, atomically: true, encoding: .utf8)
            }
            try draft.write(to: destination, atomically: true, encoding: .utf8)
            original = draft
            message = "Prompt saved."
        } catch { message = error.localizedDescription }
    }
}

private struct SettingsPermissionStatusRow: View {
    let title: String
    let state: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(state)
                .foregroundStyle(.secondary)
        }
    }
}

private struct OnboardingSettingsView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Onboarding completed", isOn: .constant(appModel.hasCompletedOnboarding))
                .disabled(true)

            Text("Resetting onboarding is useful while validating first-run permission flows.")
                .foregroundStyle(.secondary)

            Button("Reset Onboarding") {
                Task {
                    await appModel.resetOnboarding()
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
