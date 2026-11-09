//
//  MediaController.swift
//  FunNotch
//
//  A backend that can report and drive "what is playing right now".
//

import AppKit
import Foundation

/// Everything the UI needs to know about the current track.
struct TrackInfo: Equatable {
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var artwork: NSImage?
    var duration: TimeInterval = 0
    var elapsed: TimeInterval = 0
    var isPlaying: Bool = false
    var isShuffled: Bool = false
    var repeatMode: RepeatMode = .off
    /// nil when the source has no likes to offer.
    var likeStatus: LikeStatus?
    var bundleIdentifier: String?
    /// When `elapsed` was last measured, so playback can be interpolated.
    var timestamp: Date = .init()

    var isEmpty: Bool {
        title.isEmpty && artist.isEmpty
    }

    /// True when the backend actually told us how long the track is. Without
    /// it there is no honest scrubber to draw.
    var hasTiming: Bool { duration > 0 }

    /// Elapsed time projected forward to now while playing. With no known
    /// duration this stays put rather than counting up from nowhere — a
    /// browser tab read from its title has no position to report.
    var interpolatedElapsed: TimeInterval {
        guard isPlaying, hasTiming else { return elapsed }
        return min(elapsed + Date().timeIntervalSince(timestamp), duration)
    }

    static func == (lhs: TrackInfo, rhs: TrackInfo) -> Bool {
        lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.album == rhs.album
            && lhs.isPlaying == rhs.isPlaying
            && lhs.duration == rhs.duration
            && lhs.isShuffled == rhs.isShuffled
            && lhs.repeatMode == rhs.repeatMode
            && lhs.likeStatus == rhs.likeStatus
            && lhs.bundleIdentifier == rhs.bundleIdentifier
            && lhs.artwork === rhs.artwork
    }
}

extension TrackInfo {
    /// Lowercase only, so "I Monster" or "And One" are left alone.
    private static let joiners: Set<String> = ["oraz", "i", "and", "&", "und"]

    /// Players build the artist line by joining a list of names, and some
    /// feed it an empty name — the line read "Taco Hemingway oraz , Taco
    /// Hemingway". Drops empty entries and the joiner left dangling beside
    /// them, and leaves a well-formed "A i B" alone.
    static func tidyArtist(_ raw: String) -> String {
        let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var parts: [String] = []
        for piece in collapsed.split(separator: ",", omittingEmptySubsequences: false) {
            var words = piece.split(separator: " ").map(String.init)
            while let first = words.first, joiners.contains(first) { words.removeFirst() }
            while let last = words.last, joiners.contains(last) { words.removeLast() }
            if !words.isEmpty { parts.append(words.joined(separator: " ")) }
        }
        return parts.isEmpty ? collapsed : parts.joined(separator: ", ")
    }
}

/// A thumbs up or down on the current track, as YouTube Music has it.
enum LikeStatus: Equatable {
    case none
    case liked
    case disliked
}

protocol MediaController: AnyObject {
    var type: MediaControllerType { get }
    /// Called whenever the backend has fresh information.
    var onUpdate: ((TrackInfo) -> Void)? { get set }
    /// True when this backend can currently provide anything at all.
    var isAvailable: Bool { get }

    func start()
    func stop()
    /// Forces a refresh outside the normal cadence.
    func refresh()

    func play()
    func pause()
    func togglePlayPause()
    func nextTrack()
    func previousTrack()
    func seek(to time: TimeInterval)
    func toggleShuffle()
    func cycleRepeat()
    /// Thumbs up again clears it, the way the player's own button does.
    func toggleLike()
    func toggleDislike()
}

extension MediaController {
    func play() {}
    func pause() {}
    func toggleShuffle() {}
    func cycleRepeat() {}
    func toggleLike() {}
    func toggleDislike() {}
}

/// The read schedule of a player driven over Apple Events.
///
/// Every read is a round trip into the player's process, and every source
/// runs at once, so a fixed one-second poll per player kept the CPU awake all
/// day for apps that sat paused or were not even open. The next read is
/// re-armed after each one, at a rate that follows what can still change.
/// Position needs no polling at all: `TrackInfo.interpolatedElapsed`
/// projects it from the last read.
final class AdaptivePoll {
    private var timer: Timer?

    /// Seconds until the next read, or nil for none. A player that is not
    /// running is not polled: `MusicManager` refreshes every source when an
    /// app launches, which re-arms this.
    static func interval(bundleIdentifier: String, isPlaying: Bool) -> TimeInterval? {
        guard AppleScriptRunner.isRunning(bundleIdentifier) else { return nil }
        // Nobody is looking; the first read after unlocking catches up.
        if SystemActivityMonitor.isScreenIdle { return 30 }
        // In front, the user is likely clicking its own controls.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier { return 1 }
        // Playing: notice the next track soon after it starts. The system
        // Now Playing feed also nudges a read on every change it sees.
        if isPlaying { return 2 }
        return 5
    }

    func schedule(after interval: TimeInterval?, _ action: @escaping () -> Void) {
        timer?.invalidate()
        timer = nil
        guard let interval else { return }
        let timer = Timer(timeInterval: interval, repeats: false) { _ in action() }
        // Lets macOS fold this wake-up into others.
        timer.tolerance = interval * 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}
