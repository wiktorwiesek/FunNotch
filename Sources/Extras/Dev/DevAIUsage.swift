//
//  DevAIUsage.swift
//  FunNotch
//
//  How many tokens and dollars the coding agents have used today, read from
//  the session logs they already write: omp (~/.omp/agent/sessions) records a
//  `usage` block with its own cost on every assistant message, Claude Code
//  (~/.claude/projects) records token counts only.
//
//  The logs are big (a week of omp sessions is hundreds of MB) and appended
//  to constantly, so a scan never re-reads anything: each file's byte offset
//  is remembered and only the new complete lines are looked at, and only
//  lines that mention `"usage"` are decoded at all. All of it happens on one
//  background queue; the main actor only receives the finished numbers.
//
//  omp's logs repeat history when a session is forked or resumed, so omp
//  entries are de-duplicated by timestamp, model and size. Claude Code writes
//  one line per streamed chunk of a message, so those are de-duplicated by
//  message id, keeping the last (largest) one.
//

import AppKit
import Foundation
import SwiftUI

// MARK: - Snapshot

struct AIUsageProvider: Identifiable, Equatable {
    let name: String
    var tokens: Int
    var cost: Double
    var costIsEstimate: Bool
    var id: String { name }
}

struct AIUsageDay: Equatable {
    let date: Date
    var tokens: Int
    var cost: Double
}

struct AIUsageSnapshot: Equatable {
    /// Seven days, oldest first; the last one is today.
    var days: [AIUsageDay] = []
    /// Today's providers, biggest spender first.
    var providers: [AIUsageProvider] = []
    var scanned = Date.distantPast

    var todayTokens: Int { days.last?.tokens ?? 0 }
    var todayCost: Double { days.last?.cost ?? 0 }
    var todayIsEstimate: Bool { providers.contains { $0.costIsEstimate } }
}

// MARK: - Scanner

/// Owns every byte of state touched by scanning; all access is on `queue`.
private final class AIUsageScanner: @unchecked Sendable {
    struct Bucket {
        var tokens = 0
        var cost = 0.0
        var estimated = false
    }

    private struct UsageJSON: Decodable {
        struct Cost: Decodable { let total: Double? }
        // omp
        let input: Int?
        let output: Int?
        let cacheRead: Int?
        let cacheWrite: Int?
        let totalTokens: Int?
        let cost: Cost?
        // Claude Code
        let input_tokens: Int?
        let output_tokens: Int?
        let cache_read_input_tokens: Int?
        let cache_creation_input_tokens: Int?
        let cache_creation: CacheCreation?
        /// How much of the cache writes used the 1-hour cache, which costs
        /// twice the base input price instead of 1.25 times.
        struct CacheCreation: Decodable { let ephemeral_1h_input_tokens: Int? }
    }

    private struct MessageJSON: Decodable {
        let id: String?
        let role: String?
        let provider: String?
        let model: String?
        let timestamp: Int?
        let usage: UsageJSON?

        // omp messages carry `timestamp` as epoch milliseconds, Claude Code's
        // do not carry one; an unexpected type must not sink the whole line.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try? c.decode(String.self, forKey: .id)
            role = try? c.decode(String.self, forKey: .role)
            provider = try? c.decode(String.self, forKey: .provider)
            model = try? c.decode(String.self, forKey: .model)
            timestamp = try? c.decode(Int.self, forKey: .timestamp)
            usage = try? c.decode(UsageJSON.self, forKey: .usage)
        }

