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
        let requested = URL(fileURLWithPath: directory, isDirectory: true)
        let normal = support.appendingPathComponent("Varta", isDirectory: true)
        let resolved = [requested, normal, requested.appendingPathComponent("varta.sqlite"),
                        normal.appendingPathComponent("varta.sqlite")].map { location -> URL? in
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
        guard let isolatedDirectoryURL = resolved[0], let defaultDirectoryURL = resolved[1],
              let isolatedDatabaseURL = resolved[2], let defaultDatabaseURL = resolved[3],
              isolatedDatabaseURL != defaultDatabaseURL else {
            launchState = .failed("VARTA_DATA_DIRECTORY must select isolated storage; default storage and unresolved aliases were refused.")
            return
        }
        let isolatedNames = isolatedDirectoryURL.pathComponents.map { $0.lowercased() }
        let defaultNames = defaultDirectoryURL.pathComponents.map { $0.lowercased() }
        let message = "VARTA_DATA_DIRECTORY requires separate storage without writable aliases in either namespace; storage was not opened."
        guard !isolatedNames.starts(with: defaultNames), !defaultNames.starts(with: isolatedNames) else {
            launchState = .failed(message)
            return
        }
        func identity(_ attributes: [FileAttributeKey: Any]) -> [UInt64]? {
            guard let device = attributes[.systemNumber] as? NSNumber,
                  let file = attributes[.systemFileNumber] as? NSNumber else { return nil }
            return [device.uint64Value, file.uint64Value]
        }
        var contents = [Set<[UInt64]>(), Set<[UInt64]>()]
        var ancestors = [Set<[UInt64]>(), Set<[UInt64]>()]
        for (index, directory) in [isolatedDirectoryURL, defaultDirectoryURL].enumerated() {
            var cursor = directory
            while true {
                if fileManager.fileExists(atPath: cursor.path) {
                    guard let attributes = try? fileManager.attributesOfItem(atPath: cursor.path),
                          let file = identity(attributes) else {
                        launchState = .failed(message)
                        return
                    }
                    ancestors[index].insert(file)
                }
                let parent = cursor.deletingLastPathComponent()
                if parent.path == cursor.path { break }
                cursor = parent
            }
            guard fileManager.fileExists(atPath: directory.path) else { continue }
            var traversalFailed = false
            guard let root = try? fileManager.attributesOfItem(atPath: directory.path),
                  root[.type] as? FileAttributeType == .typeDirectory,
                  let rootIdentity = identity(root),
                  let entries = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil,
                    errorHandler: { _, _ in traversalFailed = true; return false }) else {
                launchState = .failed(message)
                return
            }
            contents[index].insert(rootIdentity)
            while let entry = entries.nextObject() {
                guard let location = entry as? URL,
                      let attributes = try? fileManager.attributesOfItem(atPath: location.path),
                      let type = attributes[.type] as? FileAttributeType,
                      let file = identity(attributes),
                      type == .typeDirectory || (type == .typeRegular && (attributes[.referenceCount] as? NSNumber)?.intValue == 1) else {
                    launchState = .failed(message)
                    return
                }
                contents[index].insert(file)
            }
            guard !traversalFailed else {
                launchState = .failed(message)
                return
            }
        }
        guard contents[0].isDisjoint(with: contents[1]),
              contents[0].isDisjoint(with: ancestors[1]),
              contents[1].isDisjoint(with: ancestors[0]) else {
            launchState = .failed(message)
            return
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
