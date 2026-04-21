import AppKit
import Foundation
import IOKit.ps

struct PowerSnapshot: Sendable {
    let onBattery: Bool
    let sourceName: String
}

final class ThermalStateMonitor: NSObject {
    var onChange: ((ProcessInfo.ThermalState) -> Void)?

    private var observer: NSObjectProtocol?

    deinit {
        stop()
    }

    func start() {
        stop()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleThermalStateDidChange),
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )
        observer = self

        onChange?(ProcessInfo.processInfo.thermalState)
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    @objc
    private func handleThermalStateDidChange() {
        onChange?(ProcessInfo.processInfo.thermalState)
    }
}

final class PowerStateMonitor: NSObject {
    var onChange: ((PowerSnapshot) -> Void)?

    private var observer: NSObjectProtocol?
    private var pollTimer: Timer?

    deinit {
        stop()
    }

    func start() {
        stop()

        if #available(macOS 12.0, *) {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handlePowerStateDidChange),
                name: Notification.Name.NSProcessInfoPowerStateDidChange,
                object: nil
            )
            observer = self
        }

        let timer = Timer(
            timeInterval: 30,
            target: self,
            selector: #selector(handlePollingTimer),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        publishCurrent()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil

        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    @objc
    private func handlePowerStateDidChange() {
        publishCurrent()
    }

    @objc
    private func handlePollingTimer() {
        publishCurrent()
    }

    private func publishCurrent() {
        onChange?(Self.readCurrentPowerSnapshot())
    }

    private static func readCurrentPowerSnapshot() -> PowerSnapshot {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
              let first = sources.first,
              let description = IOPSGetPowerSourceDescription(info, first)?.takeUnretainedValue() as? [String: Any],
              let powerState = description[kIOPSPowerSourceStateKey as String] as? String
        else {
            return PowerSnapshot(onBattery: false, sourceName: "Unknown")
        }

        let onBattery = powerState != (kIOPSACPowerValue as String)
        return PowerSnapshot(onBattery: onBattery, sourceName: powerState)
    }
}

final class SleepWakeMonitor: NSObject {
    var onWillSleep: (() -> Void)?
    var onDidWake: (() -> Void)?

    private var willSleepObserver: NSObjectProtocol?
    private var didWakeObserver: NSObjectProtocol?

    deinit {
        stop()
    }

    func start() {
        stop()

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(handleWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        willSleepObserver = self

        center.addObserver(
            self,
            selector: #selector(handleDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        didWakeObserver = self
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter

        if let willSleepObserver {
            center.removeObserver(willSleepObserver)
            self.willSleepObserver = nil
        }

        if let didWakeObserver {
            center.removeObserver(didWakeObserver)
            self.didWakeObserver = nil
        }
    }

    @objc
    private func handleWillSleep() {
        onWillSleep?()
    }

    @objc
    private func handleDidWake() {
        onDidWake?()
    }
}