        enum CodingKeys: String, CodingKey { case id, role, provider, model, timestamp, usage }
    }

    private struct LineJSON: Decodable {
        let type: String?
        let timestamp: String?
        let provider: String?
        let model: String?
        let usage: UsageJSON?
        let message: MessageJSON?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try? c.decode(String.self, forKey: .type)
            timestamp = try? c.decode(String.self, forKey: .timestamp)
            provider = try? c.decode(String.self, forKey: .provider)
            model = try? c.decode(String.self, forKey: .model)
            usage = try? c.decode(UsageJSON.self, forKey: .usage)
            message = try? c.decode(MessageJSON.self, forKey: .message)
        }

        enum CodingKeys: String, CodingKey { case type, timestamp, provider, model, usage, message }
    }

    enum Source { case omp, claude }

    private let queue = DispatchQueue(label: "pl.funnotch.ai-usage", qos: .utility)
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private let calendar = Calendar.current
    private let dateParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let plainDateParser = ISO8601DateFormatter()
    private let usageNeedle = Data("\"usage\"".utf8)

    private var offsets: [String: UInt64] = [:]
    /// day (start of day, epoch seconds) → provider → totals.
    private var totals: [Int: [String: Bucket]] = [:]
    /// Dedup key -> day, so keys can be dropped once their day leaves the week
    /// (a bare set would grow for as long as the app runs).
    private var seenOmp: [String: Int] = [:]
    private var seenClaude: [String: (day: Int, provider: String, bucket: Bucket)] = [:]

    func scan(completion: @escaping @Sendable (AIUsageSnapshot) -> Void) {
        queue.async { [self] in
            let snapshot = performScan()
            completion(snapshot)
        }
    }

    private func performScan() -> AIUsageSnapshot {
        let today = calendar.startOfDay(for: Date())
        let cutoff = calendar.date(byAdding: .day, value: -6, to: today) ?? today

        for (root, source) in [(home.appendingPathComponent(".omp/agent/sessions"), Source.omp),
                               (home.appendingPathComponent(".claude/projects"), Source.claude)] {
            scanFiles(under: root, source: source, cutoff: cutoff)
        }

        // Forget days that have scrolled out of the week.
        let cutoffKey = Int(cutoff.timeIntervalSince1970)
        totals = totals.filter { $0.key >= cutoffKey }
        seenClaude = seenClaude.filter { $0.value.day >= cutoffKey }
        seenOmp = seenOmp.filter { $0.value >= cutoffKey }

        var days: [AIUsageDay] = []
        for offset in 0 ..< 7 {
            guard let date = calendar.date(byAdding: .day, value: offset, to: cutoff) else { continue }
            let buckets = totals[Int(date.timeIntervalSince1970)]?.values
            days.append(AIUsageDay(
                date: date,
                tokens: buckets?.reduce(0) { $0 + $1.tokens } ?? 0,
                cost: buckets?.reduce(0) { $0 + $1.cost } ?? 0
            ))
        }
        let todayProviders = (totals[Int(today.timeIntervalSince1970)] ?? [:]).map {
            AIUsageProvider(name: $0.key, tokens: $0.value.tokens, cost: $0.value.cost, costIsEstimate: $0.value.estimated)
        }.sorted { ($0.cost, $0.tokens) > ($1.cost, $1.tokens) }
        return AIUsageSnapshot(days: days, providers: todayProviders, scanned: Date())
    }

    private func scanFiles(under root: URL, source: Source, cutoff: Date) {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  let size = values.fileSize
            else { continue }
            // A file untouched for a week has nothing in the window.
            guard modified >= cutoff else { continue }

            let path = url.path
            // A file that shrank was rewritten, so its old offset means nothing
            // (the de-duplication keeps a second read from double counting).
            let known = offsets[path] ?? 0
            let start = UInt64(size) < known ? 0 : known
            guard UInt64(size) > start else { continue }
            offsets[path] = readNewLines(in: url, from: start, source: source)
        }
    }

    /// Reads from `offset` to the end in chunks and returns the offset just
    /// past the last complete line. A line still being written is left for
    /// the next scan rather than decoded half-finished.
    private func readNewLines(in url: URL, from offset: UInt64, source: Source) -> UInt64 {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return offset }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: offset) } catch { return offset }

        var consumed = offset
        var carry = Data()
        while let chunk = try? handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            carry.append(chunk)
            guard let lastNewline = carry.lastIndex(of: 0x0A) else { continue }
            let complete = carry[carry.startIndex ... lastNewline]
            for line in complete.split(separator: 0x0A, omittingEmptySubsequences: true) {
                process(line: Data(line), source: source)
            }
            consumed += UInt64(complete.count)
            carry = Data(carry[(lastNewline + 1)...])
        }
        return consumed
    }

    private func process(line: Data, source: Source) {
        guard line.range(of: usageNeedle) != nil,
              let parsed = try? JSONDecoder().decode(LineJSON.self, from: line),
              let when = date(of: parsed.timestamp)
        else { return }
        let day = Int(calendar.startOfDay(for: when).timeIntervalSince1970)

        switch source {
        case .omp:
            // Either a model_usage record (side calls like titles) or an
            // assistant message; tool results carry a usage block too, but
            // that is already counted where the work was done.
            let usage: UsageJSON?, provider: String?, model: String?, stamp: String
            if parsed.type == "model_usage" {
                (usage, provider, model, stamp) = (parsed.usage, parsed.provider, parsed.model, parsed.timestamp ?? "")
            } else if parsed.type == "message", parsed.message?.role == "assistant" {
                let message = parsed.message
                (usage, provider, model) = (message?.usage, message?.provider, message?.model)
                stamp = message?.timestamp.map(String.init) ?? parsed.timestamp ?? ""
            } else {
                return
            }
            guard let usage else { return }
            let tokens = usage.totalTokens
                ?? (usage.input ?? 0) + (usage.output ?? 0) + (usage.cacheRead ?? 0) + (usage.cacheWrite ?? 0)
            let cost = usage.cost?.total ?? 0
            guard tokens > 0 || cost > 0 else { return }
            let key = "\(stamp)|\(model ?? "")|\(tokens)|\(cost)"
            guard seenOmp.updateValue(day, forKey: key) == nil else { return }
            add(Bucket(tokens: tokens, cost: cost), day: day, provider: provider ?? "inne")

        case .claude:
            guard parsed.type == "assistant", let message = parsed.message, let usage = message.usage,
                  let id = message.id
            else { return }
            let tokens = (usage.input_tokens ?? 0) + (usage.output_tokens ?? 0)
                + (usage.cache_read_input_tokens ?? 0) + (usage.cache_creation_input_tokens ?? 0)
            guard tokens > 0 else { return }
            var bucket = Bucket(tokens: tokens)
            if let rate = Self.rate(for: message.model ?? "") {
                let written = usage.cache_creation_input_tokens ?? 0
                let writtenForAnHour = min(usage.cache_creation?.ephemeral_1h_input_tokens ?? 0, written)
                bucket.cost = (Double(usage.input_tokens ?? 0) * rate.input
                    + Double(usage.output_tokens ?? 0) * rate.output
                    + Double(usage.cache_read_input_tokens ?? 0) * rate.cacheRead
                    + Double(written - writtenForAnHour) * rate.cacheWrite
                    + Double(writtenForAnHour) * rate.input * 2) / 1_000_000
                bucket.estimated = true
            }
            // A repeat of a message already seen replaces it: the streamed
            // chunks differ only in how many output tokens had arrived.
            if let previous = seenClaude[id] {
                guard bucket.tokens > previous.bucket.tokens else { return }
                subtract(previous.bucket, day: previous.day, provider: previous.provider)
            }
            seenClaude[id] = (day, "claude-code", bucket)
            add(bucket, day: day, provider: "claude-code")
        }
    }

    private func add(_ bucket: Bucket, day: Int, provider: String) {
        var entry = totals[day, default: [:]][provider, default: Bucket()]
        entry.tokens += bucket.tokens
        entry.cost += bucket.cost
        entry.estimated = entry.estimated || bucket.estimated
        totals[day, default: [:]][provider] = entry
    }

    private func subtract(_ bucket: Bucket, day: Int, provider: String) {
        guard var entry = totals[day]?[provider] else { return }
        entry.tokens -= bucket.tokens
        entry.cost -= bucket.cost
        totals[day]?[provider] = entry
    }

    private func date(of text: String?) -> Date? {
        guard let text else { return nil }
        return dateParser.date(from: text) ?? plainDateParser.date(from: text)
    }

    /// USD per million tokens, from Anthropic's public price list, for the one
    /// source that logs no cost. Models not recognised get no estimate rather
    /// than a guess.
    private struct Rate { let input: Double, output: Double, cacheRead: Double, cacheWrite: Double }

    private static func rate(for model: String) -> Rate? {
        let name = model.lowercased()
        // Opus 4 and 4.1 were priced three times higher than Opus 4.5 onward.
        if name.contains("opus-4-1") || name.contains("opus-4-2025") || name.contains("opus-4-0") || name.contains("3-opus") {
            return Rate(input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75)
        }
        if name.contains("opus") { return Rate(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25) }
        if name.contains("sonnet") { return Rate(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75) }
        if name.contains("haiku") { return Rate(input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25) }
        return nil
    }
}

