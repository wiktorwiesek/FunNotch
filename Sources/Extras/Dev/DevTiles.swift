//
//  DevTiles.swift
//  FunNotch
//
//  The three home tiles of the developer extras: GitHub (CI and pull
//  requests), AI usage and the app launcher. Each one takes `compact`: true in
//  the 46-point bottom row, false in the tall top row where there is room for
//  a list.
//

import AppKit
import SwiftUI

private func openInBrowser(_ url: URL) {
    NSWorkspace.shared.open(url)
}

// MARK: - GitHub

struct GitHubTile: View {
    let compact: Bool
    @ObservedObject private var manager = GitHubManager.shared

    var body: some View {
        content
            // Centered in the 46-point row (the tall row reads from the top).
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: compact ? .leading : .topLeading)
            .padding(.vertical, compact ? 0 : 9)
            .onAppear { manager.addSubscriber() }
            .onDisappear { manager.removeSubscriber() }
    }

    @ViewBuilder
    private var content: some View {
        switch manager.phase {
        case .unavailable(let message):
            notice(message)
        case .idle, .loading:
            if manager.repos.isEmpty {
                notice("Wczytywanie GitHuba…")
            } else {
                ready
            }
        case .ready:
            ready
        }
    }

    private func notice(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            PanelLabel(text: "GitHub")
            Text(text)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(compact ? 2 : 4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var ready: some View {
        if compact { compactBody } else { expandedBody }
    }

    // MARK: Compact

    /// The repository most worth a glance: one whose CI is red, then one
    /// whose CI is running, then the first.
    private var featured: GitHubRepoStatus? {
        let repos = manager.repos
        return repos.first { $0.run?.state == .failure }
            ?? repos.first { $0.run?.state == .running }
            ?? repos.first
    }

    private var reviewCount: Int { manager.repos.reduce(0) { $0 + $1.reviewRequests.count } }
    private var authoredCount: Int { manager.repos.reduce(0) { $0 + $1.authored.count } }

    @ViewBuilder
    private var compactBody: some View {
        if let repo = featured {
            VStack(alignment: .leading, spacing: 3) {
                PanelLabel(text: manager.repos.count > 1 ? "GitHub · \(manager.repos.count) repo" : "GitHub · \(repo.name)")
                if let error = repo.error, repo.run == nil {
                    Text(error)
                        .font(.system(size: 8.5))
                        .foregroundStyle(.orange.opacity(0.85))
                        .lineLimit(2)
                } else {
                    // Short on purpose: the tile is about 150 pt wide, and a chip
                    // that has to truncate ("CI cz…") says nothing.
                    HStack(spacing: 8) {
                        chip(ciShortTitle(repo.run), tint: Self.tint(of: repo.run), url: repo.run?.url ?? repo.actionsURL,
                             help: ciTitle(repo.run) + " na \(repo.branch)")
                        if repo.hasPullRequests {
                            // The counts span every repository, so with several of
                            // them the links must too.
                            let several = manager.repos.count > 1
                            if reviewCount > 0 {
                                chip("\(reviewCount)", symbol: "eye", tint: .orange,
                                     url: several ? URL(string: "https://github.com/pulls/review-requested")! : repo.reviewURL,
                                     help: "Do przeglądu: \(reviewCount)")
                            }
                            if authoredCount > 0 {
                                chip("\(authoredCount)", symbol: "arrow.triangle.pull", tint: .blue,
                                     url: several ? URL(string: "https://github.com/pulls")! : repo.authoredURL,
                                     help: "Moje otwarte PR-y: \(authoredCount)")
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chip(_ text: String, symbol: String? = nil, tint: Color, url: URL, help: String) -> some View {
        Button { openInBrowser(url) } label: {
            HStack(spacing: 3) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(tint)
                } else {
                    Circle().fill(tint).frame(width: 5, height: 5)
                }
                Text(text)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
                    .fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(help) · otwórz w przeglądarce")
    }

    // MARK: Expanded

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(manager.repos.prefix(2)) { repo in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        PanelLabel(text: repo.slug)
                        Spacer(minLength: 0)
                    }
                    if let error = repo.error, repo.run == nil {
                        Text(error)
                            .font(.system(size: 9))
                            .foregroundStyle(.orange.opacity(0.85))
                            .lineLimit(2)
                    }
                    row(symbol: Self.symbol(of: repo.run), tint: Self.tint(of: repo.run),
                        text: ciLine(repo), url: repo.run?.url ?? repo.actionsURL)
                    ForEach(Array(repo.reviewRequests.prefix(2))) { pull in
                        row(symbol: "eye", tint: .orange, text: "#\(pull.number) \(pull.title)", url: pull.url)
                    }
                    ForEach(Array(repo.authored.prefix(2))) { pull in
                        row(symbol: pull.isDraft ? "pencil.circle" : "arrow.triangle.pull", tint: .blue,
                            text: "#\(pull.number) \(pull.title)", url: pull.url)
                    }
                    if repo.hasPullRequests, repo.reviewRequests.isEmpty, repo.authored.isEmpty {
                        Text("Brak otwartych PR-ów")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(symbol: String, tint: Color, text: String, url: URL) -> some View {
        Button { openInBrowser(url) } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 12)
                Text(text)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Otwórz w przeglądarce")
    }

    // MARK: Wording

    private func ciTitle(_ run: GitHubRun?) -> String {
        switch run?.state {
        case .success: return "CI zielone"
        case .failure: return "CI czerwone"
        case .running: return "CI w toku"
        case .cancelled: return "CI anulowane"
        case .other: return "CI zakończone"
        case nil: return "brak CI"
        }
    }

    /// For the compact chip; the full wording is in its tooltip.
    private func ciShortTitle(_ run: GitHubRun?) -> String {
        switch run?.state {
        case .success: return "CI ok"
        case .failure: return "CI błąd"
        case .running: return "CI trwa"
        case .cancelled: return "CI anul."
        case .other: return "CI koniec"
        case nil: return "brak CI"
        }
    }

    private func ciLine(_ repo: GitHubRepoStatus) -> String {
        guard let run = repo.run else { return "Brak przebiegów CI na \(repo.branch)" }
        return "\(ciTitle(run)) na \(repo.branch) · \(run.title)"
    }

    static func tint(of run: GitHubRun?) -> Color {
        switch run?.state {
        case .success: return SettingsStyle.green
        case .failure: return SettingsStyle.red
        case .running: return SettingsStyle.yellow
        default: return SettingsStyle.gray
        }
    }

    static func symbol(of run: GitHubRun?) -> String {
        switch run?.state {
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.octagon.fill"
        case .running: return "clock.fill"
        default: return "circle.dashed"
        }
    }
}

// MARK: - AI usage

struct AIUsageTile: View {
    let compact: Bool
    @ObservedObject private var manager = AIUsageManager.shared

    private var snapshot: AIUsageSnapshot { manager.snapshot }

    var body: some View {
        Group {
            if compact { compactBody } else { expandedBody }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: compact ? .leading : .topLeading)
        .padding(.vertical, compact ? 0 : 9)
        .onAppear { manager.addSubscriber() }
        .onDisappear { manager.removeSubscriber() }
    }

    private var costText: String {
        guard manager.hasScanned else { return "…" }
        return (snapshot.todayIsEstimate ? "~" : "") + AIUsageManager.money(snapshot.todayCost)
    }

    private var compactBody: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                PanelLabel(text: "Zużycie AI dziś")
                // The cost is the point: the token count gives way first.
                ViewThatFits(in: .horizontal) {
                    compactFigures(withTokens: true)
                    compactFigures(withTokens: false)
                }
            }
            Spacer(minLength: 0)
            AIUsageBars(days: snapshot.days, showLabels: false)
                .frame(width: 44, height: 28)
        }
        .help("Koszt i tokeny z logów omp i Claude Code")
    }

    private func compactFigures(withTokens: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(costText)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.92))
            if withTokens {
                Text(AIUsageManager.tokens(snapshot.todayTokens))
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Two lines: label, then figures. Side by side they do not fit in
            // a tile about 200 pt wide and the label is the one that suffers.
            VStack(alignment: .leading, spacing: 1) {
                PanelLabel(text: "Zużycie AI dziś")
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(costText)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.92))
                        .fixedSize()
                    Text(AIUsageManager.tokens(snapshot.todayTokens) + " tokenów")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            ForEach(snapshot.providers.prefix(3)) { provider in
                HStack(spacing: 6) {
                    Text(AIUsageManager.providerName(provider.name))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(AIUsageManager.tokens(provider.tokens))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.4))
                    Text((provider.costIsEstimate ? "~" : "") + AIUsageManager.money(provider.cost))
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 58, alignment: .trailing)
                }
            }
            if snapshot.providers.isEmpty, manager.hasScanned {
                Text("Dziś nic jeszcze nie zużyto")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer(minLength: 0)
            AIUsageBars(days: snapshot.days, showLabels: true)
                .frame(height: 40)
        }
    }
}

