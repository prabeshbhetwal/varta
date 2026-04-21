import AppKit
import Foundation
import IOKit.ps

struct PowerSnapshot: Sendable {
    let onBattery: Bool
    let sourceName: String
}

final class ThermalStateMonitor {
    var onChange: ((ProcessInfo.ThermalState) -> Void)?

    private var observer: NSObjectProtocol?

    deinit {
        stop()
    }

    func start() {
        stop()
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.onChange?(ProcessInfo.processInfo.thermalState)
        }

        onChange?(ProcessInfo.processInfo.thermalState)
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }
}

final class PowerStateMonitor {
    var onChange: ((PowerSnapshot) -> Void)?

    private var observer: NSObjectProtocol?
    private var pollTask: Task<Void, Never>?

    deinit {
        stop()
    }

    func start() {
        stop()

        if #available(macOS 12.0, *) {
            observer = NotificationCenter.default.addObserver(
                forName: Notification.Name.NSProcessInfoPowerStateDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.publishCurrent()
            }
        }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.publishCurrent()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }

        publishCurrent()
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil

        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
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

final class SleepWakeMonitor {
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
        willSleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.onWillSleep?()
        }

        didWakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.onDidWake?()
        }
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
}
