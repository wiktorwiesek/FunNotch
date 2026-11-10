//
//  LockScreenController.swift
//  FunNotch
//
//  Decides when the lock-screen widgets exist. Until the screen is locked, with
//  the "Pokazuj na ekranie blokady" switch on and something worth showing, all
//  this holds is two notification observers; the window, the SwiftUI tree and
//  the managers' observers all come into being on lock and are gone again on
//  unlock.
//
//  There are no timers here. While the widgets are up the media pollers must
//  not fall back to their locked-screen 30 s rate, which is what the
//  `SystemActivityMonitor` hook is for.
//

import AppKit
import Combine
import SwiftUI

/// Per-widget switches. The master switch is `Settings.showOnLockScreen`.
enum LockScreenPrefs {
    static let nowPlayingKey = "extras.lockscreen.nowPlaying"
    static let focusKey = "extras.lockscreen.focus"
    static let chargingKey = "extras.lockscreen.charging"
    static let weatherKey = "extras.lockscreen.weather"

    static var nowPlaying: Bool { value(nowPlayingKey) }
    static var focus: Bool { value(focusKey) }
    static var charging: Bool { value(chargingKey) }
    static var weather: Bool { value(weatherKey) }

    private static func value(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}

enum LockScreenExtras {
    @MainActor static func start() {
        LockScreenController.shared.start()
    }
}

@MainActor
final class LockScreenController: ObservableObject {
    static let shared = LockScreenController()

    /// Whether SkyLight offers everything needed. Nil until it has been
    /// checked, which happens when the settings view appears or on the first
    /// lock with the feature on — never at launch.
    @Published private(set) var isAvailable: Bool?

    private var observers: [NSObjectProtocol] = []
    private var window: LockScreenWindow?

    private init() {}

    /// True while the widgets are on screen.
    var isShowingWidgets: Bool { window != nil }

    func start() {
        guard observers.isEmpty else { return }

        let centre = DistributedNotificationCenter.default()
        observers.append(centre.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenLocked() }
        })
        observers.append(centre.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenUnlocked() }
        })

        // Launched while already locked: no notification will announce that.
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        if session?["CGSSessionScreenIsLocked"] as? Bool == true { screenLocked() }
    }

    /// Resolves the private symbols (without creating anything) so the
    /// settings view can say whether the feature can work on this system.
    func checkAvailability() {
        let available = SkyLightSpace.shared.isAvailable
        if isAvailable != available { isAvailable = available }
    }

    // MARK: - Lock / unlock

    private func screenLocked() {
        guard window == nil, Settings.shared.showOnLockScreen, Self.hasAnythingToShow() else { return }

        checkAvailability()
        guard isAvailable == true,
              let screen = NSScreen.screens.first ?? NSScreen.main,
              let window = LockScreenWindow(screen: screen)
        else {
            DiagnosticLog.write("lockscreen", "widgets not shown")
            return
        }
        self.window = window

        // From here on "locked" is not "nobody is looking", so the pollers
        // keep their normal rate; display sleep still backs them off.
        SystemActivityMonitor.keepsActiveWhileLocked = { [weak self] in self?.isShowingWidgets ?? false }
        SystemActivityMonitor.shared.reevaluate()
        DiagnosticLog.write("lockscreen", "widgets shown")
    }

    private func screenUnlocked() {
        guard let window else { return }
        window.close()
        self.window = nil

        SystemActivityMonitor.keepsActiveWhileLocked = nil
        SystemActivityMonitor.shared.reevaluate()
        DiagnosticLog.write("lockscreen", "widgets removed")
    }

    // MARK: - Content

    /// At least one enabled widget has something to draw right now. The same
    /// conditions decide which cards the view includes.
    static func hasAnythingToShow() -> Bool {
        (LockScreenPrefs.nowPlaying && !MusicManager.shared.track.isEmpty)
            || (LockScreenPrefs.focus && Self.hasTimer)
            || (LockScreenPrefs.charging && BatteryManager.shared.isPluggedIn)
            || (LockScreenPrefs.weather && WeatherManager.shared.conditions != nil)
    }

    /// A focus session or a running countdown.
    static var hasTimer: Bool {
        FocusManager.shared.isActive || TimerManager.shared.isCountdownRunning
    }
}