/// Seven days of cost as bars; today is the bright one.
private struct AIUsageBars: View {
    let days: [AIUsageDay]
    let showLabels: Bool

    private static let weekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Polish.locale
        formatter.setLocalizedDateFormatFromTemplate("EEEEE")
        return formatter
    }()

    var body: some View {
        // Cost is the headline, but a day of free models still did work.
        let values = days.map { $0.cost > 0 ? $0.cost : Double($0.tokens) / 1_000_000 }
        let peak = max(values.max() ?? 0, 0.0001)
        HStack(alignment: .bottom, spacing: showLabels ? 6 : 2) {
            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                VStack(spacing: 2) {
                    GeometryReader { proxy in
                        VStack {
                            Spacer(minLength: 0)
                            Capsule()
                                .fill(Color.orange.opacity(index == days.count - 1 ? 0.95 : 0.4))
                                .frame(height: max(proxy.size.height * CGFloat(values[index] / peak), 2))
                                // Full-width pills turn into blobs in the wide labelled tile.
                                .frame(maxWidth: showLabels ? 14 : .infinity)
                        }
                    }
                    if showLabels {
                        Text(Self.weekday.string(from: day.date).uppercased())
                            .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
                .help("\(day.date.formatted(.dateTime.locale(Polish.locale).day().month(.wide))): \(AIUsageManager.money(day.cost)), \(AIUsageManager.tokens(day.tokens)) tokenów")
            }
        }
    }
}

