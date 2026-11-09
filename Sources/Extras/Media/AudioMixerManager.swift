//
//  AudioMixerManager.swift
//  FunNotch
//
//  Per-app volume and EQ. It finds the apps that are producing audio (Core
//  Audio publishes a process object for each), and for any app whose level,
//  mute or EQ is not at its default it puts a muted process tap on it and plays
//  the audio back through our own gain stage. Apps left at 100% with a flat EQ
//  are never touched, so the mixer costs nothing until used.
//
//  What this cannot do: taps need the "system audio recording" permission, the
//  playback runs one buffer behind the original (a few tens of milliseconds,
//  visible in lip-sync on video), and an app that opens a new audio process
//  while tapped has its tap rebuilt, which clicks once.
//

import AppKit
import Combine
import CoreAudio
import Darwin
import SwiftUI

struct MixerAppSettings: Codable, Equatable {
    /// 0 ... 1.5, linear.
    var volume = 1.0
    var muted = false
    /// Decibels, -12 ... +12.
    var bass = 0.0
    var mid = 0.0
    var treble = 0.0

    var isDefault: Bool {
        !muted && abs(volume - 1) < 0.005 && bass == 0 && mid == 0 && treble == 0
    }

    var hasEQ: Bool { bass != 0 || mid != 0 || treble != 0 }
}

/// One app that has an audio process right now.
struct MixerApp: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: NSImage?
    let isPlaying: Bool
    let isTapped: Bool
    /// Why the app could not be taken over, when it could not.
    let problem: String?

    static func == (lhs: MixerApp, rhs: MixerApp) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.isPlaying == rhs.isPlaying
            && lhs.isTapped == rhs.isTapped && lhs.problem == rhs.problem
    }
}

@MainActor
final class AudioMixerManager: ObservableObject {
    static let shared = AudioMixerManager()

    enum Availability: Equatable {
        case available
        /// macOS older than process taps.
        case unsupportedOS
        case permissionDenied
    }

    @Published private(set) var apps: [MixerApp] = []
    @Published private(set) var availability: Availability = .available
    @Published private(set) var permission: AudioCapturePermission.Status = .unknown
    @Published private(set) var settings: [String: MixerAppSettings] = [:]

    private static let storageKey = "extras.media.mixer.levels"
    /// A tap stays on an app this long after it falls silent, so a pause
    /// between songs does not rebuild it.
    private static let idleGrace: TimeInterval = 8
    private static let retryAfterFailure: TimeInterval = 20

    private var started = false
    private var timer: Timer?
    private var isPanelVisible = false
    private let observer = AudioPropertyObserver()
    // The tap objects are macOS 14.2+, so they are stored type-erased.
    private var taps: [String: AnyObject] = [:]
    private var lastPlayingAt: [String: Date] = [:]
    private var failures: [String: (message: String, at: Date)] = [:]
    /// When each tap last heard anything, for spotting a denied permission.
    private var lastHeardAt: [String: Date] = [:]
    private var terminationObserver: NSObjectProtocol?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([String: MixerAppSettings].self, from: data) {
            settings = saved.filter { !$0.value.isDefault }
        }
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true