// MARK: - Manager

@MainActor
final class AIUsageManager: ObservableObject {
    static let shared = AIUsageManager()

    static let alertKey = "extras.dev.ai.alertUSD"
    private static let alertedDayKey = "extras.dev.ai.alertedDay"

    @Published private(set) var snapshot = AIUsageSnapshot()
    @Published private(set) var hasScanned = false

    private let scanner = AIUsageScanner()
    private var subscribers = 0
    private var timer: Timer?
    private var scanning = false
    private var announceWhenScanned = false

    private init() {}

    /// Daily limit in USD; 0 means no alert.
    var alertThreshold: Double {
        UserDefaults.standard.double(forKey: Self.alertKey)
    }

    /// Safe to call repeatedly: one timer. It only runs while something needs
    /// it (a visible tile or an alert threshold), so an unused feature costs
    /// no wakeups.
    func start() {
        guard timer == nil, subscribers > 0 || alertThreshold > 0 else { return }
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // Cheap enough to do once at launch, and it means the first look at
        // the tile is not an empty box while the week is read.
        if alertThreshold > 0 { refresh() }
    }

    /// Drops the timer when neither a tile nor a threshold needs it.
    func stopIfIdle() {
        guard subscribers == 0, alertThreshold <= 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    func addSubscriber() {
        subscribers += 1
        start()
        if snapshot.scanned.timeIntervalSinceNow < -10 { refresh() }
    }

    func removeSubscriber() {
        subscribers = max(subscribers - 1, 0)
        stopIfIdle()
    }

    /// Preview renderer only: shows `snapshot` as if it had just been scanned.
    func injectPreview(_ snapshot: AIUsageSnapshot) {
        self.snapshot = snapshot
        hasScanned = true
    }

    /// Visible: look every 15 s. Not visible: only look every two minutes,
    /// and only when there is a threshold to watch.
    private func tick() {
        let age = -snapshot.scanned.timeIntervalSinceNow
        if subscribers > 0 {
            refresh()
        } else if alertThreshold > 0, age > 110 {
            refresh()
        }
    }

    func refresh() {
        guard !scanning else { return }
        scanning = true
        scanner.scan { [weak self] snapshot in
            Task { @MainActor in
                guard let self else { return }
                self.scanning = false
                self.hasScanned = true
                if self.snapshot != snapshot { self.snapshot = snapshot }
                self.checkThreshold()
                if self.announceWhenScanned {
                    self.announceWhenScanned = false
                    self.postToday()
                }
            }
        }
    }

    /// Puts today's total in the notch, from a fresh scan.
    func announceToday() {
        announceWhenScanned = true
        refresh()
    }

    private func postToday() {
        let providers = snapshot.providers.prefix(2)
            .map { AIUsageManager.providerName($0.name) }
            .joined(separator: ", ")
        IslandCenter.shared.post(Island(
            symbol: "sparkles",
            tint: SettingsStyle.orange,
            title: "Zużycie AI dziś",
            detail: providers.isEmpty ? " · jeszcze nic" : " · " + providers,
            trailing: (snapshot.todayIsEstimate ? "~" : "") + Self.money(snapshot.todayCost),
            duration: 5
        ))
    }

    private func checkThreshold() {
        let limit = alertThreshold
        guard limit > 0, snapshot.todayCost >= limit else { return }
        let key = Self.dayKey(Date())
        guard UserDefaults.standard.string(forKey: Self.alertedDayKey) != key else { return }
        UserDefaults.standard.set(key, forKey: Self.alertedDayKey)
        IslandCenter.shared.post(Island(
            symbol: "dollarsign.circle.fill",
            tint: SettingsStyle.orange,
            title: "Zużycie AI",
            detail: " · dziś przekroczono \(Self.money(limit))",
            trailing: Self.money(snapshot.todayCost),
            duration: 6
        ))
    }

    private static func dayKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }

