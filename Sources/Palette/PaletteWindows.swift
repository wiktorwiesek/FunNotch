//
//  PaletteWindows.swift
//  FunNotch
//
//  Open windows as palette results, and the "Przełącz okno" command that lists
//  only them.
//
//  Windows come from Accessibility, one app at a time, on a background queue:
//  every attribute read is synchronous IPC into the other process, so none of
//  it may run on the main thread, and one hung app must not hold up the list
//  (each element gets a short messaging timeout and each app a deadline). The
//  index is filled when the palette opens and refreshed at most every few
//  seconds while a query changes; it is emptied the moment the palette closes,
//  so a closed palette costs nothing and holds nothing. Without Accessibility
//  there are no window results and no permission prompt.
//
//  Window titles are user content and never reach the diagnostic log.
//

import AppKit
import ApplicationServices
import Foundation

// MARK: - Model

/// One open window. `element` is only ever touched off the main thread (the scan
/// and `PaletteWindowScanner.raise`), which is why the type is marked as safe to
/// hand between queues.
struct PaletteWindow: Identifiable, @unchecked Sendable {
    let id: String
    let pid: pid_t
    let appName: String
    /// Bundle path, for the icon the launcher shows; nil for apps without one.
    let appPath: String?
    /// The window's own title, or the app's name for a window without one.
    let title: String
    /// Title and app name, folded for matching.
    let folded: String
    let isMinimized: Bool
    let element: AXUIElement
}

/// What the scan needs to know about a running app, copied on the main thread.
private struct PaletteWindowTarget: Sendable {
    let pid: pid_t
    let name: String
    let path: String?
    /// Position among apps when it has no window on screen to be ranked by.
    let fallbackRank: Int
}

// MARK: - Index

@MainActor
final class PaletteWindowIndex: ObservableObject {
    static let shared = PaletteWindowIndex()

    /// Most recently active app first, each app's windows front to back.
    @Published private(set) var windows: [PaletteWindow] = []
    /// False from opening the palette until the first scan lands.
    @Published private(set) var hasLoaded = false

    /// A scan every keystroke would hammer other apps; a few seconds keeps the
    /// list current enough for a palette that is open for moments.
    private static let minimumInterval: TimeInterval = 4

    private var generation = 0
    private var isScanning = false
    private var lastStart: Date?

    private init() {}

    /// The palette just opened: scan now.
    func refresh() {
        start()
    }

    /// The palette is open and the query changed: scan again only if the last
    /// scan is old.
    func refreshIfStale() {
        if let lastStart, Date().timeIntervalSince(lastStart) < Self.minimumInterval { return }
        start()
    }

    /// The palette closed: forget everything, and ignore a scan still running.
    func clear() {
        generation += 1
        isScanning = false
        lastStart = nil
        if !windows.isEmpty { windows = [] }
        if hasLoaded { hasLoaded = false }
    }

    private func start() {
        guard !isScanning else { return }
        guard AXIsProcessTrusted() else {
            // No permission: no windows, and no prompt (the palette is not the
            // place to ask for it).
            if !windows.isEmpty { windows = [] }
            hasLoaded = true
            return
        }
        isScanning = true
        lastStart = Date()
        let token = generation

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var targets: [PaletteWindowTarget] = []
        for (position, app) in NSWorkspace.shared.runningApplications.enumerated() {
            guard app.activationPolicy == .regular, !app.isTerminated,
                  app.processIdentifier != ownPID else { continue }
            targets.append(PaletteWindowTarget(
                pid: app.processIdentifier,
                name: app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "",
                path: app.bundleURL?.path,
                // The frontmost app leads even when it has nothing on screen.
                fallbackRank: app.processIdentifier == frontPID ? -1 : 1000 + position
            ))
        }

        DispatchQueue.global(qos: .userInitiated).async { [targets] in
            let found = PaletteWindowScanner.scan(targets, frontPID: frontPID)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    PaletteWindowIndex.shared.finish(found, token: token)
                }
            }
        }
    }

    private func finish(_ found: [PaletteWindow], token: Int) {
        guard token == generation else { return }
        isScanning = false
        windows = found
        hasLoaded = true
    }
}

// MARK: - Scanning and raising (background queues only)

private final class PaletteWindowScanBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int: [PaletteWindow]] = [:]

    func set(_ windows: [PaletteWindow], at index: Int) {
        lock.lock()
        storage[index] = windows
        lock.unlock()
    }

    func value(at index: Int) -> [PaletteWindow] {
        lock.lock()
        defer { lock.unlock() }
        return storage[index] ?? []
    }
}

private enum PaletteWindowScanner {
    /// Longest an app may take to list its windows, however many of its
    /// attribute reads each wait out their own timeout.
    private static let appDeadline: TimeInterval = 1.0
    private static let elementTimeout: Float = 0.25