// MARK: - Launcher

@MainActor
final class LauncherStore: ObservableObject {
    static let shared = LauncherStore()
    static let key = "extras.dev.launcher.apps"

    @Published private(set) var paths: [String]
    private var icons: [String: NSImage] = [:]

    private init() {
        paths = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
    }

    private func save() {
        UserDefaults.standard.set(paths, forKey: Self.key)
    }

    func name(of path: String) -> String {
        URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func icon(for path: String) -> NSImage? {
        // Checked before the cache: an app deleted since it was pinned must
        // stop looking clickable.
        guard exists(path) else { icons[path] = nil; return nil }
        if let cached = icons[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        icons[path] = image
        return image
    }

    func add(_ urls: [URL]) {
        var updated = paths
        for url in urls where !updated.contains(url.path) { updated.append(url.path) }
        guard updated != paths else { return }
        paths = updated
        save()
    }

    func remove(_ path: String) {
        paths.removeAll { $0 == path }
        icons[path] = nil
        save()
    }

    /// Moves `path` to the slot currently held by `target`.
    func move(_ path: String, before target: String) {
        guard path != target, let from = paths.firstIndex(of: path), let to = paths.firstIndex(of: target) else { return }
        var updated = paths
        updated.remove(at: from)
        updated.insert(path, at: to)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { paths = updated }
        save()
    }

    /// Preview renderer only: shows `paths` without saving them.
    func injectPreview(_ paths: [String]) {
        self.paths = paths
    }

    func open(_ path: String) {
        guard exists(path) else { return }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
    }

    /// Lets the user pick apps in /Applications. When asked from the notch,
    /// `viewModel` keeps it open: the file dialog takes the mouse away, and an
    /// open notch would otherwise close under it.
    func chooseApps(keeping viewModel: NotchViewModel? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Dodaj"
        panel.message = "Wybierz aplikacje do przypięcia w kafelku"

        let wasPinned = viewModel?.pinnedOpen ?? false
        viewModel?.pinnedOpen = true
        NSApp.activate(ignoringOtherApps: true)
        let result = panel.runModal()
        viewModel?.pinnedOpen = wasPinned
        guard result == .OK else { return }
        add(panel.urls)
    }
}

struct LauncherTile: View {
    let compact: Bool
    @EnvironmentObject private var viewModel: NotchViewModel
    @ObservedObject private var store = LauncherStore.shared
    @State private var dragging: String?

    var body: some View {
        Group {
            if store.paths.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: compact ? .leading : .topLeading)
        .padding(.vertical, compact ? 4 : 9)
    }

    private var emptyState: some View {
        Button {
            store.chooseApps(keeping: viewModel)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: "plus.app")
                    .font(.system(size: compact ? 15 : 22))
                    .foregroundStyle(.white.opacity(0.55))
                Text("Dodaj aplikacje")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Wybierz aplikacje do przypięcia")
    }

    private var grid: some View {
        let size: CGFloat = compact ? 26 : 34
        return Group {
            if compact {
                // One row that scrolls sideways: a second row would spill out of
                // the 46-point tile over its neighbours.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { gridItems(size: size) }
                        .frame(maxHeight: .infinity)
                }
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: size + 4, maximum: size + 8), spacing: 6)],
                        alignment: .leading,
                        spacing: 6
                    ) { gridItems(size: size) }
                }
            }
        }
    }

    @ViewBuilder
    private func gridItems(size: CGFloat) -> some View {
        ForEach(store.paths, id: \.self) { path in
            appButton(path, size: size)
        }
        Button {
            store.chooseApps(keeping: viewModel)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(.white.opacity(0.08)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Dodaj aplikację")
    }

    private func appButton(_ path: String, size: CGFloat) -> some View {
        let icon = store.icon(for: path)
        return Button {
            store.open(path)
        } label: {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    // Moved or uninstalled since it was pinned.
                    Image(systemName: "questionmark.app.dashed")
                        .font(.system(size: size * 0.7))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .frame(width: size, height: size)
            .opacity(dragging == path ? 0.35 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(icon == nil)
        .help(icon == nil ? "\(store.name(of: path)) — nie znaleziono aplikacji" : store.name(of: path))
        .contextMenu {
            Button("Pokaż w Finderze") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            .disabled(icon == nil)
            Button("Usuń z kafelka", role: .destructive) { store.remove(path) }
        }
        .onDrag {
            dragging = path
            // SwiftUI never says when a drag is cancelled by dropping outside
            // every target, which would leave this icon faded for good. The
            // mouse button coming up is the one reliable end of any drag.
            Task { @MainActor in
                while NSEvent.pressedMouseButtons & 1 != 0 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
                dragging = nil
            }
            return NSItemProvider(object: path as NSString)
        }
        .onDrop(of: [.text], delegate: LauncherDropDelegate(target: path, store: store, dragging: $dragging))
    }
}

/// Reorders live while a tile is dragged over its neighbours, so the grid
/// shows the result before the mouse is released.
private struct LauncherDropDelegate: DropDelegate {
    let target: String
    let store: LauncherStore
    @Binding var dragging: String?

    func dropEntered(info: DropInfo) {
        guard let dragging else { return }
        store.move(dragging, before: target)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
