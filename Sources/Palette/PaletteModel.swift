//
//  PaletteModel.swift
//  FunNotch
//
//  The brain of the command palette: turns what is typed into a list of
//  results and runs the chosen one. The panel (PalettePanel) and the SwiftUI
//  view (PaletteView) only display and forward keys.
//
//  Prefixes: "=" calculator, "t " translate, "s " snippets, "f " files, and
//  any search engine's own prefix ("g ", "yt ", "a ", ...). Anything else is a
//  general search over commands, notch tabs, apps, Shortcuts, clipboard
//  history and files.
//

import AppKit
import Combine
import NaturalLanguage
import SwiftUI

struct PaletteItem: Identifiable {
    enum Icon {
        case symbol(String, Color)
        /// The icon Finder shows for this path.
        case file(String)
    }

    let id: String
    var icon: Icon
    var title: String
    var subtitle: String?
    /// Short label on the right: "Aplikacja", "Plik", "⌘2".
    var trailing: String?
    /// Whether the previously active app gets focus back before `run`. Items
    /// that open something themselves turn this off so they are not fighting it.
    var restoresFocus = true
    /// Keep the palette on screen after Enter (a result still being computed).
    var keepsOpen = false
    let run: @MainActor () -> Void
}

/// A restriction of the palette to one kind of result, entered through a
/// command and left with Backspace on an empty field or by closing the palette.
enum PaletteScope {
    case windows
}

