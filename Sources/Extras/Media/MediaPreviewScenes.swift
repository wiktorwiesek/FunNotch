//
//  MediaPreviewScenes.swift
//  FunNotch
//
//  Preview scenes for the player: the open home tile with synced lyrics at the
//  layouts people actually use, so a change to the player can be checked by
//  eye. Rendered by `FunNotch --render-preview`.
//

import AppKit
import Combine
import SwiftUI

extension PreviewRenderer {
    /// The user's own value, read before any scene changes it.
    private static let savedClosedLyrics: Any? =
        UserDefaults.standard.object(forKey: MediaExtrasDefaults.lyricsInClosedNotchKey)

    private static func mediaArtwork() -> NSImage {
        let size = CGSize(width: 300, height: 300)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(colors: [
            NSColor(srgbRed: 0.10, green: 0.45, blue: 0.62, alpha: 1),
            NSColor(srgbRed: 0.85, green: 0.30, blue: 0.40, alpha: 1),
        ])?.draw(in: CGRect(origin: .zero, size: size), angle: 35)
        NSColor.white.withAlphaComponent(0.8).setFill()
        NSBezierPath(ovalIn: CGRect(x: 100, y: 100, width: 100, height: 100)).fill()
        image.unlockFocus()
        return image
    }

    private static func mediaTrack(
        title: String = "Tamagotchi",
        artist: String = "Taco Hemingway",
        duration: TimeInterval = 201,
        elapsed: TimeInterval = 84,
        liked: Bool = true
    ) -> TrackInfo {
        var track = TrackInfo()
        track.title = title
        track.artist = artist
        track.album = "Jarmark"
        track.duration = duration
        track.elapsed = elapsed
        track.isPlaying = false // frozen: the snapshot must not drift
        track.isShuffled = true
        track.repeatMode = .all
        track.likeStatus = liked ? .liked : LikeStatus.none
        track.bundleIdentifier = "com.sertacozercan.Kaset"
        track.artwork = mediaArtwork()
        return track
    }

    private static let mediaLyrics: [LyricLine] = [
        LyricLine(time: 10, text: "Wstaję rano, kawa, ciągle ten sam dzień"),
        LyricLine(time: 20, text: "Znowu patrzę w ekran, a on patrzy we mnie"),
        LyricLine(time: 30, text: "Mój tamagotchi umarł, nikt nie wie, jak to jest"),
        LyricLine(time: 40, text: "Dzwoni telefon, nie odbieram, bo nie chcę"),
        LyricLine(time: 50, text: "Wszystko, co mam, mieści się w jednej kieszeni"),
    ]

    /// The tile layout of the user who reported the clipped player: Now
    /// playing (6), Calendar (3), Agent sessions (4); Quick actions, System
    /// stats, Battery below.
    private static var reportedLayout: [HomeTile] {
        [
            HomeTile(kind: .nowPlaying, row: 0, span: 6),
            HomeTile(kind: .calendar, row: 0, span: 3),
            HomeTile(kind: .agents, row: 0, span: 4),
            HomeTile(kind: .quickActions, row: 1, span: 2),
            HomeTile(kind: .systemStats, row: 1, span: 2),
            HomeTile(kind: .battery, row: 1, span: 2),
        ]
    }