    static func scan(_ targets: [PaletteWindowTarget], frontPID: pid_t?) -> [PaletteWindow] {
        guard !targets.isEmpty else { return [] }
        let zRanks = onScreenRanks()
        let box = PaletteWindowScanBox()
        // Apps are independent, so a slow one costs its own time, not the sum.
        DispatchQueue.concurrentPerform(iterations: targets.count) { index in
            box.set(windows(of: targets[index]), at: index)
        }

        func rank(_ target: PaletteWindowTarget) -> Int {
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

    private static func windows(of target: PaletteWindowTarget) -> [PaletteWindow] {
        let deadline = Date().addingTimeInterval(appDeadline)
        let application = AXUIElementCreateApplication(target.pid)
        // The timeout covers only the element it is set on, so each one below
        // gets its own.
        AXUIElementSetMessagingTimeout(application, elementTimeout)
        guard let list = attribute(application, kAXWindowsAttribute) as? [AXUIElement] else { return [] }

        var result: [PaletteWindow] = []
        for window in list {
            guard Date() < deadline else { break }
            AXUIElementSetMessagingTimeout(window, elementTimeout)
            // Standard windows and dialogs; palettes, sheets and the like are not
            // things anyone switches to.
            guard let subrole = attribute(window, kAXSubroleAttribute) as? String,
                  subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole else { continue }
            let rawTitle = (attribute(window, kAXTitleAttribute) as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = rawTitle.isEmpty ? target.name : rawTitle
            let minimized = attribute(window, kAXMinimizedAttribute) as? Bool ?? false
            result.append(PaletteWindow(
                id: "window:\(target.pid):\(CFHash(window))",
                pid: target.pid,
                appName: target.name,
                appPath: target.path,
                title: title,
                folded: PaletteMatch.fold(title == target.name ? title : "\(title) \(target.name)"),
                isMinimized: minimized,
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
    static func raise(_ window: PaletteWindow) {
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
                        DiagnosticLog.write("palette", "window raise failed (AX error \(raised.rawValue))")
                    }
                    guard let app = NSRunningApplication(processIdentifier: pid) else { return }
                    if app.isHidden { app.unhide() }
                    app.activate()
                }
            }
        }
    }
}

// MARK: - Palette integration

@MainActor
enum PaletteWindows {
    /// Registers "Przełącz okno". Safe to call repeatedly.
    static func registerCommand() {
        PaletteCommandRegistry.shared.register(PaletteCommand(
            id: "palette.switchWindow",
            title: "Przełącz okno",
            subtitle: "Lista otwartych okien, od ostatnio używanych",
            symbol: "macwindow.on.rectangle",
            keywords: ["okno", "okna", "window", "windows", "switch", "przełącz", "przelacz"],
            perform: { PaletteController.shared.show(scope: .windows) }
        ))
    }

    static func item(for window: PaletteWindow) -> PaletteItem {
        PaletteItem(
            id: window.id,
            icon: window.appPath.map { PaletteItem.Icon.file($0) } ?? PaletteItem.Icon.symbol("macwindow", SettingsStyle.blue),
            title: window.title,
            subtitle: window.appName,
            trailing: window.isMinimized ? "Zminimalizowane" : "Okno",
            // Raising the window activates its app; handing focus back to the
            // previous app first would fight that.
            restoresFocus: false,
            run: { PaletteWindowScanner.raise(window) }
        )
    }

    /// Windows matching `folded`, best first; every window, in recency order,
    /// when it is empty.
    static func matches(_ folded: String, in windows: [PaletteWindow]) -> [(PaletteWindow, Int)] {
        if folded.isEmpty { return windows.map { ($0, 0) } }
        var scored: [(window: PaletteWindow, score: Int, position: Int)] = []
        for (position, window) in windows.enumerated() {
            if let score = PaletteMatch.score(query: folded, in: window.folded) {
                scored.append((window, score, position))
            }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.position < $1.position }
        return scored.map { ($0.window, $0.score) }
    }

    /// Shown in the windows listing when there is nothing real to list yet.
    static func statusItem(isTrusted: Bool) -> PaletteItem {
        if !isTrusted {
            return PaletteItem(
                id: "windows:no-access",
                icon: .symbol("hand.raised.fill", SettingsStyle.orange),
                title: "Okna wymagają dostępu do Dostępności",
                subtitle: "Enter otwiera Ustawienia systemowe, gdzie możesz go włączyć",
                restoresFocus: false,
                run: {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            )
        }
        return PaletteItem(
            id: "windows:loading",
            icon: .symbol("macwindow.on.rectangle", SettingsStyle.blue),
            title: "Szukam okien…",
            subtitle: nil,
            keepsOpen: true,
            run: {}
        )
    }
}
