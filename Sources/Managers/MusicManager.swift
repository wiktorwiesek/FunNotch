//
//  MusicManager.swift
//  FunNotch
//
//  Owns the media backends, decides which of them the notch shows, publishes
//  the current track to the UI, and fires the "sneak peek" when the song
//  changes.
//
//  Backends do not exclude each other. With automatic source selection (the
//  default) every usable one runs at once and the notch follows whichever
//  *started playing* most recently: pressing play in a YouTube tab takes over
//  from a paused Kaset, pressing play in Kaset takes it back, and a source that
//  is merely open and paused never holds the display while another is playing.
//  The source picked in settings only breaks ties.
//

import AppKit
import Combine
import SwiftUI

/// The playhead the scrubber and lyrics follow.
///
/// Kept out of `MusicManager` on purpose: it changes five times a second
/// while music plays, and every view observing the manager — the root of the
/// notch among them — re-rendered with it, closed notch included. Only the
/// views that draw the position observe this.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var elapsed: TimeInterval = 0
}

@MainActor
final class MusicManager: ObservableObject {
    static let shared = MusicManager()

    @Published private(set) var track = TrackInfo() {
        didSet {
            if track.isPlaying != oldValue.isPlaying { updateTicking() }
        }
    }
    @Published private(set) var artwork: NSImage?
    /// Colours sampled from the artwork, used to tint the player.
    @Published private(set) var artworkColor: Color = .gray
    @Published private(set) var artworkSecondaryColor: Color = .gray
    /// Continuously updated playback position; observe `playback` to redraw with it.
    let playback = PlaybackClock()
    var displayedElapsed: TimeInterval {
        get { playback.elapsed }
        set { playback.elapsed = newValue }
    }
    /// True while the user is dragging the scrubber, so updates do not fight them.
    @Published var isScrubbing = false

    /// One running backend and the last thing it said.
    private final class Slot {
        let type: MediaControllerType
        let controller: MediaController
        var info = TrackInfo()
        /// When this backend last went from not playing to playing.
        var playingSince: Date?
        /// Set while the backend reports nothing but its last track is still held.
        var emptySince: Date?

        init(type: MediaControllerType, controller: MediaController) {
            self.type = type
            self.controller = controller
        }

        var isPlaying: Bool { info.isPlaying && !info.isEmpty }
    }

    private var slots: [MediaControllerType: Slot] = [:]
    private var displayed: MediaControllerType?
    private var tickTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var lastTrackKey = ""
    private var lastArtworkPointer: NSImage?

    /// A later start wins only by more than this, so two sources that began
    /// within a poll of each other do not trade places.
    private static let takeoverMargin: TimeInterval = 1.5

    private let settings = Settings.shared

    private init() {}

    /// True when MediaRemote is unusable on this OS, so the UI can explain why.
    var isNowPlayingDeprecated: Bool { NowPlayingController.isDeprecated }

    var isPlaying: Bool { track.isPlaying }

    /// Icon of the app the music is coming from, for the live activity.
    var sourceAppIcon: NSImage? {
        guard let identifier = track.bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    func start() {
        NotificationCenter.default.publisher(for: .mediaControllerChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.activateControllers() }
            .store(in: &cancellables)

        // Apps launching or quitting can change which backend is usable.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .merge(with: NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification))
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.activateControllers() }
            .store(in: &cancellables)

        // A player brought to the front is about to be clicked; read it now,
        // which also moves its polling to the fast rate (`AdaptivePoll`).
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .compactMap { ($0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier }
            .receive(on: RunLoop.main)
            .sink { [weak self] bundle in self?.refreshSource(ownedBy: bundle) }
            .store(in: &cancellables)

        // The automatic-source switch lives in UserDefaults; this fires for
        // every key, so only act when ours actually changed.
        var lastAuto = MediaExtrasDefaults.autoSource
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                let auto = MediaExtrasDefaults.autoSource
                guard auto != lastAuto else { return }
                lastAuto = auto
                self?.activateControllers()
            }
            .store(in: &cancellables)

        activateControllers()
        updateTicking()
    }