    /// Dev aid: `FUNNOTCH_PREVIEW_ONLY=qm-probe FUNNOTCH_MEDIA_PROBE=60` starts the
    /// real media backends for that many seconds and prints what the notch
    /// would show — which source, which track, playing or not — each time it
    /// changes. Nothing is drawn; no notch window is created.
    static func appendMediaProbe(to scenes: inout [QAScene]) {
        guard let seconds = ProcessInfo.processInfo.environment["FUNNOTCH_MEDIA_PROBE"].flatMap(Double.init) else { return }
        scenes.append(("qm-probe", { _ in
            let started = Date()
            func say(_ text: String) {
                let stamp = String(format: "%7.2f", Date().timeIntervalSince(started))
                print("[\(stamp)] \(text)")
                fflush(stdout)
            }
            // FUNNOTCH_MEDIA_PROBE_BACKEND=browser|kaset|nowplaying runs one backend alone.
            if let backend = ProcessInfo.processInfo.environment["FUNNOTCH_MEDIA_PROBE_BACKEND"] {
                let controller: MediaController
                switch backend {
                case "browser": controller = BrowserMediaController()
                case "kaset": controller = KasetMediaController()
                default: controller = NowPlayingController()
                }
                controller.onUpdate = { t in
                    say("\(backend): playing=\(t.isPlaying) \"\(t.title)\" — \"\(t.artist)\" dur=\(Int(t.duration)) "
                        + "elapsed=\(String(format: "%.1f", t.interpolatedElapsed)) bundle=\(t.bundleIdentifier ?? "-") art=\(t.artwork == nil ? "no" : "yes")")
                }
                controller.start()
                RunLoop.current.run(until: Date().addingTimeInterval(seconds))
                controller.stop()
                say("done")
                return
            }
            let music = MusicManager.shared
            var bag = Set<AnyCancellable>()
            music.$track
                .removeDuplicates { $0 == $1 }
                .sink { _ in
                    // Published fires before the value is stored; read it a turn later.
                    DispatchQueue.main.async {
                        let t = music.track
                        say("source=\(music.activeControllerType?.rawValue ?? "-") playing=\(t.isPlaying) "
                            + "\"\(t.title)\" — \"\(t.artist)\" [\(t.album)] dur=\(Int(t.duration)) "
                            + "elapsed=\(String(format: "%.1f", t.interpolatedElapsed)) bundle=\(t.bundleIdentifier ?? "-") "
                            + "art=\(t.artwork == nil ? "no" : "yes") like=\(String(describing: t.likeStatus))")
                    }
                }
                .store(in: &bag)
            music.start()
            LyricsManager.shared.start()
            LyricsManager.shared.$state
                .removeDuplicates()
                .sink { state in say("lyrics state=\(state)") }
                .store(in: &bag)
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
            say("done")
        }))
    }

    /// Dev aid: `FUNNOTCH_PREVIEW_ONLY=qm-lyricscheck FUNNOTCH_LYRICS_CHECK='title|artist|album|seconds'`
    /// runs the real LRCLIB lookup for one track and prints what it found.
    static func appendLyricsCheck(to scenes: inout [QAScene]) {
        guard let spec = ProcessInfo.processInfo.environment["FUNNOTCH_LYRICS_CHECK"] else { return }
        scenes.append(("qm-lyricscheck", { _ in
            let parts = spec.components(separatedBy: "|")
            guard parts.count == 4, let seconds = Double(parts[3]) else {
                print("usage: title|artist|album|seconds")
                return
            }
            var outcome: LRCLibClient.Outcome?
            Task { outcome = await LRCLibClient.fetch(title: parts[0], artist: parts[1], album: parts[2], duration: seconds) }
            let deadline = Date().addingTimeInterval(30)
            while outcome == nil, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            switch outcome {
            case let .found(document):
                print("found: synced=\(document.hasSynced) lines=\(document.lines.count) plain=\(document.plain?.prefix(40) ?? "-") instrumental=\(document.instrumental)")
                if let first = document.lines.first { print("first line: \(first.time)s \(first.text)") }
            case .notFound: print("not found")
            case .failed: print("failed")
            case nil: print("timeout")
            }
        }))
    }

    /// A backend that says whatever the check tells it to.
    private final class ScriptedSource: MediaController {
        let type: MediaControllerType
        var onUpdate: ((TrackInfo) -> Void)?
        var isAvailable: Bool { true }
        init(_ type: MediaControllerType) { self.type = type }
        func start() {}
        func stop() {}
        func refresh() {}
        func togglePlayPause() {}
        func nextTrack() {}
        func previousTrack() {}
        func seek(to time: TimeInterval) {}
        func say(_ info: TrackInfo) { onUpdate?(info) }
    }

