//
//  KasetMediaController.swift
//  FunNotch
//
//  Kaset, the native YouTube Music player, answers one AppleScript command —
//  `get player info` — with its whole state as JSON. It posts no distributed
//  notification when that changes, so this polls, at a rate set by
//  `AdaptivePoll`. Kaset has no seek command; the scrubber shows the
//  position but dragging it does not move playback.
//

import AppKit
import Foundation

final class KasetMediaController: MediaController {
    static let bundleIdentifier = "com.sertacozercan.Kaset"

    let type: MediaControllerType = .kaset
    var onUpdate: ((TrackInfo) -> Void)?

    private let poll = AdaptivePoll()
    private var current = TrackInfo()
    private var artworkKey = ""
    /// Consecutive polls that returned nothing usable.
    private var failures = 0

    var isAvailable: Bool {
        AppleScriptRunner.isRunning(Self.bundleIdentifier)
    }

    func start() {
        stop()
        refresh()
    }

    func stop() {
        poll.cancel()
    }

    private func scheduleNextPoll() {
        let interval = AdaptivePoll.interval(bundleIdentifier: Self.bundleIdentifier, isPlaying: current.isPlaying)
        poll.schedule(after: interval) { [weak self] in self?.refresh() }
    }

    func refresh() {
        guard isAvailable else {
            failures = 0
            poll.cancel()
            if !current.isEmpty || current.isPlaying {
                current = TrackInfo()
                onUpdate?(current)
            }
            return
        }
        // Armed before the read so a script that never answers cannot end
        // the polling; re-armed below once the answer says what is playing.
        scheduleNextPoll()
        // `is running` first: a bare `tell` would relaunch a Kaset that quit
        // between the check above and the script running.
        let script = "if application \"Kaset\" is running then\ntell application \"Kaset\"\nreturn get player info\nend tell\nend if\nreturn \"\""
        AppleScriptRunner.shared.runForString(script) { [weak self] json in
            guard let self else { return }
            guard let json, let state = PlayerInfo(json: json) else {
                self.noteFailure(json == nil ? "no answer" : "unreadable player info")
                return
            }
            self.failures = 0
            let wasPlaying = self.current.isPlaying
            self.apply(state)
            if self.current.isPlaying != wasPlaying { self.scheduleNextPoll() }
        }
    }

    /// A single missed answer is normal (the app is busy loading a track); a
    /// run of them means whatever is on screen is stale, so clear it rather
    /// than keep announcing a song that stopped long ago.
    private func noteFailure(_ reason: String) {
        failures += 1
        if failures == 3 { DiagnosticLog.write("media", "Kaset: \(reason)") }
        if failures >= 3, !current.isEmpty || current.isPlaying {
            current = TrackInfo()
            onUpdate?(current)
        }
    }

    /// Kaset's JSON is read field by field. `currentTrack.duration` is `null`
    /// for every YouTube Music track, and a strict `Decodable` rejected the
    /// whole document over it — so after Kaset's update the notch never
    /// changed track again.
    private struct PlayerInfo {
        struct Track {
            var name = ""
            var artist = ""
            var album = ""
            var duration: Double?
            var videoId = ""
            var artworkURL = ""
        }

        var isPlaying = false
        var position = 0.0
        var duration = 0.0
        var shuffling = false
        var repeating = "off"
        var likeStatus = "none"
        var currentTrack: Track?

        init?(json: String) {
            guard let data = json.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }

            func number(_ value: Any?) -> Double? {
                if let number = value as? NSNumber { return number.doubleValue }
                if let text = value as? String { return Double(text) }
                return nil
            }

            isPlaying = (root["isPlaying"] as? Bool) ?? !((root["isPaused"] as? Bool) ?? true)
            position = max(number(root["position"]) ?? 0, 0)
            duration = max(number(root["duration"]) ?? 0, 0)
            shuffling = root["shuffling"] as? Bool ?? false
            repeating = root["repeating"] as? String ?? "off"
            likeStatus = root["likeStatus"] as? String ?? "none"

            if let raw = root["currentTrack"] as? [String: Any] {
                var track = Track()
                track.name = raw["name"] as? String ?? ""
                track.artist = raw["artist"] as? String ?? ""
                track.album = raw["album"] as? String ?? ""
                track.duration = number(raw["duration"])
                track.videoId = raw["videoId"] as? String ?? ""
                track.artworkURL = raw["artworkURL"] as? String ?? ""
                currentTrack = track
            }
        }
    }

    private func apply(_ state: PlayerInfo) {
        var info = TrackInfo()
        if let track = state.currentTrack {
            info.title = track.name
            info.artist = TrackInfo.tidyArtist(track.artist)
            info.album = track.album
        }
        let trackLength = state.currentTrack?.duration ?? 0
        info.duration = state.duration > 0 ? state.duration : max(trackLength, 0)
        info.elapsed = state.position
        // With no track loaded there is nothing playing, whatever the flag says.
        info.isPlaying = state.isPlaying && !info.isEmpty
        info.isShuffled = state.shuffling
        switch state.repeating {
        case "one": info.repeatMode = .one
        case "all": info.repeatMode = .all
        default: info.repeatMode = .off
        }
        switch state.likeStatus {
        case "liked": info.likeStatus = .liked
        case "disliked": info.likeStatus = .disliked
        default: info.likeStatus = LikeStatus.none
        }
        info.bundleIdentifier = Self.bundleIdentifier
        info.timestamp = Date()
        info.artwork = current.artwork

        // The video id changes with every track, including a repeat of the
        // same title. Without one, name and artist stand in for it.
        let key: String
        if let track = state.currentTrack {
            key = track.videoId.isEmpty ? "\(track.name)|\(track.artist)" : track.videoId
        } else {
            key = ""
        }
        if key != artworkKey {
            artworkKey = key
            info.artwork = nil
            if let artworkURL = state.currentTrack?.artworkURL, !artworkURL.isEmpty {
                downloadArtwork(from: artworkURL, key: key)
            }
        }

        current = info
        onUpdate?(info)
    }

    /// YouTube Music hands out a 60 or 120 px square; the same image is served
    /// at any size by changing the size token (`=w60-h60-l90-rj`).
    private func downloadArtwork(from urlString: String, key: String) {
        let sized = urlString.replacingOccurrences(
            of: #"w\d+-h\d+"#, with: "w544-h544", options: .regularExpression
        )
        guard let url = URL(string: sized) else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                guard key == self.artworkKey else { return }
                self.current.artwork = image
                self.onUpdate?(self.current)
            }
        }.resume()
    }

    // MARK: - Transport

    private func tell(_ command: String) {
        AppleScriptRunner.shared.execute("tell application \"Kaset\" to \(command)")
    }

    func play() { tell("play") }
    func pause() { tell("pause") }
    func togglePlayPause() { tell("playpause") }
    func nextTrack() { tell("next track") }
    func previousTrack() { tell("previous track") }
    func seek(to time: TimeInterval) {}
    func toggleShuffle() { tell("toggle shuffle") }
    func cycleRepeat() { tell("cycle repeat") }
    func toggleLike() { tell("like track") }
    func toggleDislike() { tell("dislike track") }
}
