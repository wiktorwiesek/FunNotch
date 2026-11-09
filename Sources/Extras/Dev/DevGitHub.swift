//
//  DevGitHub.swift
//  FunNotch
//
//  CI status and pull requests, read through the `gh` command line tool that
//  is already logged in on this Mac — so Fun Notch never sees a token and
//  needs no OAuth app of its own.
//
//  For each configured repository it asks for the latest workflow run on the
//  default branch, the open PRs waiting for the user's review and the open
//  PRs the user wrote. It polls every two minutes, but only while a tile is
//  on screen (subscribers) — plus a lighter CI-only check in the background,
//  because "main just went red" is only worth anything if it reaches you
//  while the notch is closed.
//

import AppKit
import Foundation
import SwiftUI

// MARK: - gh process

/// Finds and runs `gh`. A GUI app inherits a minimal PATH that does not
/// include Homebrew, so the usual install locations are tried before PATH.
enum GitHubCLI {
    struct Failure: Error {
        let message: String
        /// True when the problem is "not logged in" rather than a one-off.
        var needsLogin = false
    }

    /// Filled by two reader threads and read only after both have finished.
    private final class OutputBox: @unchecked Sendable {
        var out = Data()
        var err = Data()
    }

    nonisolated(unsafe) private static var cachedPath: String??
    private static let lock = NSLock()

    private static func lookup() -> String?? {
        lock.lock()
        defer { lock.unlock() }
        return cachedPath
    }

    private static func remember(_ path: String?) {
        lock.lock()
        defer { lock.unlock() }
        cachedPath = .some(path)
    }

    static func locate() async -> String? {
        if let cached = lookup() { return cached }

        var candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh",
                          NSHomeDirectory() + "/.local/bin/gh"]
        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        candidates += pathDirectories.map { "\($0)/gh" }
        var found = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        if found == nil {
            // The login shell knows PATH entries the app does not (asdf, mise…).
            if let output = try? await run("/bin/zsh", ["-lc", "command -v gh"], timeout: 8),
               let line = String(data: output, encoding: .utf8)?
                .split(separator: "\n").last.map(String.init),
               FileManager.default.isExecutableFile(atPath: line) {
                found = line
            }
        }
        remember(found)
        return found
    }

    static func forgetLocation() {
        lock.lock()
        cachedPath = nil
        lock.unlock()
    }

    static func gh(_ arguments: [String]) async throws -> Data {
        guard let path = await locate() else {
            throw Failure(message: "Nie znaleziono polecenia gh. Zainstaluj je: brew install gh")
        }
        return try await run(path, arguments, timeout: 25)
    }

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
            environment["GH_PROMPT_DISABLED"] = "1"
            environment["GH_NO_UPDATE_NOTIFIER"] = "1"
            environment["GH_SPINNER_DISABLED"] = "1"
            environment["NO_COLOR"] = "1"
            process.environment = environment
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: Failure(message: "Nie udało się uruchomić gh: \(error.localizedDescription)"))
                return
            }

            // Drain both pipes while the process runs: a full pipe buffer
            // would otherwise block it forever.
            let box = OutputBox()
            let group = DispatchGroup()
            let collect = DispatchQueue(label: "pl.funnotch.gh.collect", attributes: .concurrent)
            group.enter()
            collect.async { box.out = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            group.enter()
            collect.async { box.err = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            nonisolated(unsafe) let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

            DispatchQueue.global().async {
                process.waitUntilExit()
                killer.cancel()
                group.wait()
                if process.terminationStatus == 0 {
                    continuation.resume(returning: box.out)
                    return
                }
                let message = String(data: box.err, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let lowered = message.lowercased()
                let needsLogin = lowered.contains("gh auth login") || lowered.contains("not logged in")
                    || lowered.contains("authentication") && lowered.contains("token")
                continuation.resume(throwing: Failure(
                    message: needsLogin
                        ? "gh nie jest zalogowane. Uruchom w terminalu: gh auth login"
                        : String(message.split(separator: "\n").first ?? "gh zakończyło się błędem"),
                    needsLogin: needsLogin
                ))
            }
        }
    }
}

// MARK: - Model

struct GitHubPullRequest: Identifiable, Equatable {
    let number: Int
    let title: String
    let url: URL
    let author: String
    let isDraft: Bool
    var id: Int { number }
}

struct GitHubRun: Equatable {
    enum State { case running, success, failure, cancelled, other }

    let id: Int
    let status: String
    let conclusion: String
    let title: String
    let workflow: String
    let url: URL

    var isFinished: Bool { status == "completed" }

    var state: State {
        guard isFinished else { return .running }
        switch conclusion {
        case "success": return .success
        case "failure", "timed_out", "startup_failure", "action_required": return .failure
        case "cancelled": return .cancelled
        default: return .other
        }
    }
}

struct GitHubRepoStatus: Identifiable, Equatable {
    let slug: String
    var branch: String = ""
    var run: GitHubRun?
    var reviewRequests: [GitHubPullRequest] = []
    var authored: [GitHubPullRequest] = []
    var error: String?
    /// False until the pull request lists have been fetched at least once;
    /// the background check only learns about CI.
    var hasPullRequests = false

