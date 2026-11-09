//
//  KasetMediaController.swift
//  FunNotch
//
//  Kaset, the native YouTube Music player, answers one AppleScript command —
//  `get player info` — with its whole state as JSON. It posts no distributed
//  notification when that changes, so this polls once a second like the
//  scrubber needs anyway. Kaset has no seek command; the scrubber shows the
//  position but dragging it does not move playback.
//

import AppKit
import Foundation

final class KasetMediaController: MediaController {
    static let bundleIdentifier = "com.sertacozercan.Kaset"

    let type: MediaControllerType = .kaset
    var onUpdate: ((TrackInfo) -> Void)?

    private var timer: Timer?
    private var current = TrackInfo()
    private var artworkKey = ""

    var isAvailable: Bool {
        AppleScriptRunner.isRunning(Self.bundleIdentifier)
    }

    func start() {
        stop()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard isAvailable else {
            if !current.isEmpty || current.isPlaying {
                current = TrackInfo()
                onUpdate?(current)
            }
            return
        }
        AppleScriptRunner.shared.runForString("tell application \"Kaset\" to get player info") { [weak self] json in
            guard let self, let data = json?.data(using: .utf8),
                  let state = try? JSONDecoder().decode(PlayerInfo.self, from: data)
            else { return }
            self.apply(state)
        }
    }

    private struct PlayerInfo: Decodable {
        struct Track: Decodable {
            let name: String
            let artist: String
            let album: String
            let duration: Double
            let videoId: String
            let artworkURL: String
        }

        let isPlaying: Bool
        let position: Double
        let duration: Double
        let shuffling: Bool
        let repeating: String
        let likeStatus: String
        let currentTrack: Track?
    }

    private func apply(_ state: PlayerInfo) {
        var info = TrackInfo()
        if let track = state.currentTrack {
            info.title = track.name
            info.artist = track.artist
            info.album = track.album
        }
        info.duration = state.duration > 0 ? state.duration : state.currentTrack?.duration ?? 0
        info.elapsed = state.position
        info.isPlaying = state.isPlaying
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

        let key = state.currentTrack?.videoId ?? ""
        if key != artworkKey {
            artworkKey = key
            info.artwork = nil
            if let artworkURL = state.currentTrack?.artworkURL {
                downloadArtwork(from: artworkURL, key: key)
            }
        }

        current = info
        onUpdate?(info)
    }

    /// YouTube Music hands out a 60 or 120 px square; the same image is served
    /// at any size by changing the size token.
    private func downloadArtwork(from urlString: String, key: String) {
        let sized = urlString
            .replacingOccurrences(of: "w60-h60", with: "w544-h544")
            .replacingOccurrences(of: "w120-h120", with: "w544-h544")
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