    /// The playhead only moves while something plays; a paused or empty
    /// player needs no timer at all.
    private func updateTicking() {
        guard track.isPlaying else {
            tickTimer?.invalidate()
            tickTimer = nil
            return
        }
        guard tickTimer == nil else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func tick() {
        guard !isScrubbing else { return }
        let elapsed = track.interpolatedElapsed
        // Assigning an unchanged value still notifies every observer.
        if abs(elapsed - displayedElapsed) > 0.05 {
            displayedElapsed = elapsed
        }
    }

    /// Re-reads the source that drives the app with this bundle identifier.
    private func refreshSource(ownedBy bundle: String) {
        for slot in slots.values where slot.type.appBundleIdentifier == bundle {
            slot.controller.refresh()
        }
    }

    // MARK: - Backend selection

    /// Which backends should be running right now.
    private func wantedTypes() -> [MediaControllerType] {
        let preferred = settings.mediaController

        guard MediaExtrasDefaults.autoSource else {
            // One backend, as chosen. If it cannot see anything (app not
            // running, MediaRemote locked down) fall through to one that can.
            if makeController(for: preferred).isAvailable { return [preferred] }
            for candidate in MediaControllerType.allCases where candidate != preferred {
                if makeController(for: candidate).isAvailable { return [candidate] }
            }
            return [preferred]
        }

        var types: [MediaControllerType] = []
        for type in [MediaControllerType.kaset, .appleMusic, .spotify]
        where ScriptedMediaController.isInstalled(type) {
            types.append(type)
        }
        // System-wide Now Playing sees every browser tab and any other player
        // with full metadata, so reading tabs one by one is only the fallback.
        if NowPlayingController.usesBridge || !NowPlayingController.isDeprecated {
            types.append(.nowPlaying)
        }
        if !NowPlayingController.usesBridge || preferred == .browser {
            types.append(.browser)
        }
        if !types.contains(preferred) { types.append(preferred) }
        return types
    }

    private func activateControllers() {
        let wanted = wantedTypes()

        for (type, slot) in slots where !wanted.contains(type) {
            slot.controller.stop()
            slots[type] = nil
        }
        for type in wanted where slots[type] == nil {
            let controller = makeController(for: type)
            let slot = Slot(type: type, controller: controller)
            slots[type] = slot
            controller.onUpdate = { [weak self] info in
                MainActor.assumeIsolated { self?.ingest(type, info) }
            }
            controller.start()
        }
        for slot in slots.values where wanted.contains(slot.type) {
            slot.controller.refresh()
        }

        let before = displayed
        reselect()
        if displayed != before { publishDisplayed() }
    }

    /// Replaces the real backends, so the choice between sources can be
    /// checked with scripted ones (see `MediaPreviewScenes`).
    var controllerFactory: ((MediaControllerType) -> MediaController)?

    private func makeController(for type: MediaControllerType) -> MediaController {
        if let controllerFactory { return controllerFactory(type) }
        switch type {
        case .nowPlaying:
            return NowPlayingController()
        case .appleMusic, .spotify:
            return ScriptedMediaController(type: type) ?? NowPlayingController()
        case .kaset:
            return KasetMediaController()
        case .browser:
            return BrowserMediaController()
        }
    }

    /// The backend the notch is showing, which can differ from the user's choice.
    var activeControllerType: MediaControllerType? {
        if let displayed, slots[displayed] != nil { return displayed }
        return slots[settings.mediaController] != nil ? settings.mediaController : slots.keys.first
    }

    private var displayedController: MediaController? {
        activeControllerType.flatMap { slots[$0]?.controller }
    }

    /// Forces an immediate re-read, used after a media key is pressed.
    func refreshNow() {
        slots.values.forEach { $0.controller.refresh() }
    }

    // MARK: - Choosing the displayed source

    /// A system-wide report about an app that has its own backend adds nothing
    /// but less detail (no likes, shuffle, seeking), so the app's own wins.
    private func isShadowed(_ slot: Slot) -> Bool {
        guard slot.type == .nowPlaying, let bundle = slot.info.bundleIdentifier else { return false }
        return slots.values.contains {
            $0.type != .nowPlaying && $0.type != .browser
                && !$0.info.isEmpty && $0.info.bundleIdentifier == bundle
        }
    }

    private func isEligible(_ slot: Slot) -> Bool {
        !slot.info.isEmpty && !isShadowed(slot)
    }

    /// How long a source that reports nothing keeps its last track on screen.
    /// YouTube clears its media session for a moment between videos and
    /// Shorts, and the system reports nothing in between; without this the
    /// notch dropped to whatever paused player was open, then jumped back.
    private static let emptyGrace: TimeInterval = 4

    /// Records what a backend reported and, if that changes who is showing,
    /// switches.
    private func ingest(_ type: MediaControllerType, _ incoming: TrackInfo) {
        guard let slot = slots[type] else { return }
        var info = incoming

        // The system feed reports a change the moment it happens; the app's
        // own source polls slowly (`AdaptivePoll`) and would otherwise hold
        // the display on its stale answer, since it shadows this one.
        if type == .nowPlaying, let bundle = incoming.bundleIdentifier,
           incoming.isPlaying != slot.info.isPlaying || incoming.title != slot.info.title {
            refreshSource(ownedBy: bundle)
        }

        if info.isEmpty, !slot.info.isEmpty {
            let now = Date()
            if let since = slot.emptySince {
                // Still empty after the grace period: it really stopped.
                if now.timeIntervalSince(since) < Self.emptyGrace { return }
            } else {
                // First empty report: hold the last track, but no longer
                // claim it is playing, and look again once the grace is up.
                slot.emptySince = now
                var held = slot.info
                held.elapsed = held.interpolatedElapsed
                held.timestamp = now
                held.isPlaying = false
                info = held
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.emptyGrace + 0.1) { [weak self, weak slot] in
                    guard let self, let slot, slot.emptySince != nil, self.slots[type] === slot else { return }
                    self.ingest(type, TrackInfo())
                }
            }
        } else {
            slot.emptySince = nil
        }

        let wasPlaying = slot.isPlaying
        let previousBundle = slot.info.bundleIdentifier
        slot.info = info
        if slot.isPlaying {
            // The system slot follows whichever app owns Now Playing; a
            // different owner that is already "playing" is a newer start.
            // (A missing id is a failed lookup, not a new owner.)
            let newOwner = previousBundle != nil && info.bundleIdentifier != nil && previousBundle != info.bundleIdentifier
            if !wasPlaying || newOwner { slot.playingSince = Date() }
        } else {
            slot.playingSince = nil
        }

        let before = displayed
        reselect()
        if displayed != before || displayed == type {
            publishDisplayed()
        }
    }

