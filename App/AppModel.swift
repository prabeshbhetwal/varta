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
    private(set) var recorderCoordinator: RecorderCoordinator?
    private(set) var memoryManager: MemoryManager?
    private(set) var systemRuntimeCoordinator: SystemRuntimeCoordinator?

    init() {
        Task {
            await bootstrap()
        }
    }

    func bootstrap() async {
        systemRuntimeCoordinator?.stop()

        do {
            let storageService = try StorageService()
            let settingsStore = SettingsStore(storageService: storageService)
            let memoryManager = MemoryManager()
            let jobQueue = JobQueue(storageService: storageService)
            let checkpointer = Checkpointer(storageService: storageService)
            let recorderCoordinator = RecorderCoordinator(
                storageService: storageService,
                jobQueue: jobQueue,
                checkpointer: checkpointer,
                memoryManager: memoryManager
            )
            let systemRuntimeCoordinator = SystemRuntimeCoordinator(
                recorderCoordinator: recorderCoordinator,
                memoryManager: memoryManager
            )

            let onboardingValue = try await settingsStore.bool(for: .onboardingCompleted) ?? false

            self.storageService = storageService
            self.settingsStore = settingsStore
            self.memoryManager = memoryManager
            self.recorderCoordinator = recorderCoordinator
            self.systemRuntimeCoordinator = systemRuntimeCoordinator
            self.hasCompletedOnboarding = onboardingValue
            self.launchState = .ready

            systemRuntimeCoordinator.start()
        } catch {
            launchState = .failed("Failed to initialise local storage: \(error.localizedDescription)")
        }

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
