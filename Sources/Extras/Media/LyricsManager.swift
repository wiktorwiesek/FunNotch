//
//  LyricsManager.swift
//  FunNotch
//
//  Synced lyrics for whatever MusicManager is playing, from LRCLIB. The track
//  is looked up by artist, title, album and length, parsed from LRC, cached on
//  disk, and followed against the player's position so the UI only has to ask
//  for "the current line".
//
//  It reads the track from MusicManager, never from a backend, so it works for
//  every source — Kaset, Music, Spotify, a browser tab.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Model

struct LyricLine: Equatable, Codable {
    let time: TimeInterval
    let text: String
}

/// What the lookup found for one track. This is also the cache file's content.
struct LyricsDocument: Codable {
    var lines: [LyricLine] = []
    var plain: String?
    var instrumental = false
    var fetchedAt = Date()

    var hasSynced: Bool { lines.count >= 2 }
}

enum LyricsState: Equatable {
    case idle
    case loading
    case synced
    case plain
    case instrumental
    case notFound
    /// The request itself failed (no network, server error), as opposed to
    /// the track simply having no lyrics.
    case unavailable
}

// MARK: - LRC parsing

enum LRCParser {
    /// Parses `[mm:ss.xx]text` lines. A line may carry several stamps (a
    /// repeated chorus), metadata tags like `[ar:…]` are skipped, and
    /// `[offset:±ms]` shifts everything, as the format defines it: a positive
    /// offset makes the lyrics appear earlier.
    static func parse(_ raw: String) -> [LyricLine] {
        var offset: TimeInterval = 0
        var result: [LyricLine] = []

        for rawLine in raw.split(whereSeparator: \.isNewline) {
            var rest = Substring(rawLine.trimmingCharacters(in: .whitespaces))
            var stamps: [TimeInterval] = []

            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex) ..< close]
                if let time = timestamp(tag) {
                    stamps.append(time)
                } else if tag.lowercased().hasPrefix("offset:") {
                    let value = tag.dropFirst("offset:".count).trimmingCharacters(in: .whitespaces)
                    offset = (Double(value) ?? 0) / 1000
                } else if !stamps.isEmpty {
                    // A bracket after the stamps is part of the lyric ("[Refren]").
                    break
                }
                rest = rest[rest.index(after: close)...]
            }

            guard !stamps.isEmpty else { continue }
            let text = stripWordTimings(String(rest)).trimmingCharacters(in: .whitespaces)
            for stamp in stamps {
                result.append(LyricLine(time: stamp, text: text))
            }
        }

        let shifted = result.map { LyricLine(time: max($0.time - offset, 0), text: $0.text) }
        // Stable on equal stamps, so two lines at the same time keep their order.
        return shifted.enumerated()
            .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
            .map(\.element)
    }

    /// `mm:ss`, `mm:ss.xx`, `mm:ss.xxx`, also with a comma or colon before the
    /// fraction. Returns nil for anything else, so metadata tags fall through.
    private static func timestamp(_ tag: Substring) -> TimeInterval? {
        let parts = tag.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let minutes = Int(parts[0]), parts[0].allSatisfy(\.isNumber) else { return nil }
        let seconds = parts[1].replacingOccurrences(of: ",", with: ".")
        guard let value = Double(seconds), seconds.first?.isNumber == true else { return nil }
        return Double(minutes) * 60 + value
    }

    /// Enhanced LRC puts `<mm:ss.xx>` before each word; the line is shown whole.
    private static func stripWordTimings(_ text: String) -> String {
        guard text.contains("<") else { return text }
        return text.replacingOccurrences(of: #"<\d{1,3}:\d{2}(?:[.:]\d{1,3})?>"#, with: "", options: .regularExpression)
    }
}

// MARK: - LRCLIB client

enum LRCLibClient {
    enum Outcome {
        case found(LyricsDocument)
        case notFound
        case failed
    }

    private struct Entry: Decodable {
        var trackName: String?
        var artistName: String?
        var albumName: String?
        var duration: Double?
        var instrumental: Bool?
        var plainLyrics: String?
        var syncedLyrics: String?
    }

