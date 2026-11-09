//
//  BluetoothMonitor.swift
//  FunNotch
//
//  Announces Bluetooth devices connecting and disconnecting in the notch, with
//  a battery reading where the device publishes one.
//

import AppKit
import Combine
import Foundation
import IOBluetooth
import IOKit

struct BluetoothDeviceState: Equatable {
    let address: String
    let name: String
    let isConnected: Bool
    let majorClass: UInt32
    let minorClass: UInt32
    /// 0...1, when the device reports it.
    let battery: Double?

    /// Best-guess SF Symbol from the Bluetooth class of device.
    var symbol: String {
        let lowered = name.lowercased()
        if lowered.contains("airpods max") { return "airpods.max" }
        if lowered.contains("airpods pro") { return "airpods.pro" }
        if lowered.contains("airpod") { return "airpods" }
        if lowered.contains("beats") || lowered.contains("headphone") { return "headphones" }
        if lowered.contains("watch") { return "applewatch" }
        if lowered.contains("iphone") { return "iphone" }
        if lowered.contains("ipad") { return "ipad" }

        switch majorClass {
        case 0x04: return "headphones"       // audio / video
        case 0x05: return minorClass & 0x10 != 0 ? "keyboard" : "magicmouse"
        case 0x02: return "iphone"
        default: return "dot.radiowaves.right"
        }
    }
}

@MainActor
final class BluetoothMonitor: ObservableObject {
    static let shared = BluetoothMonitor()

    @Published private(set) var devices: [BluetoothDeviceState] = []
    /// Most recent connection change, for the notch to show.
    @Published private(set) var lastChange: (device: BluetoothDeviceState, connected: Bool)?

    private var timer: Timer?
    private var connectNotification: IOBluetoothUserNotification?
    private let connectTarget = BluetoothConnectTarget()
    private var known: [String: Bool] = [:]
    private var hasBaseline = false

    private init() {}

    func start() {
        // The first call into IOBluetooth waits for the answer to macOS's
        // Bluetooth permission prompt, which reappears on every rebuild of an
        // ad-hoc-signed copy. Made on the main thread, that wait froze the app
        // at launch before the notch had even been created. So the first call
        // happens here, and polling starts once it has come back.
        DispatchQueue.global(qos: .utility).async {
            _ = IOBluetoothDevice.pairedDevices()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.beginPolling() }
            }
        }
    }

    private func beginPolling() {
        guard timer == nil else { return }
        refresh(announce: false)

        // A device connecting is delivered as a notification, so the common case
        // reacts at once. Disconnects (and devices that never notify) are caught
        // by a slow poll, which is much cheaper than the old 2 s one: each pass
        // walks the paired list and the IO registry.
        connectTarget.onChange = { [weak self] in
            // The device reports itself connected a moment after the callback.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: connectTarget, selector: #selector(BluetoothConnectTarget.deviceConnected(_:device:))
        )

        let timer = Timer(timeInterval: 4.0, repeats: true) { [weak self] _ in
            guard !SystemActivityMonitor.isScreenIdle else { return }
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        connectNotification?.unregister()
        connectNotification = nil
    }

    /// Sets a fixed connection change, for snapshots.
    func injectPreviewChange(name: String, connected: Bool, battery: Double?) {
        let device = BluetoothDeviceState(
            address: "00:00:00:00:00:00",
            name: name,
            isConnected: connected,
            majorClass: 0x04,
            minorClass: 0,
            battery: battery
        )
        devices = [device]
        lastChange = (device, connected)
    }

    private func refresh(announce: Bool = true) {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return }

        let batteries = Self.batteryLevelsByName()
        var current: [BluetoothDeviceState] = []

        for device in paired {
            guard let address = device.addressString else { continue }
            let name = device.name ?? device.nameOrAddress ?? address
            let state = BluetoothDeviceState(
                address: address,
                name: name,
                isConnected: device.isConnected(),
                majorClass: device.deviceClassMajor,
                minorClass: device.deviceClassMinor,
                battery: batteries[name.lowercased()]
            )
            current.append(state)

            let wasConnected = known[address]
            known[address] = state.isConnected

            guard announce, hasBaseline, let wasConnected, wasConnected != state.isConnected else {
                continue
            }
            announceChange(state)
        }

        let sorted = current.sorted { lhs, rhs in
            if lhs.isConnected != rhs.isConnected { return lhs.isConnected }
            return lhs.name < rhs.name
        }
        // Assigning an equal list would still redraw everything that watches it.
        if sorted != devices { devices = sorted }
        hasBaseline = true
    }

    private func announceChange(_ device: BluetoothDeviceState) {
        guard Settings.shared.bluetoothActivity else { return }
        lastChange = (device, device.isConnected)
        DiagnosticLog.write(
            "bluetooth",
            "\(device.name) \(device.isConnected ? "connected" : "disconnected")"
        )

        NotchWindowManager.shared.broadcast { viewModel in
            viewModel.showExpandingView(
                type: .bluetooth,
                value: device.battery ?? 0,
                icon: device.symbol,
                duration: 3.0
            )
        }
    }

    /// Reads battery percentages that Apple devices publish into the IO
    /// registry. Best effort — plenty of devices publish nothing.
    private static func batteryLevelsByName() -> [String: Double] {
        var result: [String: Double] = [:]

        var iterator = io_iterator_t()
        let matching = IOServiceMatching("AppleDeviceManagementHIDEventService")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return result
        }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }

            guard let properties = Self.properties(of: service) else { continue }
            guard let name = (properties["Product"] as? String) ?? (properties["DeviceName"] as? String)
            else { continue }

            let keys = ["BatteryPercent", "BatteryPercentCombined", "HeadsetBattery"]
            for key in keys {
                if let value = properties[key] as? Int, value > 0 {
                    result[name.lowercased()] = Double(value) / 100.0
                    break
                }
            }
        }

        return result
    }

    private static func properties(of service: io_object_t) -> [String: Any]? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS
        else { return nil }
        return unmanaged?.takeRetainedValue() as? [String: Any]
    }
}

/// IOBluetooth delivers notifications through an Objective-C target/selector pair.
/// The callback arrives on the main thread, but only a flag is forwarded; the
/// monitor re-reads the paired list itself.
final class BluetoothConnectTarget: NSObject {
    nonisolated(unsafe) var onChange: (() -> Void)?

    @objc func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        onChange?()
    }
}
