import Foundation

actor MemoryManager {
    enum ModelFamily: String, Sendable {
        case whisper
        case summariser
        case translation
    }

    private var activeFamily: ModelFamily?

    func runExclusive<T: Sendable>(
        family: ModelFamily,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        while let activeFamily, activeFamily != family {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        activeFamily = family
        defer { activeFamily = nil }

        return try await operation()
    }
}