    private static let base = "https://lrclib.net/api"

    /// LRCLIB asks clients to identify themselves.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 20
        configuration.httpAdditionalHeaders = ["User-Agent": "FunNotch (local build)"]
        return URLSession(configuration: configuration)
    }()

    static func fetch(title: String, artist: String, album: String, duration: TimeInterval) async -> Outcome {
        do {
            var unsynced: Entry?
            // The exact lookup needs the length; it is also the only one that
            // is certain to be this recording and not a live version.
            if duration > 0 {
                var items = [
                    URLQueryItem(name: "artist_name", value: artist),
                    URLQueryItem(name: "track_name", value: title),
                    URLQueryItem(name: "duration", value: String(Int(duration.rounded()))),
                ]
                if !album.isEmpty { items.insert(URLQueryItem(name: "album_name", value: album), at: 2) }
                if let entry: Entry = try await request("get", items) {
                    // Exact, but it may be the unsynced copy while a synced
                    // one is listed under another artist spelling.
                    if !(entry.syncedLyrics ?? "").isEmpty || entry.instrumental == true {
                        return .found(document(from: entry))
                    }
                    unsynced = entry
                }
            }

            let cleaned = cleanTitle(title)
            var searches: [(items: [URLQueryItem], requireArtist: Bool)] = [
                ([URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)], false),
            ]
            if cleaned != title {
                searches.append(([URLQueryItem(name: "track_name", value: cleaned), URLQueryItem(name: "artist_name", value: artist)], false))
            }
            // Free text, for when the artist field is "A & B" in one place and
            // "A, B" in the other.
            searches.append(([URLQueryItem(name: "q", value: "\(artist) \(cleaned)")], false))
            // The artist filter is an exact match, and players join a list of
            // artists their own way: YouTube Music says "Young Igi i Żabson",
            // LRCLIB has "Young Igi, Żabson", and neither search above finds
            // it. By title alone it is there, so ask that way and check the
            // artists share a name instead.
            searches.append(([URLQueryItem(name: "track_name", value: cleaned)], true))

            for search in searches {
                guard let entries: [Entry] = try await request("search", search.items) else { continue }
                if let best = pick(
                    from: entries, title: cleaned, duration: duration,
                    artist: search.requireArtist ? artist : nil
                ) {
                    if !(best.syncedLyrics ?? "").isEmpty { return .found(document(from: best)) }
                    if unsynced == nil { unsynced = best }
                }
            }
            // Only text without timings was out there: better than nothing.
            if let unsynced { return .found(document(from: unsynced)) }
            return .notFound
        } catch {
            return .failed
        }
    }

    /// nil on 404; throws on anything that is not a clean answer.
    private static func request<T: Decodable>(_ path: String, _ items: [URLQueryItem]) async throws -> T? {
        var components = URLComponents(string: "\(base)/\(path)")
        components?.queryItems = items
        guard let url = components?.url else { throw URLError(.badURL) }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// The words of an artist line that identify a name: "Young Igi i Żabson"
    /// and "Young Igi, Żabson" both give {young, igi, zabson}.
    private static func nameWords(_ artist: String) -> Set<String> {
        let folded = artist.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let words = folded.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let filler: Set<String> = ["oraz", "and", "feat", "ft", "with", "the", "i", "x"]
        return Set(words.filter { $0.count >= 2 && !filler.contains($0) })
    }

    /// Best of the search hits: must be the same song and about the same
    /// length (and, when `artist` is given, by someone who shares a name with
    /// it); synced lyrics beat plain ones.
    private static func pick(from entries: [Entry], title: String, duration: TimeInterval, artist: String? = nil) -> Entry? {
        let wanted = normalise(title)
        let wantedNames = artist.map(nameWords)
        let candidates = entries.filter { entry in
            guard let name = entry.trackName, normalise(cleanTitle(name)) == wanted else { return false }
            if duration > 0, let length = entry.duration, abs(length - duration) > 6 { return false }
            if let wantedNames, wantedNames.isDisjoint(with: nameWords(entry.artistName ?? "")) { return false }
            return entry.instrumental == true
                || !(entry.syncedLyrics ?? "").isEmpty
                || !(entry.plainLyrics ?? "").isEmpty
        }
        return candidates.min { lhs, rhs in
            let lhsSynced = !(lhs.syncedLyrics ?? "").isEmpty
            let rhsSynced = !(rhs.syncedLyrics ?? "").isEmpty
            if lhsSynced != rhsSynced { return lhsSynced }
            let lhsGap = duration > 0 ? abs((lhs.duration ?? duration) - duration) : 0
            let rhsGap = duration > 0 ? abs((rhs.duration ?? duration) - duration) : 0
            return lhsGap < rhsGap
        }
    }

    private static func document(from entry: Entry) -> LyricsDocument {
        var document = LyricsDocument()
        document.instrumental = entry.instrumental == true
        if let synced = entry.syncedLyrics, !synced.isEmpty {
            document.lines = LRCParser.parse(synced)
        }
        if let plain = entry.plainLyrics, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            document.plain = plain
        } else if document.hasSynced {
            document.plain = document.lines.map(\.text).joined(separator: "\n")
        }
        return document
    }

    /// "Song - 2011 Remaster", "Song (feat. X)" → "Song". Players tack these
    /// on and LRCLIB mostly does not have them.
    static func cleanTitle(_ title: String) -> String {
        var result = title
        let patterns = [
            #"\s*[\(\[][^\)\]]*(remaster|remix|live|version|edit|feat\.?|ft\.?|bonus|mono|stereo)[^\)\]]*[\)\]]"#,
            #"\s+-\s+.*(remaster|remix|live|version|edit|mono|stereo).*$"#,
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        let trimmed = result.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? title : trimmed
    }

    private static func normalise(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }
}

