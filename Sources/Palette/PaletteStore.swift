//
//  PaletteStore.swift
//  FunNotch
//
//  What the command palette remembers between launches: the text snippets,
//  the user's own search engines and the calculator history. Everything lives
//  in UserDefaults under `extras.palette.*`, as JSON where it is structured.
//

import Combine
import Foundation

enum PaletteDefaults {
    static let hotKeyEnabled = "extras.palette.hotKeyEnabled"
    static let snippets = "extras.palette.snippets"
    static let engines = "extras.palette.engines"
    static let calcHistory = "extras.palette.calcHistory"

    static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

// MARK: - Snippets

struct TextSnippet: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var text: String
}

@MainActor
final class SnippetStore: ObservableObject {
    static let shared = SnippetStore()

    /// Saved on every change, so the settings editor needs no "Save" button.
    @Published var items: [TextSnippet] {
        didSet { PaletteDefaults.save(items, key: PaletteDefaults.snippets) }
    }

    private init() {
        items = PaletteDefaults.load([TextSnippet].self, key: PaletteDefaults.snippets) ?? []
    }

    func add() {
        items.append(TextSnippet(name: "Nowy szablon", text: ""))
    }
}

// MARK: - Search engines

struct SearchEngine: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// What is typed before the query, without the space: "g", "yt".
    var prefix: String
    /// Address with `%s` where the search text goes.
    var template: String

    /// The address to open for `query`, or nil when the template is unusable.
    func url(for query: String) -> URL? {
        // ASCII only: `.alphanumerics` also lets Polish letters through unescaped.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !prefix.isEmpty && !prefix.contains(where: \.isWhitespace)
            && template.contains("%s")
            && (template.hasPrefix("https://") || template.hasPrefix("http://"))
    }
}

@MainActor
final class SearchEngineStore: ObservableObject {
    static let shared = SearchEngineStore()

    static let builtIn: [SearchEngine] = [
        SearchEngine(name: "Google", prefix: "g", template: "https://www.google.com/search?q=%s"),
        SearchEngine(name: "YouTube", prefix: "yt", template: "https://www.youtube.com/results?search_query=%s"),
        SearchEngine(name: "Allegro", prefix: "a", template: "https://allegro.pl/listing?string=%s"),
        SearchEngine(name: "DuckDuckGo", prefix: "ddg", template: "https://duckduckgo.com/?q=%s"),
        SearchEngine(name: "GitHub", prefix: "gh", template: "https://github.com/search?q=%s"),
        SearchEngine(name: "Wikipedia", prefix: "w", template: "https://pl.wikipedia.org/w/index.php?search=%s"),
    ]

    @Published var custom: [SearchEngine] {
        didSet { PaletteDefaults.save(custom, key: PaletteDefaults.engines) }
    }

    private init() {
        custom = PaletteDefaults.load([SearchEngine].self, key: PaletteDefaults.engines) ?? []
    }

    /// Own engines come first, so reusing a built-in prefix overrides it.
    var all: [SearchEngine] {
        custom.filter(\.isValid) + Self.builtIn
    }

    func engine(forPrefix prefix: String) -> SearchEngine? {
        let key = prefix.lowercased()
        return all.first { $0.prefix.lowercased() == key }
    }

    /// The engine offered as the last resort under every search.
    var fallback: SearchEngine { Self.builtIn[0] }

    func add() {
        custom.append(SearchEngine(name: "", prefix: "", template: "https://"))
    }
}

// MARK: - Calculator history

struct CalculatorEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    let expression: String
    let result: String
}

@MainActor
final class CalculatorHistory: ObservableObject {
    static let shared = CalculatorHistory()
    private static let limit = 8

    @Published private(set) var entries: [CalculatorEntry]

    private init() {
        entries = PaletteDefaults.load([CalculatorEntry].self, key: PaletteDefaults.calcHistory) ?? []
    }

    func record(expression: String, result: String) {
        entries.removeAll { $0.expression == expression && $0.result == result }
        entries.insert(CalculatorEntry(expression: expression, result: result), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        PaletteDefaults.save(entries, key: PaletteDefaults.calcHistory)
    }

    func clear() {
        entries = []
        PaletteDefaults.save(entries, key: PaletteDefaults.calcHistory)
    }
}