    // MARK: Formatting

    private static let decimal: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Polish.locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    /// "$12,34".
    static func money(_ value: Double) -> String {
        "$" + (decimal.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value))
    }

    /// "812", "14 tys.", "4,2 mln".
    static func tokens(_ value: Int) -> String {
        switch value {
        case ..<1_000: return "\(value)"
        // 999 500 and up would round to "1000 tys."; that is "1,0 mln".
        case ..<999_500: return "\(Int((Double(value) / 1_000).rounded())) tys."
        default:
            let millions = Double(value) / 1_000_000
            let text = String(format: millions >= 100 ? "%.0f" : "%.1f", millions)
                .replacingOccurrences(of: ".", with: ",")
            return "\(text) mln"
        }
    }

    static func providerName(_ raw: String) -> String {
        switch raw {
        case "anthropic": return "Anthropic"
        case "claude-code": return "Claude Code"
        case "openai": return "OpenAI"
        case "openai-codex": return "OpenAI Codex"
        case "openrouter": return "OpenRouter"
        case "kimi": return "Kimi"
        case "google": return "Google"
        default: return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }

    /// A one-line summary for the palette and settings.
    var summaryLine: String {
        guard hasScanned else { return "Liczenie…" }
        let prefix = snapshot.todayIsEstimate ? "ok. " : ""
        return "\(prefix)\(Self.money(snapshot.todayCost)) · \(Self.tokens(snapshot.todayTokens)) tokenów"
    }
}
