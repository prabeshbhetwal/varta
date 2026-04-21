import Foundation

@MainActor
final class SystemRuntimeCoordinator {
    private let recorderCoordinator: RecorderCoordinator
    private let memoryManager: MemoryManager

    private let thermalMonitor = ThermalStateMonitor()
    private let powerMonitor = PowerStateMonitor()
    private let sleepWakeMonitor = SleepWakeMonitor()

    init(recorderCoordinator: RecorderCoordinator, memoryManager: MemoryManager) {
        self.recorderCoordinator = recorderCoordinator
        self.memoryManager = memoryManager
    }

    func start() {
        thermalMonitor.onChange = { [weak self] state in
            guard let self else { return }
            Task {
                await self.recorderCoordinator.handleThermalStateChange(state)
                await self.memoryManager.handleThermalStateChange(state)
            }
        }

        powerMonitor.onChange = { [weak self] snapshot in
            guard let self else { return }
            Task {
                await self.recorderCoordinator.handlePowerStateChange(onBattery: snapshot.onBattery)
                await self.memoryManager.handlePowerStateChange(onBattery: snapshot.onBattery)
            }
        }

        sleepWakeMonitor.onWillSleep = { [weak self] in
            guard let self else { return }
            Task {
                await self.recorderCoordinator.handleWillSleep()
            }
        }

        sleepWakeMonitor.onDidWake = { [weak self] in
            guard let self else { return }
            Task {
                await self.recorderCoordinator.handleDidWake()
            }
        }

        thermalMonitor.start()
        powerMonitor.start()
        sleepWakeMonitor.start()
    }

    func stop() {
        thermalMonitor.stop()
        powerMonitor.stop()
        sleepWakeMonitor.stop()
    }
}
