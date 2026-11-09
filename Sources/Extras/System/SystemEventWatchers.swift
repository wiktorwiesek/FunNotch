//
//  SystemEventWatchers.swift
//  FunNotch
//
//  Three small watchers that turn a system event into an island: Caps Lock
//  toggling, the battery reaching a chosen level (or running low), and an
//  external drive being mounted — with a button to eject it.
//

import AppKit
import Combine
import DiskArbitration
import Foundation
import SwiftUI

// MARK: - Caps Lock

@MainActor
final class CapsLockWatcher {
    static let shared = CapsLockWatcher()

    static let announceKey = "extras.system.capsLock.announce"

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var fallbackTimer: Timer?
    private var started = false
    private var isOn = NSEvent.modifierFlags.contains(.capsLock)

    private init() {
        UserDefaults.standard.register(defaults: [Self.announceKey: true])
    }

    /// Safe to call repeatedly: monitors are installed once.
    func start() {
        guard !started else { return }
        started = true
        isOn = NSEvent.modifierFlags.contains(.capsLock)
        // Modifier changes are delivered to global monitors without Input
        // Monitoring access, unlike key presses. The local one covers our own
        // windows, which global monitors never see.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let on = event.modifierFlags.contains(.capsLock)
            MainActor.assumeIsolated {
                // Global modifier events reach us, so the polling net is not needed.
                self?.stopFallback()
                self?.handle(on)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let on = event.modifierFlags.contains(.capsLock)
            MainActor.assumeIsolated { self?.handle(on) }
            return event
        }
        // Safety net for systems that withhold global modifier events without
        // permission: the session's flag word is readable by anyone. `handle`
        // ignores anything the monitors already reported, so it never doubles up.
        // It is dropped on the first global event, and does not run at all while
        // the announcement is off, so it never polls forever for nothing.
        guard UserDefaults.standard.bool(forKey: Self.announceKey) else { return }
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            let on = CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
            MainActor.assumeIsolated {
                guard UserDefaults.standard.bool(forKey: Self.announceKey) else {
                    self?.stopFallback()
                    return
                }
                self?.handle(on)
            }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
    }

    private func stopFallback() {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    private func handle(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        guard UserDefaults.standard.bool(forKey: Self.announceKey) else { return }
        IslandCenter.shared.post(Island(
            symbol: on ? "capslock.fill" : "capslock",
            tint: on ? .orange : .white,
            title: "Caps Lock",
            detail: on ? " · włączony" : " · wyłączony",
            duration: 1.6
        ))
    }
}

// MARK: - Battery level

/// Announces when a charging battery reaches the level the user chose, and
/// when an unplugged one drops to the low threshold. It only reads
/// `BatteryManager`'s published state.
@MainActor
final class BatteryAlertWatcher {
    static let shared = BatteryAlertWatcher()

    static let chargeEnabledKey = "extras.system.battery.chargeAlert"
    static let chargeLevelKey = "extras.system.battery.chargeLevel"
    static let lowEnabledKey = "extras.system.battery.lowAlert"
    static let lowLevelKey = "extras.system.battery.lowLevel"

    private var cancellable: AnyCancellable?
    private var previousPercent: Int?
    private var chargeAnnounced = false
    private var lowAnnounced = false

    private init() {
        UserDefaults.standard.register(defaults: [
            Self.chargeEnabledKey: true,
            Self.chargeLevelKey: 80,
            Self.lowEnabledKey: true,
            Self.lowLevelKey: 20,
        ])
    }

    /// Safe to call repeatedly: the subscription is made once.
    func start() {
        guard cancellable == nil else { return }
        let battery = BatteryManager.shared
        let initial = Self.percent(level: battery.level, isCharged: battery.isCharged)
        previousPercent = initial
        // Already past a threshold when the app starts: that is not news.
        chargeAnnounced = battery.isPluggedIn && initial >= chargeLevel
        lowAnnounced = !battery.isPluggedIn && initial <= lowLevel

        cancellable = Publishers.CombineLatest4(
            battery.$level, battery.$isPluggedIn, battery.$isCharged, battery.$hasBattery
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] level, plugged, charged, hasBattery in
            MainActor.assumeIsolated {
                guard hasBattery else { return }
                self?.evaluate(percent: Self.percent(level: level, isCharged: charged), plugged: plugged)
            }
        }
    }

    private var chargeLevel: Int {
        min(100, max(80, UserDefaults.standard.integer(forKey: Self.chargeLevelKey)))
    }

    private var lowLevel: Int {
        min(30, max(5, UserDefaults.standard.integer(forKey: Self.lowLevelKey)))
    }

    private static func percent(level: Float, isCharged: Bool) -> Int {
        isCharged ? 100 : Int((level * 100).rounded())
    }