// MARK: - Disk cache

/// One JSON file per track under `~/Library/Caches/FunNotch/lyrics/`. Found
/// lyrics are kept for good; "nothing found" only for a few days, because
/// LRCLIB gets new lyrics all the time.
struct LyricsCache {
    private static let missLifetime: TimeInterval = 3 * 24 * 3600

    private struct File: Codable {
        var found: Bool
        var document: LyricsDocument?
    }

    private let directory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("FunNotch/lyrics", isDirectory: true)
    }()

    /// nil when nothing usable is cached. A cached miss reads back as `.some(nil)`.
    func read(_ key: String) -> LyricsDocument?? {
        guard let data = try? Data(contentsOf: url(for: key)),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else { return nil }
        if file.found, let document = file.document { return .some(document) }
        if let fetched = file.document?.fetchedAt, Date().timeIntervalSince(fetched) < Self.missLifetime {
            return .some(nil)
        }
        return nil
    }

    func write(_ key: String, document: LyricsDocument?) {
        let file = File(found: document != nil, document: document ?? LyricsDocument())
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(file).write(to: url(for: key), options: .atomic)
        } catch {
            DiagnosticLog.write("lyrics", "cache write failed: \(error.localizedDescription)")
        }
    }

    /// Readable prefix plus a hash, so names stay short and unique.
    private func url(for key: String) -> URL {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in key.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3
        }
        let prefix = String(key.filter { $0.isLetter || $0.isNumber }.prefix(40))
        return directory.appendingPathComponent("\(prefix)-\(String(hash, radix: 16)).json")
    }
}

// MARK: - Manager

@MainActor
final class LyricsManager: ObservableObject {
    static let shared = LyricsManager()

    @Published private(set) var state: LyricsState = .idle
    @Published private(set) var lines: [LyricLine] = []
    @Published private(set) var plain: String?
    /// Index into `lines` of the line being sung, nil before the first one.
    /// Changes once per line, not once per tick, so observers redraw rarely.
    @Published private(set) var currentIndex: Int?

