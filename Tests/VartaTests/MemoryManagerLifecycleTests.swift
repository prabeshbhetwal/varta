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
}
