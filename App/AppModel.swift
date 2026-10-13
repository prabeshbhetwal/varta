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
        // Test hosts must not bootstrap or migrate the user's real database.
        guard ProcessInfo.processInfo.environment["VARTA_TESTING"] != "1" else { return }
        Task {
            await bootstrap()
        }
    }

    func bootstrap(fileManager: FileManager = .default) async {
        #if VARTA_REQUIRE_ISOLATED_DATA
        guard let directory = ProcessInfo.processInfo.environment["VARTA_DATA_DIRECTORY"],
              !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (directory as NSString).isAbsolutePath,
              let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            launchState = .failed("Verification build requires an absolute VARTA_DATA_DIRECTORY; storage was not opened.")
            return
        }
        let requested = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("varta.sqlite")
        let normal = support.appendingPathComponent("Varta/varta.sqlite")
        let resolved = [requested, normal].map { location -> URL? in
            var cursor = location.standardizedFileURL
            var missing: [String] = []
            while !fileManager.fileExists(atPath: cursor.path) {
                if let attributes = try? fileManager.attributesOfItem(atPath: cursor.path),
                   attributes[.type] as? FileAttributeType == .typeSymbolicLink { return nil }
                let parent = cursor.deletingLastPathComponent()
                guard parent.path != cursor.path else { return nil }
                missing.append(cursor.lastPathComponent)
                cursor = parent
            }
            return missing.reversed().reduce(cursor.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }
        }
        guard let isolatedDatabaseURL = resolved[0], let defaultDatabaseURL = resolved[1],
              isolatedDatabaseURL != defaultDatabaseURL else {
            launchState = .failed("VARTA_DATA_DIRECTORY must select isolated storage; default storage and unresolved aliases were refused.")
            return
        }
        if fileManager.fileExists(atPath: isolatedDatabaseURL.path),
           fileManager.fileExists(atPath: defaultDatabaseURL.path) {
            guard let isolated = try? fileManager.attributesOfItem(atPath: isolatedDatabaseURL.path),
                  let normal = try? fileManager.attributesOfItem(atPath: defaultDatabaseURL.path),
                  let isolatedFile = isolated[.systemFileNumber] as? NSNumber,
                  let normalFile = normal[.systemFileNumber] as? NSNumber,
                  let isolatedDevice = isolated[.systemNumber] as? NSNumber,
                  let normalDevice = normal[.systemNumber] as? NSNumber,
                  isolatedFile != normalFile || isolatedDevice != normalDevice else {
                launchState = .failed("VARTA_DATA_DIRECTORY must select isolated storage; default database aliases were refused.")
                return
            }
        }
        #endif
        systemRuntimeCoordinator?.stop()

        do {
            #if VARTA_REQUIRE_ISOLATED_DATA
            let databaseURL: URL? = isolatedDatabaseURL
            #else
            let databaseURL = ProcessInfo.processInfo.environment["VARTA_DATA_DIRECTORY"].map {
                URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("varta.sqlite")
            }
            #endif
            let storageService = try StorageService(databaseURL: databaseURL, fileManager: fileManager)
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
            _ = try await jobQueue.recoverInterruptedRecordingJobs()
            _ = try await TranscriptionService(storageService: storageService, memoryManager: memoryManager).recoverInterruptedJobs()
            try await storageService.recoverInterruptedGenerationJobs()

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

    func resetOnboarding() async {
        do {
            try await settingsStore?.set(false, for: .onboardingCompleted)
            hasCompletedOnboarding = false
        } catch {
            launchState = .failed("Failed to reset onboarding: \(error.localizedDescription)")
        }
    }
}