    private let music = MusicManager.shared
    private let cache = LyricsCache()
    private var cancellables = Set<AnyCancellable>()
    private var task: Task<Void, Never>?
    private var started = false
    private var loadedKey = ""
    private var retryTask: Task<Void, Never>?
    private var retryCount = 0
    private var lastEnabled = MediaExtrasDefaults.lyricsEnabled

    /// The player's position runs a little behind what is audible, and LRC
    /// stamps mark the first sung syllable, so lines switch slightly early.
    private static let lead: TimeInterval = 0.2

    private init() {}

    func start() {
        guard !started else { return }
        started = true

        music.$track
            .map { track in
                TrackKey(title: track.title, artist: track.artist, album: track.album, hasDuration: track.hasTiming)
            }
            .removeDuplicates()
            // `@Published` fires before the value is stored; hop a turn of the
            // run loop so `reload()` reads the new track, not the old one.
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)

        music.$displayedElapsed
            .sink { [weak self] elapsed in self?.follow(elapsed) }
            .store(in: &cancellables)

        // The settings switch lives in UserDefaults; this fires for every key,
        // so only act when ours actually changed.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let enabled = MediaExtrasDefaults.lyricsEnabled
                if enabled != lastEnabled {
                    lastEnabled = enabled
                    reload()
                }
            }
            .store(in: &cancellables)
    }

    private struct TrackKey: Equatable {
        let title: String
        let artist: String
        let album: String
        let hasDuration: Bool
    }

    // MARK: Reading

    /// The line being sung, empty during an instrumental gap.
    var currentText: String? {
        guard state == .synced, let index = currentIndex, lines.indices.contains(index) else { return nil }
        let text = lines[index].text
        return text.isEmpty ? nil : text
    }

    /// The next line that has words.
    var nextText: String? {
        guard state == .synced else { return nil }
        let start = (currentIndex ?? -1) + 1
        guard start < lines.count else { return nil }
        return lines[start...].first(where: { !$0.text.isEmpty })?.text
    }

    /// Seconds from `elapsed` until the next line begins.
    private func secondsToNextLine(from elapsed: TimeInterval) -> TimeInterval? {
        let next = (currentIndex ?? -1) + 1
        guard lines.indices.contains(next) else { return nil }
        return max(lines[next].time - elapsed, 0)
    }

    // MARK: Loading

    private static func key(for track: TrackInfo) -> String {
        "\(track.artist.lowercased())|\(track.title.lowercased())|\(track.album.lowercased())"
    }

    /// A recording longer than this is a mix, a set or a lecture, not a song
    /// with published lyrics; asking LRCLIB would only send it a video title.
    private static let longestSong: TimeInterval = 15 * 60
    /// And one shorter than this is a clip or a Short.
    private static let shortestSong: TimeInterval = 40

    /// Whether `track` can plausibly have lyrics. A hashtagged title is a
    /// social video, whatever its length.
    private static func looksLikeSong(_ track: TrackInfo) -> Bool {
        if track.hasTiming, track.duration > longestSong || track.duration < shortestSong { return false }
        return !track.title.contains(" #") && !track.title.hasPrefix("#")
    }

    private func reload() {
        task?.cancel()
        task = nil
        retryTask?.cancel()
        retryTask = nil
        retryCount = 0

        let track = music.track
        lines = []
        plain = nil
        currentIndex = nil

        guard MediaExtrasDefaults.lyricsEnabled, !track.title.isEmpty else {
            state = .idle
            loadedKey = ""
            return
        }

        let key = Self.key(for: track)
        loadedKey = key

        guard Self.looksLikeSong(track) else {
            state = .notFound
            return
        }

        if let cached = cache.read(key) {
            apply(cached)
            return
        }
        lookup(track: track, key: key)
    }

    private func lookup(track: TrackInfo, key: String) {
        state = .loading
        let title = track.title
        let artist = track.artist
        let album = track.album
        let duration = track.duration
        let hasDuration = track.hasTiming
        task?.cancel()
        task = Task { [weak self] in
            let outcome = await LRCLibClient.fetch(title: title, artist: artist, album: album, duration: duration)
            guard !Task.isCancelled else { return }
            self?.finish(key: key, track: track, hasDuration: hasDuration, outcome: outcome)
        }
    }

    private func finish(key: String, track: TrackInfo, hasDuration: Bool, outcome: LRCLibClient.Outcome) {
        guard key == loadedKey else { return }
        switch outcome {
        case let .found(document):
            cache.write(key, document: document)
            apply(document)
        case .notFound:
            // Without the length only the looser search ran, which is no
            // reason to remember a miss for days.
            if hasDuration { cache.write(key, document: nil) }
            apply(nil)
        case .failed:
            state = .unavailable
            DiagnosticLog.write("lyrics", "lookup failed for \(key)")
            scheduleRetry(track: track, key: key)
        }
    }

    /// Offline or a server hiccup is not a verdict on the song: look again
    /// after a while, a few times, without waiting for the next track.
    private func scheduleRetry(track: TrackInfo, key: String) {
        let delays: [TimeInterval] = [15, 45, 120, 300]
        guard retryCount < delays.count else { return }
        let delay = delays[retryCount]
        retryCount += 1
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.loadedKey == key else { return }
            self.lookup(track: track, key: key)
        }
    }

    private func apply(_ document: LyricsDocument?) {
        guard let document else {
            state = .notFound
            return
        }
        lines = document.hasSynced ? document.lines : []
        plain = document.plain
        if document.instrumental, !document.hasSynced, document.plain == nil {
            state = .instrumental
        } else if document.hasSynced {
            state = .synced
        } else if document.plain != nil {
            state = .plain
        } else {
            state = document.instrumental ? .instrumental : .notFound
        }
        follow(music.displayedElapsed)
    }

    /// Installs finished lyrics without a lookup, for snapshots.
    func injectPreview(lines: [LyricLine], currentIndex: Int?) {
        task?.cancel()
        retryTask?.cancel()
        loadedKey = Self.key(for: music.track)
        self.lines = lines
        plain = lines.map(\.text).joined(separator: "\n")
        self.currentIndex = currentIndex
        state = .synced
    }

    func clearPreview() {
        task?.cancel()
        retryTask?.cancel()
        loadedKey = ""
        lines = []
        plain = nil
        currentIndex = nil
        state = .idle
    }

    func injectPreviewPlain(_ text: String) {
        loadedKey = Self.key(for: music.track)
        lines = []
        plain = text
        currentIndex = nil
        state = .plain
    }

    // MARK: Following playback

    private func follow(_ elapsed: TimeInterval) {
        guard state == .synced, !lines.isEmpty else { return }
        // Between a track change and its reload the old lines are still
        // here; they must not be followed with the new track's position.
        guard loadedKey == Self.key(for: music.track) else { return }
        let target = elapsed + Self.lead
        // Last line whose stamp has passed. Lines are sorted, so bisect.
        var low = 0
        var high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].time <= target { low = mid + 1 } else { high = mid }
        }
        let index: Int? = low == 0 ? nil : low - 1
        guard index != currentIndex else { return }
        currentIndex = index
        presentInClosedNotch(elapsed: elapsed)
    }

    // MARK: Closed notch

    /// Holds the current line in the strip under the closed notch, by keeping
    /// the track-change peek up for as long as the line lasts. The peek's chin
    /// shows the lyric instead of the title while this is on.
    private func presentInClosedNotch(elapsed: TimeInterval) {
        guard MediaExtrasDefaults.lyricsInClosedNotch,
              MediaExtrasDefaults.lyricsEnabled,
              music.isPlaying,
              currentText != nil
        else { return }

        let hold = min((secondsToNextLine(from: elapsed) ?? 4) + 0.6, 12)
        NotchWindowManager.shared.broadcast { viewModel in
            guard viewModel.notchState == .closed,
                  Settings.shared.sneakPeekStyle == .standard,
                  !viewModel.isShowingStandardHUD,
                  !viewModel.sneakPeek.show || viewModel.sneakPeek.type == .music
            else { return }
            viewModel.showSneakPeek(type: .music, duration: hold)
        }
    }
}