    /// Dev aid: `FUNNOTCH_PREVIEW_ONLY=qm-arbitrate FUNNOTCH_MEDIA_ARBITRATE=1` drives
    /// `MusicManager` with scripted sources through the situations that went
    /// wrong (paused player holding the display, flapping on a media-session
    /// gap, two sources at once) and prints PASS/FAIL for each. Run it from a
    /// copy with its own bundle id: it sets the preferred source.
    static func appendMediaArbitrationCheck(to scenes: inout [QAScene]) {
        guard ProcessInfo.processInfo.environment["FUNNOTCH_MEDIA_ARBITRATE"] != nil else { return }
        scenes.append(("qm-arbitrate", { _ in
            var sources: [MediaControllerType: ScriptedSource] = [:]
            let music = MusicManager.shared
            Settings.shared.mediaController = .kaset
            music.controllerFactory = { type in
                let source = ScriptedSource(type)
                sources[type] = source
                return source
            }
            music.start()

            func track(_ title: String, playing: Bool, bundle: String, artist: String = "A") -> TrackInfo {
                var info = TrackInfo()
                info.title = title
                info.artist = artist
                info.duration = 200
                info.elapsed = 10
                info.isPlaying = playing
                info.bundleIdentifier = bundle
                return info
            }
            let kasetID = "com.sertacozercan.Kaset"
            let heliumID = "net.imput.helium"
            func wait(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
            @MainActor func expect(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
                print("\(condition ? "PASS" : "FAIL")  \(name)  \(condition ? "" : detail())")
                fflush(stdout)
            }
            @MainActor func shown() -> String {
                "\(music.activeControllerType?.rawValue ?? "-") / \(music.track.title) / playing=\(music.isPlaying)"
            }

            wait(0.3)
            guard let kaset = sources[.kaset], let system = sources[.nowPlaying] else {
                expect("backends created", false, "sources=\(sources.keys.map(\.rawValue))")
                return
            }

            kaset.say(track("Kaset song", playing: false, bundle: kasetID))
            wait(0.1)
            expect("a paused source is shown when nothing plays", music.track.title == "Kaset song", shown())

            system.say(track("Helium video", playing: true, bundle: heliumID))
            wait(0.1)
            expect("a source that starts playing takes over from a paused one",
                   music.track.title == "Helium video" && music.isPlaying, shown())

            wait(1.7)
            kaset.say(track("Kaset song", playing: true, bundle: kasetID))
            wait(0.1)
            expect("the source that started last wins while both play",
                   music.track.title == "Kaset song", shown())

            kaset.say(track("Kaset song", playing: false, bundle: kasetID))
            wait(0.1)
            expect("pausing it hands the display to the one still playing",
                   music.track.title == "Helium video", shown())

            // A media-session gap: the system reports nothing for two seconds.
            system.say(TrackInfo())
            wait(2)
            expect("a short gap does not drop to the paused source", music.track.title == "Helium video", shown())
            expect("a held track is not claimed to be playing", !music.isPlaying, shown())
            system.say(track("Helium video 2", playing: true, bundle: heliumID))
            wait(0.1)
            expect("the next video appears after the gap", music.track.title == "Helium video 2" && music.isPlaying, shown())

            // A real stop.
            system.say(TrackInfo())
            wait(4.5)
            expect("after the grace period the empty source gives way",
                   music.track.title == "Kaset song", shown())

            // The system also reports Kaset's own track: Kaset's backend wins.
            kaset.say(track("Kaset song", playing: true, bundle: kasetID))
            wait(0.1)
            system.say(track("Kaset song", playing: true, bundle: kasetID))
            wait(1.7)
            kaset.say(track("Kaset song", playing: true, bundle: kasetID))
            wait(0.1)
            expect("the system copy of an app's track is ignored", music.activeControllerType == .kaset, shown())

            // Kaset's backend failing falls back to the system copy.
            kaset.say(TrackInfo())
            wait(4.5)
            expect("with Kaset empty the system report is shown", music.activeControllerType == .nowPlaying, shown())

            print("arbitration check done")
            fflush(stdout)
        }))
    }

    static func appendMediaScenes(to scenes: inout [QAScene]) {
        appendMediaProbe(to: &scenes)
        appendMediaArbitrationCheck(to: &scenes)
        appendLyricsCheck(to: &scenes)

        func open(
            _ viewModel: NotchViewModel,
            tiles: [HomeTile]? = nil,
            track: TrackInfo,
            lyrics: Bool,
            line: Int? = 2
        ) {
            HomeLayout.filmTiles = tiles ?? reportedLayout
            MusicManager.shared.injectPreviewTrack(track)
            if lyrics {
                LyricsManager.shared.injectPreview(lines: mediaLyrics, currentIndex: line)
            } else {
                LyricsManager.shared.clearPreview()
            }
            viewModel.refreshPreviewMusicActivity()
            viewModel.previewOpen()
            viewModel.currentTab = .home
        }

        scenes.append(("qm-player-nolyrics", { viewModel in
            open(viewModel, track: mediaTrack(), lyrics: false)
        }))
        scenes.append(("qm-player-lyrics", { viewModel in
            open(viewModel, track: mediaTrack(), lyrics: true)
        }))
        scenes.append(("qm-player-lyrics-long", { viewModel in
            open(viewModel, track: mediaTrack(
                title: "Żółć w żółtym żwirze — wersja rozszerzona (feat. Zażółć Gęślą Jaźń)",
                artist: "Taco Hemingway, Żabson, Young Igi i Quebonafide"
            ), lyrics: true)
        }))
        scenes.append(("qm-player-lyrics-notiming", { viewModel in
            open(viewModel, track: mediaTrack(duration: 0, elapsed: 0, liked: false), lyrics: true)
        }))
        scenes.append(("qm-player-lyrics-wide", { viewModel in
            open(viewModel, tiles: [
                HomeTile(kind: .nowPlaying, row: 0, span: 8),
                HomeTile(kind: .calendar, row: 0, span: 3),
                HomeTile(kind: .battery, row: 1, span: 2),
            ], track: mediaTrack(), lyrics: true)
        }))
        scenes.append(("qm-player-lyrics-narrow", { viewModel in
            open(viewModel, tiles: [
                HomeTile(kind: .nowPlaying, row: 0, span: 4),
                HomeTile(kind: .calendar, row: 0, span: 4),
                HomeTile(kind: .agents, row: 0, span: 4),
            ], track: mediaTrack(), lyrics: true)
        }))
        scenes.append(("qm-player-lyrics-onerow", { viewModel in
            open(viewModel, tiles: [
                HomeTile(kind: .nowPlaying, row: 0, span: 6),
                HomeTile(kind: .calendar, row: 0, span: 3),
            ], track: mediaTrack(), lyrics: true)
        }))
        scenes.append(("qm-player-lyrics-plain", { viewModel in
            open(viewModel, track: mediaTrack(), lyrics: false)
            LyricsManager.shared.injectPreviewPlain("Wstaję rano, kawa\nciągle ten sam dzień")
        }))

        // The track-change peek: lyric line in the chin, and the plain title
        // when the lyrics are off or there is no line yet.
        scenes.append(("qm-closed-lyric", { viewModel in
            _ = savedClosedLyrics
            UserDefaults.standard.set(true, forKey: MediaExtrasDefaults.lyricsInClosedNotchKey)
            MusicManager.shared.injectPreviewTrack(mediaTrack(elapsed: 33))
            LyricsManager.shared.injectPreview(lines: mediaLyrics, currentIndex: 2)
            viewModel.refreshPreviewMusicActivity()
            viewModel.sneakPeek = SneakPeek(show: true, type: .music)
        }))
        scenes.append(("qm-closed-lyric-long", { viewModel in
            MusicManager.shared.injectPreviewTrack(mediaTrack(elapsed: 33))
            LyricsManager.shared.injectPreview(lines: [
                LyricLine(time: 0, text: "Zażółć gęślą jaźń, a potem jeszcze raz od początku, bo jeden raz to za mało"),
                LyricLine(time: 30, text: "Druga linia"),
            ], currentIndex: 0)
            viewModel.refreshPreviewMusicActivity()
            viewModel.sneakPeek = SneakPeek(show: true, type: .music)
        }))
        scenes.append(("qm-closed-peek-title", { viewModel in
            UserDefaults.standard.set(false, forKey: MediaExtrasDefaults.lyricsInClosedNotchKey)
            MusicManager.shared.injectPreviewTrack(mediaTrack(title: "Żółć w żółtym żwirze", artist: "Taco Hemingway, Żabson"))
            LyricsManager.shared.clearPreview()
            viewModel.refreshPreviewMusicActivity()
            viewModel.sneakPeek = SneakPeek(show: true, type: .music)
        }))

        // Leave the shared layout override as the other scenes expect it.
        scenes.append(("qm-zz-reset", { viewModel in
            HomeLayout.filmTiles = nil
            if let saved = savedClosedLyrics {
                UserDefaults.standard.set(saved, forKey: MediaExtrasDefaults.lyricsInClosedNotchKey)
            } else {
                UserDefaults.standard.removeObject(forKey: MediaExtrasDefaults.lyricsInClosedNotchKey)
            }
            LyricsManager.shared.clearPreview()
            MusicManager.shared.clearPreviewTrack()
            viewModel.refreshPreviewMusicActivity()
        }))
    }
}
