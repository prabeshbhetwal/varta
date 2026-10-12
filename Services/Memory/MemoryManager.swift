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
    private var cancelActiveOperation: (@Sendable () -> Void)?
    private var runtimeMode: RuntimeMode = .normal
    private var thermalState: ProcessInfo.ThermalState = .nominal
    private var onBattery = false

    func runExclusive<T: Sendable>(
        family: ModelFamily,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        while runtimeMode == .paused || activeFamily != nil {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        try Task.checkCancellation()
        activeFamily = family
        let task = Task { try await operation() }
        cancelActiveOperation = { task.cancel() }
        defer {
            activeFamily = nil
            cancelActiveOperation = nil
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func currentRuntimeMode() -> RuntimeMode {
        runtimeMode
    }

    func handleThermalStateChange(_ thermalState: ProcessInfo.ThermalState) {
        self.thermalState = thermalState
        updateRuntimeMode()
    }

    func handlePowerStateChange(onBattery: Bool) {
        self.onBattery = onBattery
        updateRuntimeMode()
    }

    private func updateRuntimeMode() {
        switch thermalState {
        case .nominal, .fair:
            runtimeMode = onBattery ? .reduced : .normal
        case .serious:
            runtimeMode = .reduced
        case .critical:
            runtimeMode = .paused
            cancelActiveOperation?()
        @unknown default:
            runtimeMode = .reduced
        }
    }

}
