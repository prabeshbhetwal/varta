import Foundation

actor MemoryManager {
    enum RuntimeMode: String, Sendable {
        case normal
        case reduced
        case paused
    }

    enum ModelFamily: String, Sendable {
        case whisper
        case summariser
        case translation
    }

    private var activeFamily: ModelFamily?
    private var runtimeMode: RuntimeMode = .normal

    func runExclusive<T: Sendable>(
        family: ModelFamily,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        while runtimeMode == .paused {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        while let activeFamily, activeFamily != family {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        activeFamily = family
        defer { activeFamily = nil }

        return try await operation()
    }

    func currentRuntimeMode() -> RuntimeMode {
        runtimeMode
    }

    func handleThermalStateChange(_ thermalState: ProcessInfo.ThermalState) {
        switch thermalState {
        case .nominal, .fair:
            runtimeMode = .normal
        case .serious:
            runtimeMode = .reduced
        case .critical:
            runtimeMode = .paused
        @unknown default:
            runtimeMode = .reduced
        }
    }

    func handlePowerStateChange(onBattery: Bool) {
        guard runtimeMode != .paused else {
            return
        }

        runtimeMode = onBattery ? .reduced : .normal
    }
}
