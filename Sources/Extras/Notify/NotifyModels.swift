//
//  NotifyModels.swift
//  FunNotch
//
//  What the notification features pass around: one delivered notification, the
//  one-time-code finder, and the lookup that turns the app name a banner shows
//  ("Wiadomości") into an app we can open and an icon we can draw.
//

import AppKit
import Foundation

/// One delivered notification, as shown in the Powiadomienia tab.
struct MirroredNotification: Identifiable, Equatable {
    enum Source {
        /// Read off the banner while it was on screen.
        case banner
        /// Read from the Notification Center database.
        case database
    }

    let id: String
    var bundleIdentifier: String?
    var appName: String
    var title: String
    var subtitle: String
    var body: String
    var date: Date
    var source: Source
    /// A one-time code found in the text, if any.
    var code: String?

    /// The bold line of a row: the sender or subject, or the app when the
    /// notification has no title.
    var heading: String { title.isEmpty ? appName : title }

    /// Subtitle and body together, for the softer line under the heading.
    var detail: String {
        [subtitle, body].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Lowercased title and body without spacing differences, used to tell
    /// that a banner and a database row are the same notification.
    var fingerprint: String {
        let joined = [title, subtitle, body].joined(separator: "\u{1F}")
        return joined.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    var isMessages: Bool {
        NotifyAppDirectory.isMessages(bundleIdentifier: bundleIdentifier, name: appName)
    }
}

/// Finds a verification code in a notification: four to eight digits, close to
/// a word that says what the number is for.
enum OneTimeCode {
    private static let keywords = try? NSRegularExpression(
        pattern: #"\b(kod\w*|code\w*|weryfikac\w*|verif\w*|otp|pin|jednorazow\w*|autoryzac\w*|potwierdz\w*|has[łl]o|passcode|password|security)\b"#,
        options: [.caseInsensitive]
    )

    /// Digits that are not part of a longer number, a phone number or a date.
    private static let digits = try? NSRegularExpression(
        pattern: #"(?<!\d)(?<!\d[ -])(\d{3}[ -]\d{3}|\d{4,8})(?![ -]\d)(?!\d)"#
    )

    static func find(in text: String) -> String? {
        guard let keywords, let digits else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        let words = keywords.matches(in: text, range: range)
        guard !words.isEmpty else { return nil }

        var best: (code: String, distance: Int)?
        for match in digits.matches(in: text, range: range) {
            let code = (text as NSString).substring(with: match.range).filter(\.isNumber)
            guard (4 ... 8).contains(code.count) else { continue }
            // How far the number is from the nearest keyword, in characters.
            let distance = words.map { word -> Int in
                if match.range.location >= word.range.upperBound { return match.range.location - word.range.upperBound }
                return word.range.location - match.range.upperBound
            }.min() ?? Int.max
            if distance <= 60, distance < (best?.distance ?? Int.max) {
                best = (code, distance)
            }
        }
        return best?.code
    }
}

/// Resolves the application name a banner shows into something we can open.
@MainActor
final class NotifyAppDirectory {
    static let shared = NotifyAppDirectory()

    struct App {
        let name: String
        let bundleIdentifier: String?
        let url: URL?
    }

    /// Lowercased localized name → application, filled once in the background
    /// from the usual application folders.
    private var installed: [String: App] = [:]
    private var scanned = false
    private var iconCache: [String: NSImage] = [:]
    private var nameCache: [String: String] = [:]

    private init() {}

    nonisolated static func isMessages(bundleIdentifier: String?, name: String) -> Bool {
        if bundleIdentifier == "com.apple.MobileSMS" { return true }
        let lowered = name.lowercased()
        return lowered == "messages" || lowered == "wiadomości" || lowered == "wiadomosci"
    }

    /// Safe to call repeatedly: the folders are listed once.
    func prefetch() {
        guard !scanned else { return }
        scanned = true
        Task.detached(priority: .utility) {
            let found = Self.scanApplications()
            await MainActor.run { NotifyAppDirectory.shared.installed = found }
        }
    }

    nonisolated private static func scanApplications() -> [String: App] {
        let fileManager = FileManager.default
        var roots = [
            "/Applications", "/Applications/Utilities",
            "/System/Applications", "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications",
        ]
        // One level down covers folders such as /Applications/Setapp.
        for root in ["/Applications", NSHomeDirectory() + "/Applications"] {
            for entry in (try? fileManager.contentsOfDirectory(atPath: root)) ?? [] where !entry.hasSuffix(".app") {
                roots.append(root + "/" + entry)
            }
        }

        var result: [String: App] = [:]
        for root in roots {
            for entry in (try? fileManager.contentsOfDirectory(atPath: root)) ?? [] where entry.hasSuffix(".app") {
                let path = root + "/" + entry
                let url = URL(fileURLWithPath: path)
                let display = fileManager.displayName(atPath: path)
                let name = display.hasSuffix(".app") ? String(display.dropLast(4)) : display
                let identifier = Bundle(url: url)?.bundleIdentifier
                let app = App(name: name, bundleIdentifier: identifier, url: url)
                result[name.lowercased(), default: app] = app
                let plain = String(entry.dropLast(4)).lowercased()
                result[plain, default: app] = app
            }
        }
        return result
    }

    /// The app behind the name shown in a banner header.
    func resolve(name: String) -> App? {
        let lowered = name.lowercased()
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.activationPolicy != .prohibited && $0.localizedName?.lowercased() == lowered
        }) {
            return App(name: running.localizedName ?? name, bundleIdentifier: running.bundleIdentifier, url: running.bundleURL)
        }
        return installed[lowered]
    }

    func url(bundleIdentifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    /// The name Finder shows for a bundle identifier, e.g. "Wiadomości".
    func displayName(bundleIdentifier: String) -> String {
        if let cached = nameCache[bundleIdentifier] { return cached }
        let name: String
        if let url = url(bundleIdentifier: bundleIdentifier) {
            let display = FileManager.default.displayName(atPath: url.path)
            name = display.hasSuffix(".app") ? String(display.dropLast(4)) : display
        } else {
            // Not installed any more: the last component of the identifier is
            // the best readable thing left.
            name = bundleIdentifier.split(separator: ".").last.map(String.init) ?? bundleIdentifier
        }
        nameCache[bundleIdentifier] = name
        return name
    }

    func application(for item: MirroredNotification) -> URL? {
        if let identifier = item.bundleIdentifier, let url = url(bundleIdentifier: identifier) { return url }
        return resolve(name: item.appName)?.url
    }

    func icon(for item: MirroredNotification) -> NSImage? {
        let key = item.bundleIdentifier ?? "name:" + item.appName.lowercased()
        if let cached = iconCache[key] { return cached }
        guard let url = application(for: item) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[key] = image
        return image
    }
}
