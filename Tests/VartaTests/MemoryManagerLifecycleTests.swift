import XCTest
@testable import Varta

final class MemoryManagerLifecycleTests: XCTestCase {
    func testThermalAndPowerTransitions() async {
        let manager = MemoryManager()

        await manager.handleThermalStateChange(.nominal)
        let nominalMode = await manager.currentRuntimeMode()
        XCTAssertEqual(nominalMode, .normal)

        await manager.handlePowerStateChange(onBattery: true)
        let onBatteryMode = await manager.currentRuntimeMode()
        XCTAssertEqual(onBatteryMode, .reduced)

        await manager.handleThermalStateChange(.critical)
        let criticalThermalMode = await manager.currentRuntimeMode()
        XCTAssertEqual(criticalThermalMode, .paused)

        await manager.handlePowerStateChange(onBattery: false)
        let pluggedInWhileCriticalMode = await manager.currentRuntimeMode()
        XCTAssertEqual(pluggedInWhileCriticalMode, .paused)

        await manager.handleThermalStateChange(.fair)
        let fairThermalMode = await manager.currentRuntimeMode()
        XCTAssertEqual(fairThermalMode, .normal)
    }

    func testPowerUpdatesDoNotClearThermalReduction() async {
        let manager = MemoryManager()
        await manager.handleThermalStateChange(.serious)
        await manager.handlePowerStateChange(onBattery: false)
        let hotMode = await manager.currentRuntimeMode()
        XCTAssertEqual(hotMode, .reduced)
        await manager.handlePowerStateChange(onBattery: true)
        await manager.handleThermalStateChange(.nominal)
        let batteryMode = await manager.currentRuntimeMode()
        XCTAssertEqual(batteryMode, .reduced)
    }

    func testCriticalThermalStateCancelsActiveWorkAndReleasesLease() async throws {
        let manager = MemoryManager()
        let probe = ConcurrencyProbe()
        let operation = Task {
            try await manager.runExclusive(family: .summariser) {
                await probe.enter()
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        for _ in 0..<250 {
            if await probe.maximum > 0 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let entered = await probe.maximum
        guard entered > 0 else {
            operation.cancel()
            _ = try? await operation.value
            XCTFail("Fixture did not acquire its lease within five seconds")
            return
        }
        await manager.handleThermalStateChange(.critical)
        do {
            _ = try await operation.value
            XCTFail("Critical thermal state must cancel active model work")
        } catch is CancellationError { }
        await manager.handleThermalStateChange(.nominal)
        let released = try await manager.runExclusive(family: .whisper) { true }
        XCTAssertTrue(released)
    }

    func testSameFamilyOperationsAreExclusive() async throws {
        let manager = MemoryManager()
        let probe = ConcurrencyProbe()
        async let first: Void = manager.runExclusive(family: .whisper) {
            await probe.enter()
            try await Task.sleep(nanoseconds: 50_000_000)
            await probe.leave()
        }
        async let second: Void = manager.runExclusive(family: .whisper) {
            await probe.enter()
            try await Task.sleep(nanoseconds: 50_000_000)
            await probe.leave()
        }
        _ = try await (first, second)
        let maximum = await probe.maximum
        XCTAssertEqual(maximum, 1)
    }
}

private actor ConcurrencyProbe {
    private var active = 0
    private(set) var maximum = 0

    func enter() {
        active += 1
        maximum = max(maximum, active)
    }

    func leave() { active -= 1 }
}
