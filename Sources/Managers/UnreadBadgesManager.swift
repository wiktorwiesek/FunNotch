//
//  UnreadBadgesManager.swift
//  FunNotch
//
//  The red badges chat apps put on their Dock icons — Slack's count, or its
//  dot when there are only unread channels — read straight from Launch
//  Services, which is where the Dock gets them too. Unlike reading the Dock
//  over Accessibility this needs no permission at all.
//
//  `_LSCopyApplicationInformationItem` is private, so like MediaRemote it is
//  looked up at run time; if it ever goes away the widget just shows nothing.
//

import AppKit
import Foundation

@MainActor
final class UnreadBadgesManager: ObservableObject {
    static let shared = UnreadBadgesManager()

    struct Badge: Identifiable, Equatable {
        let bundleIdentifier: String
        /// "3", "99+", or "•" for unread without a count.
        let label: String
        var id: String { bundleIdentifier }
    }

    /// Chat apps worth watching, in the order they are shown.
    static let watched = [
        "com.tinyspeck.slackmacgap", // Slack
        "dev.vencord.vesktop", // Vesktop
        "com.hnc.Discord", // Discord
    ]

    @Published private(set) var badges: [Badge] = []

    private var timer: Timer?
    private var launchObservers: [NSObjectProtocol] = []

    private typealias CreateASN = @convention(c) (CFAllocator?, pid_t) -> Unmanaged<CFTypeRef>?
    private typealias CopyItem = @convention(c) (Int32, CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private let createASN: CreateASN?
    private let copyItem: CopyItem?

    private init() {
        let handle = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW)
        createASN = dlsym(handle, "_LSASNCreateWithPid").map { unsafeBitCast($0, to: CreateASN.self) }
        copyItem = dlsym(handle, "_LSCopyApplicationInformationItem").map { unsafeBitCast($0, to: CopyItem.self) }
    }

    /// Safe to call from every `onAppear`: only one set of observers ever exists.
    /// The poll runs only while a watched app is running, and not behind a lock
    /// screen or a sleeping display, where nobody could see a badge change.
    func start() {
        guard launchObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            launchObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncTimer() }
            })
        }
        syncTimer()
    }

    private func syncTimer() {
        let watching = Self.watched.contains {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
        }
        if watching, timer == nil {
            let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
                guard !SystemActivityMonitor.isScreenIdle else { return }
                MainActor.assumeIsolated { self?.refresh() }
            }
            timer.tolerance = 1
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !watching {
            timer?.invalidate()
            timer = nil
        }
        refresh()
    }

    func refresh() {
        let next = Self.watched.compactMap { identifier -> Badge? in
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first,
                  let label = badgeLabel(of: app.processIdentifier)
            else { return nil }
            return Badge(bundleIdentifier: identifier, label: label)
        }
        if next != badges { badges = next }
    }

    private func badgeLabel(of pid: pid_t) -> String? {
        guard let createASN, let copyItem,
              let asn = createASN(nil, pid)?.takeRetainedValue(),
              let item = copyItem(-2, asn, "StatusLabel" as CFString)?.takeRetainedValue() as? [String: Any],
              let label = item["label"] as? String,
              !label.isEmpty
        else { return nil }
        return label
    }

    /// Brings the first app with something unread to the front.
    func openFirst() {
        guard let badge = badges.first,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: badge.bundleIdentifier).first
        else { return }
        app.activate()
    }

    static func icon(for bundleIdentifier: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