    var id: String { slug }
    var name: String { String(slug.split(separator: "/").last ?? Substring(slug)) }
    var webURL: URL { URL(string: "https://github.com/\(slug)")! }
    var actionsURL: URL { webURL.appendingPathComponent("actions") }

    var reviewURL: URL {
        URL(string: "https://github.com/\(slug)/pulls?q=is%3Aopen+is%3Apr+review-requested%3A%40me")!
    }

    var authoredURL: URL {
        URL(string: "https://github.com/\(slug)/pulls?q=is%3Aopen+is%3Apr+author%3A%40me")!
    }
}

// MARK: - Manager

@MainActor
final class GitHubManager: ObservableObject {
    static let shared = GitHubManager()

    static let reposKey = "extras.dev.github.repos"
    static let ciIslandsKey = "extras.dev.github.ciIslands"
    /// Used when no repositories are configured: this one's `origin` remote.
    static let defaultCheckout = NSHomeDirectory() + "/Developer/project"

    enum Phase: Equatable {
        case idle
        case loading
        case ready
        /// gh missing, not logged in, or no repository to look at.
        case unavailable(String)
    }

    @Published private(set) var repos: [GitHubRepoStatus] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastUpdate: Date?

    private var subscribers = 0
    private var timer: Timer?
    private var refreshing = false
    private var defaultBranches: [String: String] = [:]
    private var detectedDefault: String?
    /// The last run seen per repository, to notice one that has just finished.
    private var lastSeen: [String: GitHubRun] = [:]

    private init() {}

    var configuredSlugs: [String] {
        let raw = UserDefaults.standard.string(forKey: Self.reposKey) ?? ""
        return raw.split(whereSeparator: { ",;\n ".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .compactMap(Self.normalize)
    }

    var watchesInBackground: Bool {
        UserDefaults.standard.object(forKey: Self.ciIslandsKey) as? Bool ?? true
    }

    /// Safe to call repeatedly: one timer, and it ticks cheaply.
    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // First look a little after launch, so it does not compete with the
        // rest of startup.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.tick() }
    }

    func addSubscriber() {
        subscribers += 1
        start()
        // Opening the notch should show something current, not what was true
        // two minutes ago.
        if lastUpdate.map({ Date().timeIntervalSince($0) > 15 }) ?? true {
            Task { await refresh(full: true) }
        }
    }

    func removeSubscriber() {
        subscribers = max(subscribers - 1, 0)
    }

    private func tick() {
        if subscribers > 0 {
            Task { await refresh(full: true) }
        } else if watchesInBackground, Self.layoutsContainTile() {
            Task { await refresh(full: false) }
        }
    }

    /// Whether any home layout has a GitHub tile; without one the background
    /// check has nobody to tell.
    private static func layoutsContainTile() -> Bool {
        LayoutCase.allCases.contains { layoutCase in
            Settings.shared.homeTiles(for: layoutCase)?.contains { $0.kind == .github } ?? false
        }
    }

    func reloadConfiguration() {
        defaultBranches.removeAll()
        lastSeen.removeAll()
        GitHubCLI.forgetLocation()
        Task { await refresh(full: true) }
    }

    // MARK: Refresh

    func refresh(full: Bool) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        if repos.isEmpty { phase = .loading }

        guard await GitHubCLI.locate() != nil else {
            phase = .unavailable("Nie znaleziono polecenia gh. Zainstaluj je: brew install gh")
            return
        }
        var slugs = configuredSlugs
        if slugs.isEmpty {
            if detectedDefault == nil { detectedDefault = await Self.detectOrigin(of: Self.defaultCheckout) }
            if let detectedDefault { slugs = [detectedDefault] }
        }
        guard !slugs.isEmpty else {
            repos = []
            phase = .unavailable("Dodaj repozytorium w ustawieniach (Dodatki > GitHub).")
            return
        }

        var loginProblem: String?
        var results: [GitHubRepoStatus] = []
        let previous = Dictionary(uniqueKeysWithValues: repos.map { ($0.slug, $0) })
        for slug in slugs {
            var status = previous[slug] ?? GitHubRepoStatus(slug: slug)
            do {
                try await load(&status, full: full)
                status.error = nil
            } catch let failure as GitHubCLI.Failure {
                status.error = failure.message
                if failure.needsLogin { loginProblem = failure.message }
            } catch {
                status.error = error.localizedDescription
            }
            results.append(status)
        }
        repos = results
        lastUpdate = Date()
        phase = loginProblem.map { .unavailable($0) } ?? .ready
        for status in results { announceIfFinished(status) }
    }

    private struct RunJSON: Decodable {
        let databaseId: Int
        let status: String
        let conclusion: String?
        let displayTitle: String
        let workflowName: String
        let url: String
    }

    private struct PullJSON: Decodable {
        struct Author: Decodable { let login: String }
        let number: Int
        let title: String
        let url: String
        let author: Author?
        let isDraft: Bool
    }

