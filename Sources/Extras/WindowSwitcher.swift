//
//  WindowSwitcher.swift
//  FunNotch
//
//  "Przełącz okno": every open window as a menu at the pointer, most recently
//  used app first; picking one brings it to the front.
//
//  Windows come from Accessibility, one app at a time, on a background queue:
//  every attribute read is synchronous IPC into the other process, so none of
//  it may run on the main thread, and one hung app must not hold up the list
//  (each element gets a short messaging timeout and each app a deadline).
//  Nothing is scanned or kept unless the menu is asked for. Without
//  Accessibility the notch says so, and nothing prompts.
//
//  Window titles are user content and never reach the diagnostic log.
//

import AppKit
import ApplicationServices
import Foundation
import SwiftUI

@MainActor
enum WindowSwitcher {
    /// More than this is not a menu any more.
    private static let limit = 40

    /// Scans, then opens the menu where the pointer is by then.
    static func showMenu() {
        guard AXIsProcessTrusted() else {
            announce("wymaga uprawnienia Dostępność", tint: .orange)
            return
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var targets: [WindowScanner.Target] = []
        for (position, app) in NSWorkspace.shared.runningApplications.enumerated() {
            guard app.activationPolicy == .regular, !app.isTerminated,
                  app.processIdentifier != ownPID else { continue }
            targets.append(WindowScanner.Target(
                pid: app.processIdentifier,
                name: app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "",
                // The frontmost app leads even when it has nothing on screen.
                fallbackRank: app.processIdentifier == frontPID ? -1 : 1000 + position
            ))
        }

        DispatchQueue.global(qos: .userInitiated).async { [targets] in
            let found = WindowScanner.scan(targets, frontPID: frontPID)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { present(found) }
            }
        }
    }

    private static func present(_ windows: [OpenWindow]) {
        guard !windows.isEmpty else {
            announce("brak otwartych okien", tint: .white)
            return
        }
        PointerMenu.show(windows.prefix(limit).map { window in
            PointerMenu.Item(
                title: menuTitle(title: window.title, appName: window.appName, isMinimized: window.isMinimized),
                symbol: "macwindow"
            ) {
                WindowScanner.raise(window)
            }
        })
    }

    /// "Title — App", the app alone for a window without a title of its own,
    /// cut to a width a menu can carry.
    static func menuTitle(title: String, appName: String, isMinimized: Bool) -> String {
        var text = title
        if text.count > 60 { text = String(text.prefix(59)) + "…" }
        if title != appName, !appName.isEmpty { text += " — " + appName }
        if isMinimized { text += " (zminimalizowane)" }
        return text
    }

    private static func announce(_ detail: String, tint: Color) {
        IslandCenter.shared.post(Island(symbol: "macwindow.on.rectangle", tint: tint, title: "Okna", detail: detail, duration: 3))
    }
}

/// One open window. `element` is only ever touched off the main thread (the
/// scan and `WindowScanner.raise`), which is why the type is marked as safe to
/// hand between queues.
private struct OpenWindow: @unchecked Sendable {
    let pid: pid_t
    let appName: String
    /// The window's own title, or the app's name for a window without one.
    let title: String
    let isMinimized: Bool
    let element: AXUIElement
}

private final class WindowScanBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int: [OpenWindow]] = [:]

    func set(_ windows: [OpenWindow], at index: Int) {
        lock.lock()
        storage[index] = windows
        lock.unlock()
    }

    func value(at index: Int) -> [OpenWindow] {
        lock.lock()
        defer { lock.unlock() }
        return storage[index] ?? []
    }
}

/// Scanning and raising: background queues only.
private enum WindowScanner {
    /// What the scan needs to know about a running app, copied on the main thread.
    struct Target: Sendable {
        let pid: pid_t
        let name: String
        /// Position among apps when it has no window on screen to be ranked by.
        let fallbackRank: Int
    }

    /// Longest an app may take to list its windows, however many of its
    /// attribute reads each wait out their own timeout.
    private static let appDeadline: TimeInterval = 1.0
    private static let elementTimeout: Float = 0.25

    static func scan(_ targets: [Target], frontPID: pid_t?) -> [OpenWindow] {
        guard !targets.isEmpty else { return [] }
        let zRanks = onScreenRanks()
        let box = WindowScanBox()
        // Apps are independent, so a slow one costs its own time, not the sum.
        DispatchQueue.concurrentPerform(iterations: targets.count) { index in
            box.set(windows(of: targets[index]), at: index)
        }

        func rank(_ target: Target) -> Int {
            if target.pid == frontPID { return -1 }
            return zRanks[target.pid] ?? target.fallbackRank
        }
        let order = targets.indices.sorted { left, right in
            let a = rank(targets[left]), b = rank(targets[right])
            return a != b ? a < b : left < right
        }
        return order.flatMap { box.value(at: $0) }
    }

    /// App rank by the front-to-back order of windows on screen: a better
    /// "most recently used" signal than the running-apps list, and it needs no
    /// permission (no window names are read).
    private static func onScreenRanks() -> [pid_t: Int] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [:] }
        var ranks: [pid_t: Int] = [:]
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int ?? 0) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  ranks[pid] == nil else { continue }
            ranks[pid] = ranks.count
        }
        return ranks
    }

    private static func windows(of target: Target) -> [OpenWindow] {
        let deadline = Date().addingTimeInterval(appDeadline)
        let application = AXUIElementCreateApplication(target.pid)
        // The timeout covers only the element it is set on, so each one below
        // gets its own.
        AXUIElementSetMessagingTimeout(application, elementTimeout)
        guard let list = attribute(application, kAXWindowsAttribute) as? [AXUIElement] else { return [] }

        var result: [OpenWindow] = []
        for window in list {
            guard Date() < deadline else { break }
            AXUIElementSetMessagingTimeout(window, elementTimeout)
            // Standard windows and dialogs; palettes, sheets and the like are not
            // things anyone switches to.
            guard let subrole = attribute(window, kAXSubroleAttribute) as? String,
                  subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole else { continue }
            let rawTitle = (attribute(window, kAXTitleAttribute) as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            result.append(OpenWindow(
                pid: target.pid,
                appName: target.name,
                title: rawTitle.isEmpty ? target.name : rawTitle,
                isMinimized: attribute(window, kAXMinimizedAttribute) as? Bool ?? false,
                element: window
            ))
        }
        return result
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    /// Brings `window` to the front: un-minimise, raise, make it the app's main
    /// window, then activate the app. The Accessibility calls wait on the other
    /// app, so they run off the main thread; only the activation comes back.
    static func raise(_ window: OpenWindow) {
        DispatchQueue.global(qos: .userInitiated).async {
            let element = window.element
            AXUIElementSetMessagingTimeout(element, 0.5)
            if attribute(element, kAXMinimizedAttribute) as? Bool == true {
                AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            let raised = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
            let pid = window.pid
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if raised != .success {
                        DiagnosticLog.write("windows", "window raise failed (AX error \(raised.rawValue))")
                    }
                    guard let app = NSRunningApplication(processIdentifier: pid) else { return }
                    if app.isHidden { app.unhide() }
                    app.activate()
                }
            }
        }
    }
}
