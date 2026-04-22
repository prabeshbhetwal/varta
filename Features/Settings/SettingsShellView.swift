import AppKit
import SwiftUI

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case permissions
    case onboarding

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            return "General"
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
    @State private var enableCalendarSuggestions = true
    @State private var hasLoadedValues = false
    @State private var storagePath = "Loading…"
    @State private var storageFolderURL: URL?

    var body: some View {
        Form {
            Section("Defaults") {
                TextField("Default meeting title prefix", text: $defaultMeetingTitlePrefix)
                Toggle("Enable calendar suggestions", isOn: $enableCalendarSuggestions)
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
        .onChange(of: defaultMeetingTitlePrefix) {
            guard hasLoadedValues else { return }
            Task {
                try? await appModel.settingsStore?.set(defaultMeetingTitlePrefix, for: .defaultMeetingTitlePrefix)
            }
        }
        .onChange(of: enableCalendarSuggestions) {
            guard hasLoadedValues else { return }
            Task {
                try? await appModel.settingsStore?.set(enableCalendarSuggestions, for: .enableCalendarSuggestions)
            }
        }
    }

    private func loadValuesIfNeeded() async {
        guard !hasLoadedValues else {
            return
        }

        let store = appModel.settingsStore
        defaultMeetingTitlePrefix = (try? await store?.string(for: .defaultMeetingTitlePrefix)) ?? ""
        enableCalendarSuggestions = (try? await store?.bool(for: .enableCalendarSuggestions)) ?? true
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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsPermissionStatusRow(title: "Microphone", state: appModel.permissions.microphoneState.rawValue)
            SettingsPermissionStatusRow(title: "Screen Recording", state: appModel.permissions.screenRecordingState.rawValue)
            SettingsPermissionStatusRow(title: "Calendar", state: appModel.permissions.calendarState.rawValue)

            HStack(spacing: 12) {
                Button("Request Microphone") {
                    Task {
                        await appModel.permissions.requestMicrophonePermission()
                    }
                }
                Button("Request Screen Recording") {
                    appModel.permissions.requestScreenRecordingPermission()
                }
                Button("Request Calendar") {
                    Task {
                        await appModel.permissions.requestCalendarPermission()
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            appModel.permissions.refreshAll()
        }
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
                    try? await appModel.settingsStore?.set(false, for: .onboardingCompleted)
                    await appModel.bootstrap()
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