    private struct RepoJSON: Decodable {
        struct Branch: Decodable { let name: String }
        let defaultBranchRef: Branch?
    }

    private func load(_ status: inout GitHubRepoStatus, full: Bool) async throws {
        let slug = status.slug
        var branch = defaultBranches[slug]
        if branch == nil {
            let data = try await GitHubCLI.gh(["repo", "view", slug, "--json", "defaultBranchRef"])
            guard let name = (try? JSONDecoder().decode(RepoJSON.self, from: data))?.defaultBranchRef?.name else {
                throw GitHubCLI.Failure(message: "Nie znaleziono domyślnej gałęzi \(slug).")
            }
            defaultBranches[slug] = name
            branch = name
        }
        status.branch = branch ?? ""

        let pullFields = "number,title,url,author,isDraft"
        let branchName = status.branch
        async let runData = GitHubCLI.gh([
            "run", "list", "-R", slug, "--branch", branchName, "--limit", "1",
            "--json", "databaseId,status,conclusion,displayTitle,workflowName,url",
        ])
        async let reviewData: Data? = full
            ? GitHubCLI.gh(["pr", "list", "-R", slug, "--state", "open", "--search", "review-requested:@me",
                            "--limit", "20", "--json", pullFields])
            : nil
        async let authoredData: Data? = full
            ? GitHubCLI.gh(["pr", "list", "-R", slug, "--state", "open", "--author", "@me",
                            "--limit", "20", "--json", pullFields])
            : nil

        let runBytes = try await runData
        let runs = (try? JSONDecoder().decode([RunJSON].self, from: runBytes)) ?? []
        status.run = runs.first.flatMap { item in
            URL(string: item.url).map {
                GitHubRun(id: item.databaseId, status: item.status, conclusion: item.conclusion ?? "",
                          title: item.displayTitle, workflow: item.workflowName, url: $0)
            }
        }
        if full {
            if let data = try await reviewData { status.reviewRequests = Self.pulls(from: data) }
            if let data = try await authoredData { status.authored = Self.pulls(from: data) }
            status.hasPullRequests = true
        }
    }

    private static func pulls(from data: Data) -> [GitHubPullRequest] {
        ((try? JSONDecoder().decode([PullJSON].self, from: data)) ?? []).compactMap { item in
            URL(string: item.url).map {
                GitHubPullRequest(number: item.number, title: item.title, url: $0,
                                  author: item.author?.login ?? "", isDraft: item.isDraft)
            }
        }
    }

    // MARK: Island

    /// An island when a run that was still going last time is now over, or a
    /// newer run has appeared already finished. The first look after launch
    /// only records the state: announcing yesterday's result would be noise.
    private func announceIfFinished(_ status: GitHubRepoStatus) {
        defer { if let run = status.run { lastSeen[status.slug] = run } }
        guard let run = status.run, run.isFinished, let before = lastSeen[status.slug] else { return }
        guard run.id != before.id || !before.isFinished else { return }

        let symbol: String, tint: Color, detail: String
        switch run.state {
        case .success:
            (symbol, tint, detail) = ("checkmark.circle.fill", SettingsStyle.green, " · CI na \(status.branch) przeszło")
        case .failure:
            (symbol, tint, detail) = ("xmark.octagon.fill", SettingsStyle.red, " · CI na \(status.branch) nie przeszło")
        case .cancelled:
            (symbol, tint, detail) = ("slash.circle.fill", SettingsStyle.gray, " · CI na \(status.branch) anulowane")
        default:
            (symbol, tint, detail) = ("circle.dashed", SettingsStyle.gray, " · CI na \(status.branch) zakończone")
        }
        let url = run.url
        IslandCenter.shared.post(Island(
            symbol: symbol, tint: tint, title: status.name, detail: detail,
            action: IslandAction(title: "Otwórz") { NSWorkspace.shared.open(url) },
            duration: 6
        ))
    }

    // MARK: Helpers

    /// "owner/name" from a slug or any GitHub URL.
    static func normalize(_ text: String) -> String? {
        var value = text
        for prefix in ["https://github.com/", "http://github.com/", "git@github.com:", "ssh://git@github.com/"]
            where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
        }
        if value.hasSuffix(".git") { value = String(value.dropLast(4)) }
        let parts = value.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    private static func detectOrigin(of checkout: String) async -> String? {
        guard FileManager.default.fileExists(atPath: checkout + "/.git") else { return nil }
        guard let data = try? await GitHubCLI.run("/usr/bin/git", ["-C", checkout, "remote", "get-url", "origin"], timeout: 8),
              let url = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        return normalize(url)
    }

    /// The Actions page of Project: the configured repository of that
    /// name, otherwise the `origin` of the local checkout. For the palette.
    func projectActionsURL() async -> URL? {
        var slug = configuredSlugs.first { $0.lowercased().hasSuffix("/project") }
        if slug == nil {
            if detectedDefault == nil { detectedDefault = await Self.detectOrigin(of: Self.defaultCheckout) }
            slug = detectedDefault
        }
        return slug.flatMap { URL(string: "https://github.com/\($0)/actions") }
    }
}