    private func reselect() {
        let preferred = settings.mediaController
        let candidates = slots.values.filter(isEligible)
        let playing = candidates.filter(\.isPlaying)
        let current = displayed.flatMap { slots[$0] }

        func started(_ slot: Slot) -> Date { slot.playingSince ?? .distantPast }

        /// Latest starter; sources that started together go to the preferred one.
        func newest(_ pool: [Slot]) -> Slot? {
            guard let latest = pool.map(started).max() else { return nil }
            let close = pool.filter { latest.timeIntervalSince(started($0)) <= Self.takeoverMargin }
            return close.first { $0.type == preferred } ?? close.max { started($0) < started($1) }
        }

        var choice: Slot?
        if let current, isEligible(current), current.isPlaying {
            // Staying is the default; only a source that began playing clearly
            // after this one takes over.
            let later = playing.filter {
                $0 !== current && started($0).timeIntervalSince(started(current)) > Self.takeoverMargin
            }
            choice = newest(later) ?? current
        } else if let best = newest(playing) {
            choice = best
        } else if let current, isEligible(current) {
            choice = current
        } else {
            // Nothing is playing and the display has nothing: show the
            // preferred source's paused track, else any other.
            choice = candidates.first { $0.type == preferred } ?? candidates.first
        }

        displayed = (choice ?? slots[preferred] ?? slots.values.first)?.type
    }

    /// Pushes the displayed backend's latest report to the UI.
    private func publishDisplayed() {
        guard let displayed, let slot = slots[displayed] else {
            handle(TrackInfo())
            return
        }
        // A backend that is shown only because nothing better exists may be
        // empty; that is how "nothing is playing" reaches the UI.
        handle(isEligible(slot) ? slot.info : TrackInfo())
    }

