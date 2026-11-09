//
//  SettingsWindowController.swift
//  FunNotch
//
//  Hosts the settings UI in a normal window. The app is an accessory, so it
//  temporarily becomes a regular app while settings are on screen — otherwise
//  the window could never take keyboard focus.
//

import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    /// Opens settings on a specific page, for links from inside the notch.
    func show(tab: SettingsTab) {
        SettingsNavigation.shared.tab = tab
        show()
    }

    func show() {
        if let window {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(
            rootView: SettingsView().environmentObject(Settings.shared)
        )
        hosting.sizingOptions = [.minSize]

        let window = NSWindow(contentViewController: hosting)
        window.title = "Ustawienia Fun Notch"
        // The sidebar runs up under the traffic lights, System Settings style.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.setContentSize(NSSize(width: 820, height: 620))
        window.contentMinSize = NSSize(width: 780, height: 560)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        self.window = window

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        // Forgotten at once, so a reopen right now builds a fresh window rather
        // than reviving this one while its content is being taken apart.
        if window === closing { window = nil }
        DispatchQueue.main.async {
            Self.refreshActivationPolicy(excluding: closing)
            // A closed window keeps its SwiftUI tree alive, and every
            // `TimelineView(.animation)` in it (the mascot pickers on the
            // decor page) keeps redrawing at 30 Hz — measured at ~30 body
            // updates a second after `close()`, enough to hold the app at
            // tens of percent CPU long after Settings was dismissed. Dropping
            // the content stops that; `show()` builds a fresh one.
            closing?.contentViewController = nil
            closing?.delegate = nil
        }
    }

    /// Keeps the Dock icon while any of the app's own windows is open, and
    /// drops it once the last one closes. The notch panels do not count.
    static func refreshActivationPolicy(excluding closing: NSWindow?) {
        let hasWindow = NSApp.windows.contains { window in
            window !== closing && window.isVisible && window.styleMask.contains(.titled)
        }
        NSApp.setActivationPolicy(hasWindow ? .regular : .accessory)
    }
}