        guard #available(macOS 14.2, *) else {
            availability = .unsupportedOS
            return
        }

        permission = AudioCapturePermission.status

        // Taps are bound to the output device they were built against.
        observer.add(AudioObjects.system, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            self?.releaseAllTaps()
            self?.refresh()
        }

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseAllTaps() }
        }

        updateTimer()
        refresh()
    }

    /// The panel being open makes the list refresh quickly.
    func setPanelVisible(_ visible: Bool) {
        guard isPanelVisible != visible else { return }
        isPanelVisible = visible
        updateTimer()
        if visible {
            permission = AudioCapturePermission.status
            refresh()
        }
    }

    /// Asks for the permission when it has not been decided, otherwise opens
    /// the place where it can be changed.
    func requestPermission() {
        switch AudioCapturePermission.status {
        case .notDetermined, .unknown:
            AudioCapturePermission.request { [weak self] _ in
                self?.permission = AudioCapturePermission.status
                self?.refresh()
            }
        case .denied, .granted:
            AudioCapturePermission.openSystemSettings()
        }
    }

    private func updateTimer() {
        timer?.invalidate()
        timer = nil
        guard started, availability != .unsupportedOS else { return }
        // Needed in the background only while something has to be kept up:
        // a tap running, or saved levels waiting for their app to play.
        let needsBackground = !taps.isEmpty || !settings.isEmpty
        guard isPanelVisible || needsBackground else { return }
        let timer = Timer(timeInterval: isPanelVisible ? 1 : 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: Changing levels

    func levels(for id: String) -> MixerAppSettings { settings[id] ?? MixerAppSettings() }

    func update(_ id: String, _ change: (inout MixerAppSettings) -> Void) {
        var next = levels(for: id)
        change(&next)
        // 100% is the one value people mean exactly; make it easy to land on.
        if abs(next.volume - 1) < 0.03 { next.volume = 1 }
        next.volume = min(max(next.volume, 0), 1.5)
        guard next != levels(for: id) else { return }

        if next.isDefault {
            settings[id] = nil
        } else {
            settings[id] = next
        }
        persist()

        // While a slider is dragged the tap already exists and only needs the
        // new numbers; listing every audio process 60 times a second would not.
        if #available(macOS 14.2, *), let tap = taps[id] as? MixerTap, !next.isDefault {
            tap.apply(next)
        } else {
            refresh()
        }
        updateTimer()
    }

    func reset(_ id: String) {
        update(id) { $0 = MixerAppSettings() }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    // MARK: Reconciling

    private struct AudioGroup {
        var name: String
        var icon: NSImage?
        var processObjects: [AudioObjectID] = []
        var isPlaying = false
    }

    func refresh() {
        guard #available(macOS 14.2, *) else { return }
        refreshApps()
    }

    @available(macOS 14.2, *)
    private func refreshApps() {
        let groups = currentGroups()
        let now = Date()

        for (id, group) in groups where group.isPlaying {
            lastPlayingAt[id] = now
        }

        // Apps that are playing, plus any that have a tap or saved levels, so a
        // paused app can still be turned back up or reset.
        var shown: [MixerApp] = []
        for (id, group) in groups {
            let configured = settings[id] != nil
            guard group.isPlaying || taps[id] != nil || configured else { continue }
            shown.append(MixerApp(
                id: id, name: group.name, icon: group.icon,
                isPlaying: group.isPlaying, isTapped: taps[id] != nil,
                problem: failures[id].map(\.message)
            ))
        }
        shown.sort { lhs, rhs in
            if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        if shown != apps { apps = shown }

        reconcileTaps(groups: groups, now: now)

        let status = AudioCapturePermission.status
        if status != permission { permission = status }
        let next: Availability = status == .denied ? .permissionDenied : .available
        if next != availability { availability = next }
    }

    @available(macOS 14.2, *)
    private func reconcileTaps(groups: [String: AudioGroup], now: Date) {
        // Drop taps that are no longer wanted.
        for (id, object) in taps {
            guard let tap = object as? MixerTap else { continue }
            let group = groups[id]
            let wanted = settings[id] != nil
                && group != nil
                && now.timeIntervalSince(lastPlayingAt[id] ?? .distantPast) < Self.idleGrace
            let changedProcesses = group.map { Set($0.processObjects) != Set(tap.processObjects) } ?? false
            if !wanted || changedProcesses {
                tap.stop()
                taps[id] = nil
                lastHeardAt[id] = nil
            }
        }

        guard permission != .denied else { return }

        for (id, group) in groups {
            guard let appSettings = settings[id], taps[id] == nil,
                  now.timeIntervalSince(lastPlayingAt[id] ?? .distantPast) < Self.idleGrace
            else { continue }
            if let failure = failures[id], now.timeIntervalSince(failure.at) < Self.retryAfterFailure { continue }

            do {
                taps[id] = try MixerTap(processObjects: group.processObjects, settings: appSettings)
                failures[id] = nil
                lastHeardAt[id] = now
                DiagnosticLog.write("mixer", "tap on \(group.name)")
            } catch {
                let message = (error as? AudioTapError)?.description ?? error.localizedDescription
                failures[id] = (message, now)
                DiagnosticLog.write("mixer", "tap on \(group.name) failed: \(message)")
            }
        }

        watchForSilence(groups: groups, now: now)
        updateTimer()
    }

    /// With the permission missing a tap can come up fine and deliver only
    /// zeros — and a muted tap would then silence the app. If an app is
    /// playing and its tap has heard nothing for a few seconds, take the tap
    /// off again and say why.
    @available(macOS 14.2, *)
    private func watchForSilence(groups: [String: AudioGroup], now: Date) {
        guard AudioCapturePermission.status != .granted else { return }
        for (id, object) in taps {
            guard let tap = object as? MixerTap else { continue }
            if tap.takePeak() > 0.000_01 {
                lastHeardAt[id] = now
                continue
            }
            guard groups[id]?.isPlaying == true,
                  now.timeIntervalSince(lastHeardAt[id] ?? now) > 3
            else { continue }
            tap.stop()
            taps[id] = nil
            failures[id] = ("Brak dźwięku z tapa. Sprawdź zgodę na nagrywanie dźwięku systemu.", now)
            DiagnosticLog.write("mixer", "tap on \(id) heard nothing; released")
        }
    }

    private func releaseAllTaps() {
        guard #available(macOS 14.2, *) else { return }
        for object in taps.values {
            (object as? MixerTap)?.stop()
        }
        taps.removeAll()
        lastHeardAt.removeAll()
    }

    // MARK: Finding apps

    /// Audio processes grouped by the app they belong to. Browsers and other
    /// apps play through helper processes, so the helpers are folded into
    /// their app and tapped together.
    @available(macOS 14.2, *)
    private func currentGroups() -> [String: AudioGroup] {
        var groups: [String: AudioGroup] = [:]
        let ownPID = ProcessInfo.processInfo.processIdentifier

        for object in AudioObjects.objectIDs(AudioObjects.system, kAudioHardwarePropertyProcessObjectList) {
            guard let pid = AudioObjects.value(object, kAudioProcessPropertyPID, as: pid_t.self),
                  pid != ownPID,
                  let owner = AudioAppResolver.owner(of: pid, bundleID: AudioObjects.string(object, kAudioProcessPropertyBundleID))
            else { continue }

            let playing = (AudioObjects.value(object, kAudioProcessPropertyIsRunningOutput, as: UInt32.self) ?? 0) != 0
            var group = groups[owner.id] ?? AudioGroup(name: owner.name, icon: owner.icon)
            group.processObjects.append(object)
            group.isPlaying = group.isPlaying || playing
            groups[owner.id] = group
        }
        return groups
    }
}

// MARK: - Which app owns an audio process

enum AudioAppResolver {
    struct Owner {
        let id: String
        let name: String
        let icon: NSImage?
    }

    private typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t

    /// The process Activity Monitor would blame: for an XPC helper or a web
    /// content process, the app that started it.
    private static let responsiblePID: ResponsibleFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: ResponsibleFunction.self)
    }()

    static func owner(of pid: pid_t, bundleID: String?) -> Owner? {
        let own = Bundle.main.bundleIdentifier

        var candidates: [pid_t] = [pid]
        if let responsible = responsiblePID?(pid), responsible > 1, responsible != pid {
            candidates.append(responsible)
        }
        var current = pid
        for _ in 0 ..< 5 {
            guard let parent = parentPID(of: current), parent > 1 else { break }
            candidates.append(parent)
            current = parent
        }

        // Helpers are `.prohibited` and never owners themselves; the app that
        // started them is the first candidate that is a real application.
        for candidate in candidates {
            guard let app = NSRunningApplication(processIdentifier: candidate),
                  app.activationPolicy != .prohibited,
                  let owner = owner(from: app),
                  owner.id != own
            else { continue }
            return owner
        }

        // Last resort: a helper's bundle id usually starts with its app's.
        if let bundleID {
            let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy != .prohibited }
            let match = apps
                .compactMap { app -> (NSRunningApplication, Int)? in
                    guard let id = app.bundleIdentifier,
                          bundleID == id || bundleID.hasPrefix(id + ".")
                    else { return nil }
                    return (app, id.count)
                }
                .max { $0.1 < $1.1 }?.0
            if let match, let owner = owner(from: match), owner.id != own { return owner }
            // WebKit's audio runs in system-owned helpers with no parent app.
            if bundleID.hasPrefix("com.apple.WebKit."),
               let safari = apps.first(where: { $0.bundleIdentifier == "com.apple.Safari" }),
               let owner = owner(from: safari) {
                return owner
            }
        }
        return nil
    }

    private static func owner(from app: NSRunningApplication) -> Owner? {
        let id = app.bundleIdentifier ?? "pid.\(app.processIdentifier)"
        let name = app.localizedName ?? id
        return Owner(id: id, name: name, icon: app.icon)
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }
}