    /// Installs a fixed track without touching any backend, for snapshots.
    func injectPreviewTrack(_ info: TrackInfo) {
        track = info
        displayedElapsed = info.elapsed
        artwork = info.artwork
        updateColors(from: info.artwork)
    }

    /// Moves an injected track's playhead and play state without re-reading
    /// its artwork, for the film renderer's frame-by-frame playback.
    func injectPreviewPlayback(elapsed: TimeInterval, isPlaying: Bool) {
        track.elapsed = elapsed
        track.isPlaying = isPlaying
        displayedElapsed = elapsed
    }

    /// Clears the injected track so a snapshot can show the idle home screen,
    /// which is where the weather lives.
    func clearPreviewTrack() {
        track = TrackInfo()
        displayedElapsed = 0
        artwork = nil
        updateColors(from: nil)
    }

    // MARK: - Incoming updates

    private func handle(_ incoming: TrackInfo) {
        var info = incoming
        info.artist = TrackInfo.tidyArtist(info.artist)

        let key = "\(info.title)|\(info.artist)|\(info.album)"
        let isNewTrack = !info.title.isEmpty && key != lastTrackKey

        // Backends report every few seconds or on change; most reports change
        // nothing the UI shows, and each assignment redraws the notch. The
        // position counts as a change only if it drifted off the projection.
        if info != track || abs(info.interpolatedElapsed - track.interpolatedElapsed) > 0.6 {
            track = info
        }
        if !isScrubbing {
            let elapsed = info.interpolatedElapsed
            if abs(elapsed - displayedElapsed) > 0.05 { displayedElapsed = elapsed }
        }

        if info.artwork !== lastArtworkPointer {
            lastArtworkPointer = info.artwork
            artwork = info.artwork
            updateColors(from: info.artwork)
        }

        if isNewTrack {
            lastTrackKey = key
            announceTrackChange()
        } else if info.isEmpty {
            lastTrackKey = ""
        }
    }

    /// A browser feed of Shorts, or a page that fills in its title and then
    /// its artist a moment later, changes the track many times in a few
    /// seconds. One peek per burst is enough.
    private static let minimumPeekGap: TimeInterval = 6
    private var lastPeekAt = Date.distantPast

    private func announceTrackChange() {
        guard settings.enableSneakPeek, track.isPlaying,
              Date().timeIntervalSince(lastPeekAt) >= Self.minimumPeekGap
        else { return }
        lastPeekAt = Date()
        NotchWindowManager.shared.broadcast { viewModel in
            guard viewModel.notchState == .closed else { return }
            viewModel.showSneakPeek(type: .music)
        }
    }

    private func updateColors(from image: NSImage?) {
        guard let image else {
            artworkColor = .gray
            artworkSecondaryColor = .gray
            return
        }
        let colors = image.dominantColors()
        artworkColor = Color(nsColor: colors.primary)
        artworkSecondaryColor = Color(nsColor: colors.secondary)
    }

    // MARK: - Transport

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.displayedController?.refresh()
        }
    }

    func togglePlayPause() {
        displayedController?.togglePlayPause()
        // Optimistically flip so the button feels instant.
        track.isPlaying.toggle()
        track.timestamp = Date()
        track.elapsed = displayedElapsed
        refreshSoon()
    }

    func nextTrack() {
        displayedController?.nextTrack()
        refreshSoon()
    }

    func previousTrack() {
        displayedController?.previousTrack()
        refreshSoon()
    }

    func seek(to time: TimeInterval) {
        displayedController?.seek(to: time)
        displayedElapsed = time
    }

    func toggleShuffle() {
        displayedController?.toggleShuffle()
        track.isShuffled.toggle()
        refreshSoon()
    }

    func cycleRepeat() {
        displayedController?.cycleRepeat()
        refreshSoon()
    }

    func toggleLike() {
        displayedController?.toggleLike()
        track.likeStatus = track.likeStatus == .liked ? LikeStatus.none : .liked
        refreshSoon()
    }

    func toggleDislike() {
        displayedController?.toggleDislike()
        track.likeStatus = track.likeStatus == .disliked ? LikeStatus.none : .disliked
        refreshSoon()
    }

    /// Brings the playing app to the front, like clicking the artwork does.
    func openPlayingApp() {
        guard let identifier = track.bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
        else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
