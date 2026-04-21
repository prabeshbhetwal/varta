import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum LaunchState {
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var launchState: LaunchState = .loading
    @Published private(set) var hasCompletedOnboarding = false

    let permissions = PermissionsService()

    private(set) var storageService: StorageService?
    private(set) var settingsStore: SettingsStore?

    init() {
        Task {
            await bootstrap()
        }
    }

    func bootstrap() async {
        do {
            let storageService = try StorageService()
            let settingsStore = SettingsStore(storageService: storageService)
            let onboardingValue = try await settingsStore.bool(for: .onboardingCompleted) ?? false

            self.storageService = storageService
            self.settingsStore = settingsStore
            self.hasCompletedOnboarding = onboardingValue
            self.launchState = .ready
        } catch {
            launchState = .failed("Failed to initialise local storage: \(error.localizedDescription)")
        }

        permissions.refreshAll()
    }

    func completeOnboarding() async {
        guard let settingsStore else {
            return
        }

        do {
            try await settingsStore.set(true, for: .onboardingCompleted)
            hasCompletedOnboarding = true
        } catch {
            launchState = .failed("Failed to persist onboarding completion: \(error.localizedDescription)")
        }
    }
}
