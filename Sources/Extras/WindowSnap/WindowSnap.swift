//
//  WindowSnap.swift
//  FunNotch
//
//  Entry point and coordinator for the two window features: snapping a window
//  by dropping it under the notch, and moving or resizing it with a held
//  modifier. Both are off until switched on, and both need Accessibility, so
//  this decides — from the settings and the permission together — which of
//  them should be running, and re-decides whenever either changes.
//

import AppKit
import Foundation

/// Called once from the app's startup.
@MainActor
enum WindowSnap {
    static func start() {
        WindowSnapManager.shared.start()
    }
}

enum WindowSnapKeys {
    static let notchSnap = "extras.windowsnap.notchSnap"
    static let modifierDrag = "extras.windowsnap.modifierDrag"
    static let modifier = "extras.windowsnap.modifier"
}

@MainActor
final class WindowSnapManager: ObservableObject {
    static let shared = WindowSnapManager()

    @Published private(set) var accessibilityGranted = WindowAccess.isTrusted

    private var started = false
    private var watchdog: Timer?

    private init() {}

    var notchSnapEnabled: Bool { UserDefaults.standard.bool(forKey: WindowSnapKeys.notchSnap) }
    var modifierDragEnabled: Bool { UserDefaults.standard.bool(forKey: WindowSnapKeys.modifierDrag) }

    var modifier: WindowDragModifier {
        UserDefaults.standard.string(forKey: WindowSnapKeys.modifier)
            .flatMap(WindowDragModifier.init(rawValue:)) ?? .controlOption
    }

    /// Safe to call repeatedly: observers are added once, and `apply()` only
    /// changes what actually differs.
    func start() {
        guard !started else {
            apply()
            return
        }
        started = true

        // A switch or the modifier picker changing in Settings.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
        // macOS announces a change in the Accessibility list; the grant takes
        // a moment to become visible to `AXIsProcessTrusted`.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                MainActor.assumeIsolated { self?.apply() }
            }
        }

        apply()
    }

    /// Brings the running features in line with the settings and the permission.
    func apply() {
        let trusted = WindowAccess.isTrusted
        if trusted != accessibilityGranted {
            accessibilityGranted = trusted
            DiagnosticLog.write("windowsnap", "Accessibility \(trusted ? "granted" : "revoked")")
        }

        if notchSnapEnabled && trusted {
            NotchWindowSnapper.shared.start()
        } else {
            NotchWindowSnapper.shared.stop()
        }

        if modifierDragEnabled && trusted {
            ModifierWindowDragger.shared.start(modifier: modifier)
        } else {
            ModifierWindowDragger.shared.stop()
        }

        updateWatchdog()
    }

    /// The Accessibility list can change without any notification we get — a
    /// rebuild with a new signature silently drops the grant — so while a
    /// feature is switched on the permission is re-checked every few seconds.
    private func updateWatchdog() {
        let needed = notchSnapEnabled || modifierDragEnabled
        if needed, watchdog == nil {
            let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            }
            timer.tolerance = 1
            RunLoop.main.add(timer, forMode: .common)
            watchdog = timer
        } else if !needed, let timer = watchdog {
            timer.invalidate()
            watchdog = nil
        }
    }

    /// The settings button: asks, and also opens the pane, because once macOS
    /// has an answer on record the system prompt no longer appears.
    func requestAccess() {
        WindowAccess.requestPrompt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            WindowAccess.openPrivacyPane()
        }
        apply()
    }
}