    private func evaluate(percent: Int, plugged: Bool) {
        defer { previousPercent = percent }
        let defaults = UserDefaults.standard

        // Charging side. Armed again once unplugged or a little below the level,
        // so a battery hovering around it does not announce repeatedly.
        let chargeLevel = chargeLevel
        if !plugged || percent < chargeLevel - 2 { chargeAnnounced = false }
        if plugged, !chargeAnnounced, percent >= chargeLevel, (previousPercent ?? 100) < chargeLevel {
            chargeAnnounced = true
            if defaults.bool(forKey: Self.chargeEnabledKey) {
                IslandCenter.shared.post(Island(
                    symbol: "battery.100.bolt",
                    tint: .green,
                    title: "Bateria",
                    detail: percent >= 100 ? " · w pełni naładowana" : " · naładowana do \(percent)%",
                    trailing: "\(percent)%",
                    duration: 4
                ))
            }
        }

        // Discharging side.
        let lowLevel = lowLevel
        if plugged || percent > lowLevel + 2 { lowAnnounced = false }
        if !plugged, !lowAnnounced, percent <= lowLevel, (previousPercent ?? 0) > lowLevel {
            lowAnnounced = true
            if defaults.bool(forKey: Self.lowEnabledKey) {
                IslandCenter.shared.post(Island(
                    symbol: percent <= 10 ? "battery.0" : "battery.25",
                    tint: percent <= 10 ? Color(red: 1, green: 0.35, blue: 0.32) : .orange,
                    title: "Bateria",
                    detail: " · niski poziom",
                    trailing: "\(percent)%",
                    duration: 4
                ))
            }
        }
    }
}

// MARK: - External drives

@MainActor
final class VolumeMountWatcher {
    static let shared = VolumeMountWatcher()

    static let announceKey = "extras.system.volumes.announce"

    private var observer: NSObjectProtocol?
    private let session = DASessionCreate(kCFAllocatorDefault)

    private init() {
        UserDefaults.standard.register(defaults: [Self.announceKey: true])
    }

    /// Safe to call repeatedly: the observer is added once.
    func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { [weak self] note in
            // The notification carries a plain path; read it before hopping actors.
            let path = (note.userInfo?["NSDevicePath"] as? String)
                ?? (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path
            MainActor.assumeIsolated {
                guard let path else { return }
                self?.handleMount(URL(fileURLWithPath: path))
            }
        }
    }

    private func handleMount(_ url: URL) {
        guard UserDefaults.standard.bool(forKey: Self.announceKey), isExternalDrive(url) else { return }
        let name = (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? url.lastPathComponent
        IslandCenter.shared.post(Island(
            symbol: "externaldrive.fill",
            tint: SettingsStyle.blue,
            title: name,
            detail: " · podłączony",
            action: IslandAction(title: "Wysuń") { [weak self] in
                self?.eject(url, name: name)
            },
            duration: 6
        ))
    }

    /// A physical drive that can be unplugged, as opposed to the startup disk,
    /// a mounted disk image or a network share.
    private func isExternalDrive(_ url: URL) -> Bool {
        guard let session,
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let description = DADiskCopyDescription(disk) as? [String: Any]
        else { return false }

        let isInternal = description[kDADiskDescriptionDeviceInternalKey as String] as? Bool ?? false
        let protocolName = description[kDADiskDescriptionDeviceProtocolKey as String] as? String
        let ejectable = description[kDADiskDescriptionMediaEjectableKey as String] as? Bool ?? false
        let removable = description[kDADiskDescriptionMediaRemovableKey as String] as? Bool ?? false
        // A mounted .dmg reports "Disk Image" (older systems: "Virtual Interface")
        // and looks external and removable, and a network share has no internal
        // flag at all, so both are filtered here.
        if protocolName == "Virtual Interface" || protocolName == "Disk Image" { return false }
        if description[kDADiskDescriptionVolumeNetworkKey as String] as? Bool == true { return false }
        // The startup disk is internal and neither removable nor ejectable; a
        // built-in SD card slot is internal but removable media.
        return !isInternal || ejectable || removable
    }

    private func eject(_ url: URL, name: String) {
        // Unmounting flushes writes and can take seconds; keep it off the main thread.
        Task.detached {
            let result: Result<Void, Error>
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                result = .success(())
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                switch result {
                case .success:
                    IslandCenter.shared.post(Island(
                        symbol: "checkmark.circle.fill", tint: .green, title: name,
                        detail: " · można bezpiecznie odłączyć", duration: 4
                    ))
                case let .failure(error):
                    DiagnosticLog.write("volumes", "eject \(name) failed: \(error.localizedDescription)")
                    let reason = (error as NSError).localizedFailureReason
                    IslandCenter.shared.post(Island(
                        symbol: "exclamationmark.triangle.fill", tint: .orange, title: name,
                        detail: " · " + (reason ?? "nie udało się wysunąć"), duration: 5
                    ))
                }
            }
        }
    }
}
