//
//  PaletteSources.swift
//  FunNotch
//
//  Where the palette finds things: a fuzzy matcher, the installed apps (the
//  launcher), and files through Spotlight.
//

import AppKit
import Foundation

// MARK: - Matching

enum PaletteMatch {
    /// Lowercased, without diacritics ("Łódź" → "lodz"), so Polish text can be
    /// searched with an English keyboard. `ł` has no decomposition, hence the
    /// extra replacement.
    static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "ł", with: "l")
    }

    /// How well `query` matches `candidate` (both already folded); nil when it
    /// does not match. Every word of the query has to match somewhere.
    static func score(query: String, in candidate: String) -> Int? {
        let tokens = query.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return 0 }
        let words = candidate.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        var total = 0
        for token in tokens {
            let value: Int
            if candidate.hasPrefix(token) {
                value = 4
            } else if words.contains(where: { $0.hasPrefix(token) }) {
                value = 3
            } else if candidate.contains(token) {
                value = 2
            } else if token.count >= 3, isSubsequence(token, of: candidate) {
                value = 1
            } else {
                return nil
            }
            total += value
        }
        // Among equal matches the shorter name is the likelier intent.
        return total * 100 - min(candidate.count, 99)
    }

    private static func isSubsequence(_ token: String, of candidate: String) -> Bool {
        var remaining = token[...]
        for character in candidate where remaining.first == character {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return true }
        }
        return remaining.isEmpty
    }
}

// MARK: - Applications

struct PaletteApp: Identifiable, Hashable {
    let name: String
    let folded: String
    let url: URL
    var id: String { url.path }
}

@MainActor
final class PaletteAppIndex: ObservableObject {
    static let shared = PaletteAppIndex()

    @Published private(set) var apps: [PaletteApp] = []
    private var isScanning = false

    private init() {}

    /// Rescans in the background. Cheap enough to run on every palette open,
    /// which keeps a freshly installed app findable.
    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        Task.detached(priority: .utility) {
            let found = Self.scan()
            await MainActor.run {
                PaletteAppIndex.shared.apps = found
                PaletteAppIndex.shared.isScanning = false
            }
        }
    }

    private nonisolated static func scan() -> [PaletteApp] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let roots = [
            "/Applications", "/System/Applications", "\(home)/Applications",
            "/System/Cryptexes/App/System/Applications",
            // Screen Sharing, Directory Utility, Wireless Diagnostics and friends.
            "/System/Library/CoreServices/Applications",
        ]
        // Finder lives in CoreServices next to dozens of background helpers, so
        // it is added by path instead of scanning that folder.
        let singles = ["/System/Library/CoreServices/Finder.app"]
        var byName: [String: PaletteApp] = [:]

        func add(_ url: URL) {
            var name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name.removeLast(4) }
            // The first root wins, so /Applications beats a stray copy elsewhere.
            guard byName[name] == nil else { return }
            // The name on disk too: a Polish display name must not hide "System Settings".
            let fileName = url.deletingPathExtension().lastPathComponent
            let searchable = fileName == name ? name : "\(name) \(fileName)"
            byName[name] = PaletteApp(name: name, folded: PaletteMatch.fold(searchable), url: url)
        }

        for root in roots {
            guard let walker = FileManager.default.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.isApplicationKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in walker {
                // Folders like Utilities hold apps one level down; go no deeper.
                if walker.level > 3 { walker.skipDescendants(); continue }
                guard url.pathExtension == "app" else { continue }
                add(url)
            }
        }
        for path in singles where FileManager.default.fileExists(atPath: path) {
            add(URL(fileURLWithPath: path))
        }
        return byName.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Files

struct PaletteFile: Identifiable, Hashable {
    let path: String
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    /// The folder it lives in, with the home directory shortened to "~".
    var folder: String {
        (path as NSString).deletingLastPathComponent.replacingOccurrences(
            of: NSHomeDirectory(), with: "~"
        )
    }
}

/// A name search through Spotlight, limited to the top few results.
@MainActor
final class PaletteFileSearch {
    static let limit = 8

    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?
    private var debounce: Task<Void, Never>?
    private let onResults: ([PaletteFile]) -> Void

    init(onResults: @escaping ([PaletteFile]) -> Void) {
        self.onResults = onResults
    }

    func search(_ text: String) {
        debounce?.cancel()
        stopQuery()
        let words = text.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty, text.count >= 2 else {
            onResults([])
            return
        }
        // Spotlight is queried only once typing pauses; every keystroke would
        // start a fresh crawl of the index.
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            self?.start(words: words)
        }
    }

    func cancel() {
        debounce?.cancel()
        stopQuery()
    }

    private func start(words: [String]) {
        let query = NSMetadataQuery()
        let wordPredicates = words.map {
            NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, $0)
        }
        // NSMetadataQuery throws (and the app dies) on an AND of a single
        // predicate, so one word is passed as it is.
        query.predicate = wordPredicates.count == 1
            ? wordPredicates[0]
            : NSCompoundPredicate(andPredicateWithSubpredicates: wordPredicates)
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        // Recently used first: those are the files someone is likely to want.
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemLastUsedDateKey, ascending: false)]
        observer = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
        self.query = query
        query.start()
    }

    private func finish() {
        guard let query else { return }
        query.disableUpdates()
        let home = NSHomeDirectory()
        var files: [PaletteFile] = []
        for index in 0 ..< min(query.resultCount, 400) {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            // Library, dot-folders and app bundles are noise next to real files;
            // apps have their own source.
            if path.hasPrefix(home + "/Library/") || path.contains("/.") || path.contains(".app/") { continue }
            if path.hasSuffix(".app") { continue }
            files.append(PaletteFile(path: path))
            if files.count == Self.limit { break }
        }
        stopQuery()
        onResults(files)
    }

    private func stopQuery() {
        query?.stop()
        query = nil
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }
}
