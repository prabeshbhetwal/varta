import Foundation

actor SettingsStore {
    enum Key: String {
        case onboardingCompleted = "onboarding.completed"
        case defaultMeetingTitlePrefix = "settings.defaultMeetingTitlePrefix"
        case enableCalendarSuggestions = "settings.enableCalendarSuggestions"
    }

    private let storageService: StorageService

    init(storageService: StorageService) {
        self.storageService = storageService
    }

    func string(for key: Key) async throws -> String? {
        try await storageService.readSettingValue(for: key.rawValue)
    }

    func set(_ value: String?, for key: Key) async throws {
        try await storageService.writeSettingValue(value, for: key.rawValue)
    }

    func bool(for key: Key) async throws -> Bool? {
        guard let value = try await string(for: key) else {
            return nil
        }

        switch value.lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    func set(_ value: Bool, for key: Key) async throws {
        try await set(value ? "1" : "0", for: key)
    }
}
