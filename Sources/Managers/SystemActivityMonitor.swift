//
//  SystemActivityMonitor.swift
//  FunNotch
//
//  Whether anyone is actually looking at the screen.
//
//  Polling a browser for what it is playing costs Apple Events in both
//  processes. Doing that every couple of seconds behind a lock screen is pure
//  waste, and it is exactly the sort of thing that makes a small utility show
//  up in the battery menu.
//

import AppKit
import Combine
import Foundation

@MainActor
final class SystemActivityMonitor: ObservableObject {
    static let shared = SystemActivityMonitor()

    /// True when the screen is locked, the display has slept, or the machine is
    /// going to sleep — anything that means the notch is not being watched.
    @Published private(set) var isIdle = false

    /// The same flag, readable from the polling code without hopping to the
    /// main actor. Only ever written on the main queue, and a stale read costs
    /// at most one extra poll.
    nonisolated(unsafe) private(set) static var isScreenIdle = false

    /// Asked whenever the idle state is worked out: true while something is
    /// deliberately on screen behind the lock screen (the lock-screen widgets),
    /// so that "locked" alone must not slow the media pollers to one read per
    /// 30 s. Only the locked reason is waived; a sleeping display or system
    /// still counts as idle. It is nil unless the widgets are showing, so with
    /// the feature off the behaviour is exactly what it was without the hook.
    static var keepsActiveWhileLocked: (@MainActor () -> Bool)?

    private var observers: [(center: NotificationCenter, handle: NSObjectProtocol)] = []

    /// The three reasons the screen can be unwatched are tracked separately: the
    /// display can wake while the lock screen is still up, and a wake
    /// notification for one reason must not cancel another that still holds.
    private enum Reason { case locked, displayAsleep, systemAsleep }
    private var active: Set<Reason> = []

    private init() {}

    func start() {
        guard observers.isEmpty else { return }

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification, .displayAsleep, on: true)
        observe(workspace, NSWorkspace.screensDidWakeNotification, .displayAsleep, on: false)
        observe(workspace, NSWorkspace.willSleepNotification, .systemAsleep, on: true)
        observe(workspace, NSWorkspace.didWakeNotification, .systemAsleep, on: false)

        // The lock screen is not a notification AppKit publishes; it comes over
        // the distributed centre, under a name Apple has never documented but
        // which every screen-lock-aware app on macOS relies on.
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked"), .locked, on: true)
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked"), .locked, on: false)

        // Launched while already locked: no notification will announce that.
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        if session?["CGSSessionScreenIsLocked"] as? Bool == true { set(.locked, on: true) }
    }

    func stop() {
        for observer in observers {
            observer.center.removeObserver(observer.handle)
        }
        observers.removeAll()
    }

    private func observe(_ centre: NotificationCenter, _ name: Notification.Name, _ reason: Reason, on: Bool) {
        let handle = centre.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.set(reason, on: on) }
        }
        observers.append((centre, handle))
    }

    private func set(_ reason: Reason, on: Bool) {
        if on { active.insert(reason) } else { active.remove(reason) }
        reevaluate()
    }

    /// Recomputes the idle state. Called after every reason change, and by the
    /// lock-screen widgets when they appear or disappear, since that changes
    /// the answer without any of the reasons changing.
    func reevaluate() {
        var reasons = active
        if reasons.contains(.locked), Self.keepsActiveWhileLocked?() == true {
            reasons.remove(.locked)
        }
        let idle = !reasons.isEmpty
        guard isIdle != idle else { return }
        isIdle = idle
        Self.isScreenIdle = idle
        DiagnosticLog.write("power", idle ? "screen off, backing off polling" : "screen on, resuming")
    }
}