@MainActor
final class PaletteModel: ObservableObject {
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            queryChanged()
        }
    }

    @Published private(set) var items: [PaletteItem] = []
    @Published var selection = 0

    /// The pending on-device translation, picked up by the view that owns the
    /// translation session (see PaletteTranslation.swift).
    @Published private(set) var translationRequest: PaletteTranslationRequest?
    @Published private(set) var translation: PaletteTranslationState = .idle

    /// Set by the controller: closes the panel, then runs the item.
    var onActivate: ((PaletteItem) -> Void)?
    weak var searchField: NSTextField?

    /// What the list is restricted to, when it is not the whole palette.
    @Published private(set) var scope: PaletteScope?

    private var files: [PaletteFile] = []
    private lazy var fileSearch = PaletteFileSearch { [weak self] found in
        self?.files = found
        self?.rebuild(keepingSelection: true)
    }
    private var translationTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    /// Between `reset` and `suspend`. A closed palette has nothing on screen to
    /// refresh, and the clipboard alone would otherwise rebuild the list on
    /// every copy made anywhere.
    private var isOpen = false

    private static let rowLimit = 40

    init() {
        // Lists that load in the background change what a query matches.
        let apps = PaletteAppIndex.shared.objectWillChange.map { _ in () }
        let shortcuts = PaletteShortcuts.shared.objectWillChange.map { _ in () }
        let clipboard = ClipboardManager.shared.objectWillChange.map { _ in () }
        let commands = PaletteCommandRegistry.shared.objectWillChange.map { _ in () }
        let windows = PaletteWindowIndex.shared.objectWillChange.map { _ in () }
        Publishers.MergeMany(apps, shortcuts, clipboard, commands, windows)
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self, self.isOpen else { return }
                self.rebuild(keepingSelection: true)
            }
            .store(in: &cancellables)
    }

    // MARK: Lifecycle

    /// Called each time the palette opens.
    func reset(query initial: String = "", scope initialScope: PaletteScope? = nil) {
        isOpen = true
        scope = initialScope
        PaletteWindowIndex.shared.refresh()
        fileSearch.cancel()
        translationTask?.cancel()
        files = []
        translation = .idle
        translationRequest = nil
        if query == initial {
            rebuild(keepingSelection: false)
        } else {
            query = initial
        }
        PaletteAppIndex.shared.refresh()
        PaletteShortcuts.shared.refresh()
    }

    func suspend() {
        isOpen = false
        scope = nil
        fileSearch.cancel()
        translationTask?.cancel()
        PaletteWindowIndex.shared.clear()
    }

    /// Backspace on an empty field leaves a scoped listing for the full palette.
    /// Returns whether it did anything.
    func leaveScope() -> Bool {
        guard scope != nil, query.isEmpty else { return false }
        scope = nil
        rebuild(keepingSelection: false)
        return true
    }

    // MARK: Keys

    func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        selection = (selection + delta + items.count) % items.count
    }

    func activateSelection() {
        guard items.indices.contains(selection) else { return }
        onActivate?(items[selection])
    }

    /// ⌘1…⌘9: opens the n-th notch tab, whatever is typed.
    func jumpToTab(number: Int) {
        let tabs = PaletteTabs.available
        guard tabs.indices.contains(number - 1) else { return }
        onActivate?(PaletteTabs.item(for: tabs[number - 1], number: nil))
    }

    // MARK: Building results

    /// The windows listing: every open window (best match first once something
    /// is typed), nothing else, and no prefix modes.
    private func windowScopeItems(_ text: String) -> [PaletteItem] {
        let index = PaletteWindowIndex.shared
        guard AXIsProcessTrusted() else { return [PaletteWindows.statusItem(isTrusted: false)] }
        let matches = PaletteWindows.matches(PaletteMatch.fold(text.trimmingCharacters(in: .whitespaces)), in: index.windows)
        if matches.isEmpty && !index.hasLoaded { return [PaletteWindows.statusItem(isTrusted: true)] }
        return matches.map { PaletteWindows.item(for: $0.0) }
    }

    private func queryChanged() {
        selection = 0
        if isOpen { PaletteWindowIndex.shared.refreshIfStale() }
        if scope != nil {
            // Nothing but windows is listed, so nothing else is searched.
            fileSearch.cancel()
            files = []
            translationTask?.cancel()
            translation = .idle
            translationRequest = nil
            rebuild(keepingSelection: false)
            return
        }
        let mode = Mode(query)
        if case .general(let text) = mode, !text.isEmpty {
            fileSearch.search(text)
        } else if case .files(let text) = mode {
            fileSearch.search(text)
        } else {
            fileSearch.cancel()
            files = []
        }
        if case .translate(let text) = mode {
            scheduleTranslation(text)
        } else {
            translationTask?.cancel()
            translation = .idle
            translationRequest = nil
        }
        rebuild(keepingSelection: false)
    }

    private func rebuild(keepingSelection: Bool) {
        let previous = items.indices.contains(selection) ? items[selection].id : nil
        let built = scope == .windows ? windowScopeItems(query) : buildItems(for: Mode(query))
        items = Array(built.prefix(Self.rowLimit))
        if keepingSelection, let previous, let index = items.firstIndex(where: { $0.id == previous }) {
            selection = index
        } else {
            selection = 0
        }
    }

    private enum Mode {
        case empty
        case calculator(String)
        case translate(String)
        case snippets(String)
        case files(String)
        case engine(SearchEngine, String)
        case general(String)

        @MainActor
        init(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { self = .empty; return }
            if trimmed.hasPrefix("=") {
                self = .calculator(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                return
            }
            // A prefix needs its space ("g cats"); a bare "g" is still a search.
            // Leading spaces are ignored, so " g cats" still works.
            let leading = raw.drop(while: { $0 == " " })
            if let space = leading.firstIndex(of: " ") {
                let prefix = String(leading[..<space]).lowercased()
                let rest = String(leading[leading.index(after: space)...]).trimmingCharacters(in: .whitespaces)
                switch prefix {
                case "t": self = .translate(rest); return
                case "s": self = .snippets(rest); return
                case "f": self = .files(rest); return
                default:
                    if let engine = SearchEngineStore.shared.engine(forPrefix: prefix) {
                        self = .engine(engine, rest)
                        return
                    }
                }
            }
            self = .general(trimmed)
        }
    }

    private func buildItems(for mode: Mode) -> [PaletteItem] {
        switch mode {
        case .empty:
            return emptyItems()
        case let .calculator(expression):
            return calculatorItems(expression, forced: true)
        case let .translate(text):
            return translationItems(text)
        case let .snippets(filter):
            return snippetItems(filter)
        case let .files(text):
            return fileItems(text.isEmpty ? [] : files)
        case let .engine(engine, text):
            return engineItems(engine, text)
        case let .general(text):
            return generalItems(text)
        }
    }

    // MARK: Groups

    private func emptyItems() -> [PaletteItem] {
        var result = PaletteCommandRegistry.shared.commands.map(commandItem)
        result += PaletteTabs.available.enumerated().map { PaletteTabs.item(for: $1, number: $0 + 1) }
        for entry in CalculatorHistory.shared.entries.prefix(3) {
            result.append(historyItem(entry))
        }
        return result
    }

    private func commandItem(_ command: PaletteCommand) -> PaletteItem {
        PaletteItem(
            id: "cmd:" + command.id,
            icon: .symbol(command.symbol, SettingsStyle.indigo),
            title: command.title,
            subtitle: command.subtitle,
            trailing: "Polecenie",
            run: command.perform
        )
    }

    private func historyItem(_ entry: CalculatorEntry) -> PaletteItem {
        PaletteItem(
            id: "calc-history:\(entry.id)",
            icon: .symbol("clock.arrow.circlepath", SettingsStyle.gray),
            title: entry.result,
            subtitle: entry.expression,
            trailing: "Kalkulator",
            run: { Self.copyResult(entry.result, expression: entry.expression) }
        )
    }

    private func calculatorItems(_ expression: String, forced: Bool) -> [PaletteItem] {
        if expression.isEmpty {
            let history = CalculatorHistory.shared.entries.map(historyItem)
            guard history.isEmpty else { return history }
            return [PaletteItem(
                id: "calc:hint",
                icon: .symbol("equal.circle.fill", SettingsStyle.orange),
                title: "Wpisz działanie",
                subtitle: "Na przykład = 12,5 * 4 albo = 200 + 10%",
                keepsOpen: true,
                run: {}
            )]
        }
        guard let result = PaletteCalculator.evaluate(expression, force: forced) else {
            guard forced else { return [] }
            return [PaletteItem(
                id: "calc:error",
                icon: .symbol("exclamationmark.circle", SettingsStyle.gray),
                title: "Nie da się obliczyć",
                subtitle: expression,
                keepsOpen: true,
                run: {}
            )]
        }
        return [PaletteItem(
            id: "calc:result",
            icon: .symbol("equal.circle.fill", SettingsStyle.orange),
            title: result,
            subtitle: "\(expression) · Enter kopiuje wynik",
            trailing: "Kalkulator",
            run: { Self.copyResult(result, expression: expression) }
        )]
    }

    private static func copyResult(_ result: String, expression: String) {
        PaletteClipboard.copy(result)
        CalculatorHistory.shared.record(expression: expression, result: result)
        IslandCenter.shared.post(Island(
            symbol: "equal.circle.fill",
            tint: SettingsStyle.orange,
            title: result,
            detail: " · skopiowano"
        ))
    }

    private func snippetItems(_ filter: String) -> [PaletteItem] {
        let snippets = SnippetStore.shared.items
        guard !snippets.isEmpty else {
            return [PaletteItem(
                id: "snippet:none",
                icon: .symbol("text.badge.plus", SettingsStyle.teal),
                title: "Brak szablonów tekstu",
                subtitle: "Dodasz je w ustawieniach, na stronie Dodatki",
                restoresFocus: false,
                run: { SettingsWindowController.shared.show() }
            )]
        }
        let folded = PaletteMatch.fold(filter)
        let matching = snippets.compactMap { snippet -> (TextSnippet, Int)? in
            guard let score = PaletteMatch.score(query: folded, in: PaletteMatch.fold(snippet.name)) else { return nil }
            return (snippet, score)
        }
        // Keep the user's own order while nothing is typed; rank once there is a filter.
        let ordered = folded.isEmpty ? matching : matching.sorted { $0.1 > $1.1 }
        return ordered.map { snippet, _ in
            PaletteItem(
                id: "snippet:\(snippet.id)",
                icon: .symbol("text.quote", SettingsStyle.teal),
                title: snippet.name,
                subtitle: snippet.text.replacingOccurrences(of: "\n", with: " "),
                trailing: "Szablon",
                run: { PaletteClipboard.paste(snippet.text) }
            )
        }
    }

    private func fileItems(_ found: [PaletteFile]) -> [PaletteItem] {
        found.map { file in
            PaletteItem(
                id: "file:" + file.path,
                icon: .file(file.path),
                title: file.name,
                subtitle: file.folder,
                trailing: "Plik",
                restoresFocus: false,
                run: { NSWorkspace.shared.open(URL(fileURLWithPath: file.path)) }
            )
        }
    }

    private func engineItems(_ engine: SearchEngine, _ text: String) -> [PaletteItem] {
        guard !text.isEmpty else {
            return [PaletteItem(
                id: "engine:hint:\(engine.id)",
                icon: .symbol("magnifyingglass", SettingsStyle.blue),
                title: "Szukaj w: \(engine.name)",
                subtitle: "Wpisz, czego szukać",
                keepsOpen: true,
                run: {}
            )]
        }
        return [Self.engineItem(engine, text)]
    }

    private static func engineItem(_ engine: SearchEngine, _ text: String) -> PaletteItem {
        PaletteItem(
            id: "engine:\(engine.id):\(text)",
            icon: .symbol("magnifyingglass", SettingsStyle.blue),
            title: "Szukaj w \(engine.name): \(text)",
            subtitle: engine.prefix + " " + text,
            trailing: "Internet",
            restoresFocus: false,
            run: {
                if let url = engine.url(for: text) { NSWorkspace.shared.open(url) }
            }
        )
    }

    private func generalItems(_ text: String) -> [PaletteItem] {
        let folded = PaletteMatch.fold(text)
        var result: [PaletteItem] = []

        // Maths first: if it parses, that is what was meant.
        result += calculatorItems(text, forced: false)

        // Commands, tabs, apps and shortcuts compete on match quality.
        var ranked: [(PaletteItem, Int)] = []
        for command in PaletteCommandRegistry.shared.commands {
            let haystack = ([command.title, command.subtitle ?? ""] + command.keywords).joined(separator: " ")
            if let score = PaletteMatch.score(query: folded, in: PaletteMatch.fold(haystack)) {
                ranked.append((commandItem(command), score + 50))
            }
        }
        for (index, tab) in PaletteTabs.available.enumerated() {
            let haystack = "karta \(tab.title) \(tab.rawValue)"
            if let score = PaletteMatch.score(query: folded, in: PaletteMatch.fold(haystack)) {
                ranked.append((PaletteTabs.item(for: tab, number: index + 1), score))
            }
        }
        for app in PaletteAppIndex.shared.apps {
            if let score = PaletteMatch.score(query: folded, in: app.folded) {
                ranked.append((appItem(app), score + 20))
            }
        }
        for name in PaletteShortcuts.shared.names {
            if let score = PaletteMatch.score(query: folded, in: PaletteMatch.fold(name)) {
                ranked.append((shortcutItem(name), score))
            }
        }
        // Open windows: a few at most, so a common app name cannot crowd the rest out.
        for (window, score) in PaletteWindows.matches(folded, in: PaletteWindowIndex.shared.windows).prefix(4) {
            ranked.append((PaletteWindows.item(for: window), score + 10))
        }
        result += ranked.sorted { $0.1 > $1.1 }.prefix(8).map(\.0)

        // Clipboard history, text only, at most three.
        if folded.count >= 2 {
            let entries = ClipboardManager.shared.entries.compactMap { entry -> PaletteItem? in
                guard case let .text(value) = entry.payload,
                      PaletteMatch.fold(value).contains(folded) else { return nil }
                return PaletteItem(
                    id: "clip:\(entry.id)",
                    icon: .symbol(entry.symbol, SettingsStyle.purple),
                    title: String(entry.preview.prefix(110)),
                    subtitle: entry.sourceApp.map { "Skopiowano z: \($0)" },
                    trailing: "Schowek",
                    run: {
                        ClipboardManager.shared.copyBack(entry)
                        PaletteClipboard.paste(value)
                    }
                )
            }
            result += entries.prefix(3)
        }

        result += fileItems(files)

        // The way out for anything that matched nothing here.
        result.append(Self.engineItem(SearchEngineStore.shared.fallback, text))
        return result
    }

    private func appItem(_ app: PaletteApp) -> PaletteItem {
        PaletteItem(
            id: "app:" + app.url.path,
            icon: .file(app.url.path),
            title: app.name,
            subtitle: nil,
            trailing: "Aplikacja",
            restoresFocus: false,
            run: {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(at: app.url, configuration: configuration) { _, error in
                    if let error {
                        DiagnosticLog.write("palette", "launch \(app.name) failed: \(error.localizedDescription)")
                    }
                }
            }
        )
    }

    private func shortcutItem(_ name: String) -> PaletteItem {
        PaletteItem(
            id: "shortcut:" + name,
            icon: .symbol("bolt.square.fill", SettingsStyle.pink),
            title: name,
            subtitle: "Uruchom skrót",
            trailing: "Skrót",
            run: { PaletteShortcuts.shared.run(name) }
        )
    }

    // MARK: Translation

    private func translationItems(_ text: String) -> [PaletteItem] {
        guard !text.isEmpty else {
            return [PaletteItem(
                id: "translate:hint",
                icon: .symbol("character.bubble.fill", SettingsStyle.teal),
                title: "Wpisz tekst do przetłumaczenia",
                subtitle: "Polski na angielski, każdy inny język na polski",
                keepsOpen: true,
                run: {}
            )]
        }
        let google = PaletteItem(
            id: "translate:google",
            icon: .symbol("globe", SettingsStyle.blue),
            title: "Otwórz w Tłumaczu Google",
            subtitle: text,
            trailing: "Internet",
            restoresFocus: false,
            run: { PaletteTranslation.openInGoogle(text) }
        )
        switch translation {
        case .idle, .working:
            return [
                PaletteItem(
                    id: "translate:working",
                    icon: .symbol("character.bubble.fill", SettingsStyle.teal),
                    title: "Tłumaczę…",
                    subtitle: text,
                    keepsOpen: true,
                    run: {}
                ),
                google,
            ]
        case let .done(result, direction):
            return [
                PaletteItem(
                    id: "translate:result",
                    icon: .symbol("character.bubble.fill", SettingsStyle.teal),
                    title: result,
                    subtitle: "\(direction) · Enter kopiuje",
                    trailing: "Tłumacz",
                    run: {
                        PaletteClipboard.copy(result)
                        IslandCenter.shared.post(Island(
                            symbol: "character.bubble.fill",
                            tint: SettingsStyle.teal,
                            title: "Tłumaczenie",
                            detail: " · skopiowano"
                        ))
                    }
                ),
                google,
            ]
        case let .unavailable(reason):
            return [
                PaletteItem(
                    id: "translate:unavailable",
                    icon: .symbol("exclamationmark.circle", SettingsStyle.gray),
                    title: "Tłumaczenie na urządzeniu niedostępne",
                    subtitle: reason,
                    keepsOpen: true,
                    run: {}
                ),
                google,
            ]
        }
    }

    private func scheduleTranslation(_ text: String) {
        translationTask?.cancel()
        translation = .idle
        translationRequest = nil
        guard !text.isEmpty else { return }
        translationTask = Task { [weak self] in
            // Wait for typing to pause; each request may fetch a language model.
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled, let self else { return }
            guard #available(macOS 15.0, *) else {
                self.translation = .unavailable("Wymaga macOS 15 lub nowszego")
                self.rebuild(keepingSelection: true)
                return
            }
            self.translation = .working
            switch await PaletteTranslation.plan(for: text) {
            case let .request(request):
                guard !Task.isCancelled else { return }
                self.translationRequest = request
            case let .unavailable(reason):
                guard !Task.isCancelled else { return }
                self.translation = .unavailable(reason)
            }
            self.rebuild(keepingSelection: true)
        }
    }

    /// Called by the view that ran the session.
    func finishTranslation(_ request: PaletteTranslationRequest, result: Result<String, Error>) {
        guard request.id == translationRequest?.id else { return }
        switch result {
        case let .success(text):
            translation = .done(text, request.directionLabel)
        case let .failure(error):
            DiagnosticLog.write("palette", "translation failed: \(error.localizedDescription)")
            translation = .unavailable("Nie udało się przetłumaczyć")
        }
        rebuild(keepingSelection: true)
    }
}

// MARK: - Notch tabs

@MainActor
enum PaletteTabs {
    /// Mirrors which tabs the open notch shows, so ⌘1–9 and the list agree with
    /// the tab bar.
    static var available: [NotchTab] {
        let settings = Settings.shared
        return NotchTab.allCases.filter { tab in
            switch tab {
            case .shelf: return settings.shelfEnabled
            case .clipboard: return settings.clipboardHistoryEnabled
            case .notes: return settings.showNotes
            case .game: return !FocusManager.shared.isActive
            case .notifications: return NotifyCenter.shared.showsTab
            default: return true
            }
        }
    }

    static func item(for tab: NotchTab, number: Int?) -> PaletteItem {
        PaletteItem(
            id: "tab:" + tab.rawValue,
            icon: .symbol(tab.symbol, SettingsStyle.purple),
            title: "Karta: \(tab.title)",
            subtitle: nil,
            trailing: number.map { $0 <= 9 ? "⌘\($0)" : "Karta" } ?? "Karta",
            run: { open(tab) }
        )
    }

    static func open(_ tab: NotchTab) {
        guard let viewModel = NotchWindowManager.shared.activeViewModel else { return }
        viewModel.open()
        withAnimation(.notchContent) { viewModel.currentTab = tab }
    }
}
