//
//  ClipboardSmart.swift
//  FunNotch
//
//  Recognises what a copied piece of text is (link, colour, e-mail, phone,
//  EAN-13, NIP, long text) and offers the actions that make sense for it.
//

import AppKit
import SwiftUI

struct ClipboardColor: Equatable {
    let red: Int
    let green: Int
    let blue: Int
    let alpha: Double

    var hex: String {
        let base = String(format: "#%02X%02X%02X", red, green, blue)
        return alpha < 1 ? base + String(format: "%02X", Int((alpha * 255).rounded())) : base
    }

    var rgb: String {
        guard alpha < 1 else { return "rgb(\(red), \(green), \(blue))" }
        var value = String(format: "%.2f", alpha)
        while value.hasSuffix("0") { value.removeLast() }
        if value.hasSuffix(".") { value.removeLast() }
        return "rgba(\(red), \(green), \(blue), \(value))"
    }

    var swiftUIColor: Color {
        Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255, opacity: alpha)
    }
}

enum ClipboardSmartKind: Equatable {
    case url(URL)
    case color(ClipboardColor)
    case email(String)
    /// Dialable form, e.g. "+48600100200".
    case phone(String)
    case ean(String)
    /// Ten digits, no separators.
    case nip(String)
    case longText(characters: Int, words: Int)
    case plain

    var symbol: String {
        switch self {
        case .url: return "link"
        case .color: return "eyedropper"
        case .email: return "envelope"
        case .phone: return "phone"
        case .ean: return "barcode"
        case .nip: return "building.2"
        case .longText, .plain: return "text.alignleft"
        }
    }
}

struct ClipboardSmartAction: Identifiable {
    let id: String
    let title: String
    let symbol: String
    /// True when the action writes to the pasteboard, so the tile can confirm it.
    var copies = false
    let perform: @MainActor () -> Void
}

enum ClipboardSmart {
    private final class Box {
        let kind: ClipboardSmartKind
        init(_ kind: ClipboardSmartKind) { self.kind = kind }
    }

    /// Detection runs for every visible tile on every redraw, and the regexes
    /// are not free, so the verdict for a given text is remembered.
    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 400
        return cache
    }()

    static func kind(for text: String) -> ClipboardSmartKind {
        guard ShelfClipPrefs.smartActions else { return .plain }
        let key = text as NSString
        if let hit = cache.object(forKey: key) { return hit.kind }
        let kind = detect(text)
        cache.setObject(Box(kind), forKey: key)
        return kind
    }

    // MARK: - Detection

    static func detect(_ text: String) -> ClipboardSmartKind {
        // A pasted log or CSV runs to megabytes. Tiles are drawn on main for every
        // redraw, so skip the trims and regexes and just count in a single pass.
        // `utf8.count` is O(1), unlike `count`.
        if text.utf8.count > 4_000 { return longTextSummary(text) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .plain }

        let singleLine = !trimmed.contains(where: \.isNewline)
        if singleLine, trimmed.count <= 300 {
            if let color = parseColor(trimmed) { return .color(color) }
            if let url = parseURL(trimmed) { return .url(url) }
            if matches(trimmed, "^[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}$") { return .email(trimmed) }
            // Check/identifier numbers go before phone: a valid 10-digit NIP
            // would otherwise be mistaken for a number to dial.
            if let ean = parseEAN(trimmed) { return .ean(ean) }
            if let nip = parseNIP(trimmed) { return .nip(nip) }
            if let phone = parsePhone(trimmed) { return .phone(phone) }
        } else if singleLine, trimmed.count <= 2_048, let url = parseURL(trimmed) {
            // Tracking and share links often run past 300 characters.
            return .url(url)
        }

        let lines = trimmed.split(whereSeparator: \.isNewline).count
        if trimmed.count >= 140 || (lines >= 4 && trimmed.count >= 60) {
            let words = trimmed.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
            return .longText(characters: trimmed.count, words: words)
        }
        return .plain
    }

    /// One pass over the scalars: count what the tile shows, nothing else.
    private static func longTextSummary(_ text: String) -> ClipboardSmartKind {
        var characters = 0
        var words = 0
        var inWord = false
        // Whitespace is only counted once more text follows it, so leading and
        // trailing runs are left out, as trimming would leave them.
        var pending = 0
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                pending += 1
                inWord = false
            } else {
                if characters > 0 { characters += pending }
                pending = 0
                characters += 1
                if !inWord {
                    words += 1
                    inWord = true
                }
            }
        }
        return words == 0 ? .plain : .longText(characters: characters, words: words)
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func parseColor(_ text: String) -> ClipboardColor? {
        if matches(text, "^#([0-9A-Fa-f]{3,4}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$") {
            var digits = Array(text.dropFirst())
            // "#1234" or "#404" is an order number or an issue reference far more
            // often than a colour; shorthand needs at least one letter digit.
            if digits.count <= 4, !digits.contains(where: { $0.isLetter }) { return nil }
            // #RGB and #RGBA are shorthand for doubled digits.
            if digits.count <= 4 { digits = digits.flatMap { [$0, $0] } }
            func byte(_ index: Int) -> Int {
                Int(String(digits[index * 2 ... index * 2 + 1]), radix: 16) ?? 0
            }
            let alpha = digits.count == 8 ? Double(byte(3)) / 255 : 1
            return ClipboardColor(red: byte(0), green: byte(1), blue: byte(2), alpha: alpha)
        }

        let pattern = "^rgba?\\(\\s*(\\d{1,3})\\s*[, ]\\s*(\\d{1,3})\\s*[, ]\\s*(\\d{1,3})\\s*(?:[,/]\\s*(\\d*\\.?\\d+%?))?\\s*\\)$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }

        func group(_ index: Int) -> String? {
            let range = match.range(at: index)
            return Range(range, in: text).map { String(text[$0]) }
        }
        guard let red = group(1).flatMap({ Int($0) }),
              let green = group(2).flatMap({ Int($0) }),
              let blue = group(3).flatMap({ Int($0) }),
              (0 ... 255).contains(red), (0 ... 255).contains(green), (0 ... 255).contains(blue)
        else { return nil }

        var alpha = 1.0
        if let raw = group(4) {
            if raw.hasSuffix("%") {
                alpha = (Double(raw.dropLast()) ?? 100) / 100
            } else {
                alpha = Double(raw) ?? 1
            }
        }
        return ClipboardColor(red: red, green: green, blue: blue, alpha: min(max(alpha, 0), 1))
    }

    private static func parseURL(_ text: String) -> URL? {
        guard !text.contains(where: \.isWhitespace) else { return nil }
        let candidate = text.lowercased().hasPrefix("www.") ? "https://" + text : text
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, host.contains(".") || host == "localhost"
        else { return nil }
        return url
    }

    private static func parseEAN(_ text: String) -> String? {
        guard matches(text, "^\\d{13}$") else { return nil }
        let digits = text.compactMap(\.wholeNumberValue)
        let sum = digits.prefix(12).enumerated().reduce(0) { $0 + $1.element * ($1.offset % 2 == 0 ? 1 : 3) }
        return (10 - sum % 10) % 10 == digits[12] ? text : nil
    }

    private static func parseNIP(_ text: String) -> String? {
        guard matches(text, "^(?:PL\\s?|NIP[:\\s]*)?\\d{3}[-\\s]?\\d{3}[-\\s]?\\d{2}[-\\s]?\\d{2}$")
            || matches(text, "^(?:PL\\s?|NIP[:\\s]*)?\\d{3}[-\\s]?\\d{2}[-\\s]?\\d{2}[-\\s]?\\d{3}$")
        else { return nil }
        let digits = text.compactMap(\.wholeNumberValue)
        guard digits.count == 10 else { return nil }
        let weights = [6, 5, 7, 2, 3, 4, 5, 6, 7]
        let sum = zip(digits.prefix(9), weights).reduce(0) { $0 + $1.0 * $1.1 }
        // A remainder of 10 can never match a single check digit: not a NIP.
        guard sum % 11 == digits[9] else { return nil }
        return digits.map(String.init).joined()
    }

    private static func parsePhone(_ text: String) -> String? {
        // A leading "(22)" is the usual way to write a Polish area code.
        guard matches(text, "^(?:\\+?\\d[\\d\\s\\-().]{7,18}\\d|\\(\\d{2}\\)\\s?\\d[\\d\\s\\-]{5,12}\\d)$") else { return nil }
        let hasPlus = text.hasPrefix("+")
        let digits = String(text.filter(\.isNumber))
        // A decimal such as "3.14159265" has the digit count of a phone number
        // but is not one: dots only count as separators in international form.
        if !hasPlus, !digits.hasPrefix("00"), text.contains(".") { return nil }
        switch digits.count {
        case 9 where !hasPlus:
            return "+48" + digits
        case 11 where !hasPlus && digits.hasPrefix("48"):
            // Polish numbers never start with 0, and a PESEL born in 1948 looks
            // exactly like "48" plus nine digits.
            if digits.dropFirst(2).hasPrefix("0") || isPESEL(digits) { return nil }
            return "+" + digits
        case 10 ... 15 where !hasPlus && digits.hasPrefix("00"):
            return "+" + digits.dropFirst(2)
        case 8 ... 15 where hasPlus:
            return "+" + digits
        default:
            return nil
        }
    }

    private static func isPESEL(_ digits: String) -> Bool {
        let values = digits.compactMap(\.wholeNumberValue)
        guard values.count == 11 else { return false }
        let weights = [1, 3, 7, 9, 1, 3, 7, 9, 1, 3]
        let sum = zip(values.prefix(10), weights).reduce(0) { $0 + $1.0 * $1.1 }
        return (10 - sum % 10) % 10 == values[10]
    }

    /// "123-456-32-18"
    static func formatted(nip: String) -> String {
        guard nip.count == 10 else { return nip }
        let d = Array(nip)
        return "\(String(d[0 ... 2]))-\(String(d[3 ... 5]))-\(String(d[6 ... 7]))-\(String(d[8 ... 9]))"
    }

    /// "+48 600 100 200"
    static func formatted(phone: String) -> String {
        if phone.hasPrefix("+48"), phone.count == 12 {
            let d = Array(phone.dropFirst(3))
            return "+48 \(String(d[0 ... 2])) \(String(d[3 ... 5])) \(String(d[6 ... 8]))"
        }
        return phone
    }

    // MARK: - Actions

    @MainActor
    static func actions(for kind: ClipboardSmartKind, linkTitle: String?) -> [ClipboardSmartAction] {
        switch kind {
        case let .url(url):
            var list = [
                ClipboardSmartAction(id: "open", title: "Otwórz", symbol: "safari") {
                    NSWorkspace.shared.open(url)
                },
                ClipboardSmartAction(id: "copy", title: "Kopiuj link", symbol: "doc.on.doc", copies: true) {
                    ClipboardManager.shared.copyText(url.absoluteString)
                },
            ]
            if let linkTitle {
                list.append(ClipboardSmartAction(id: "title", title: "Kopiuj tytuł strony", symbol: "textformat", copies: true) {
                    ClipboardManager.shared.copyText(linkTitle)
                })
            }
            return list

        case let .color(color):
            return [
                ClipboardSmartAction(id: "hex", title: "Kopiuj jako HEX (\(color.hex))", symbol: "number", copies: true) {
                    ClipboardManager.shared.copyText(color.hex)
                },
                ClipboardSmartAction(id: "rgb", title: "Kopiuj jako RGB (\(color.rgb))", symbol: "slider.horizontal.3", copies: true) {
                    ClipboardManager.shared.copyText(color.rgb)
                },
            ]

        case let .email(address):
            return [
                ClipboardSmartAction(id: "mail", title: "Napisz", symbol: "square.and.pencil") {
                    if let url = URL(string: "mailto:" + address) { NSWorkspace.shared.open(url) }
                },
                ClipboardSmartAction(id: "copy", title: "Kopiuj adres", symbol: "doc.on.doc", copies: true) {
                    ClipboardManager.shared.copyText(address)
                },
            ]

        case let .phone(dial):
            return [
                ClipboardSmartAction(id: "call", title: "Zadzwoń", symbol: "phone.arrow.up.right") {
                    if let url = URL(string: "tel:" + dial) { NSWorkspace.shared.open(url) }
                },
                ClipboardSmartAction(id: "copy", title: "Kopiuj numer bez spacji", symbol: "doc.on.doc", copies: true) {
                    ClipboardManager.shared.copyText(dial)
                },
            ]

        case let .ean(ean):
            return [
                ClipboardSmartAction(id: "allegro", title: "Szukaj na Allegro", symbol: "cart") {
                    open(base: "https://allegro.pl/listing", name: "string", value: ean)
                },
                ClipboardSmartAction(id: "google", title: "Szukaj w Google", symbol: "magnifyingglass") {
                    open(base: "https://www.google.com/search", name: "q", value: ean)
                },
            ]

        case let .nip(nip):
            return [
                ClipboardSmartAction(id: "regon", title: "Sprawdź w KRS/CEIDG (REGON)", symbol: "building.columns", copies: true) {
                    // The registry search has no deep link, so the number is
                    // put on the pasteboard ready to paste into its form.
                    ClipboardManager.shared.copyText(nip)
                    if let url = URL(string: "https://wyszukiwarkaregon.stat.gov.pl/appBIR/index.aspx") {
                        NSWorkspace.shared.open(url)
                    }
                },
                ClipboardSmartAction(id: "google", title: "Szukaj w Google", symbol: "magnifyingglass") {
                    open(base: "https://www.google.com/search", name: "q", value: "NIP " + nip)
                },
                ClipboardSmartAction(id: "copy", title: "Kopiuj sam NIP", symbol: "doc.on.doc", copies: true) {
                    ClipboardManager.shared.copyText(nip)
                },
            ]

        case .longText, .plain:
            return []
        }
    }

    @MainActor
    private static func open(base: String, name: String, value: String) {
        guard var components = URLComponents(string: base) else { return }
        components.queryItems = [URLQueryItem(name: name, value: value)]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
}

// MARK: - Link titles

/// Fetches the `<title>` of a copied link once and remembers it. A GET on a
/// link can have side effects (one-time sign-in, unsubscribe), so anything that
/// looks like it carries a secret or an action is never requested.
@MainActor
final class LinkTitleStore: ObservableObject {
    static let shared = LinkTitleStore()

    @Published private(set) var titles: [String: String] = [:]

    private var order: [String] = []
    private var attempted: Set<String> = []
    /// Not the same key as `ShelfClipPrefs.linkTitlesKey`: the cache must never
    /// share storage with the on/off switch, or clearing it flips the switch.
    private let storeKey = "extras.shelfclip.linkTitleCache"
    private let limit = 200

    private init() {
        // Before the keys were split, the cache lived under the switch's key.
        // Drop that array: it holds URLs the user can no longer see or clear.
        let legacyKey = ShelfClipPrefs.linkTitlesKey
        if UserDefaults.standard.object(forKey: legacyKey) is [Any] {
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }
        let stored = UserDefaults.standard.array(forKey: storeKey) as? [[String]] ?? []
        for pair in stored where pair.count == 2 {
            titles[pair[0]] = pair[1]
            order.append(pair[0])
            attempted.insert(pair[0])
        }
    }

    var cachedCount: Int { titles.count }

    func title(for url: URL) -> String? { titles[url.absoluteString] }

    func clearCache() {
        titles.removeAll()
        order.removeAll()
        attempted.removeAll()
        UserDefaults.standard.removeObject(forKey: storeKey)
    }

    func request(_ url: URL) {
        let key = url.absoluteString
        guard ShelfClipPrefs.smartActions, ShelfClipPrefs.linkTitles,
              !attempted.contains(key), Self.isSafeToFetch(url)
        else { return }
        // Remembered for the session even on failure, so a dead link is not
        // retried every time its tile scrolls into view.
        attempted.insert(key)

        Task { [weak self] in
            let title = await Self.fetchTitle(url)
            // The switch may have been turned off while the request was in flight.
            guard let self, let title, ShelfClipPrefs.linkTitles else { return }
            self.store(title, for: key)
        }
    }

    private func store(_ title: String, for key: String) {
        titles[key] = title
        order.append(key)
        while order.count > limit {
            titles.removeValue(forKey: order.removeFirst())
        }
        UserDefaults.standard.set(order.compactMap { k in titles[k].map { [k, $0] } }, forKey: storeKey)
    }

    nonisolated static func isSafeToFetch(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let rawHost = url.host, url.user == nil, url.password == nil
        else { return false }

        // Only the scheme's own port: other ports are where routers, printers
        // and dev servers listen.
        if let port = url.port, port != (scheme == "https" ? 443 : 80) { return false }

        // A public site name only. This rejects IP literals in every spelling
        // (dotted, decimal, hex, IPv6), localhost and single-label LAN names,
        // because a real top-level domain never starts with a digit and
        // never contains ":".
        var host = rawHost.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let tld = labels.last, tld.first?.isLetter == true,
              !host.contains(":")
        else { return false }
        let internalSuffixes = ["localhost", "local", "internal", "lan", "home", "arpa", "intranet", "corp", "private"]
        if internalSuffixes.contains(String(tld)) { return false }

        let sensitive = "token|key|secret|auth|sig|session|pass|pwd|code|otp|reset|magic|confirm|verify|unsubscribe|invite|login|logout|nonce|jwt|ticket"
        let queryNames = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.map(\.name) ?? []
        if queryNames.contains(where: { $0.range(of: sensitive, options: [.regularExpression, .caseInsensitive]) != nil }) {
            return false
        }
        let pathWords = "unsubscribe|reset|verify|confirm|activate|invite|login|logout|magic|optout|opt-out|signout"
        return url.path.range(of: pathWords, options: [.regularExpression, .caseInsensitive]) == nil
    }

    /// A public page can redirect to localhost or a LAN address; the target of
    /// every hop has to pass the same check as the first URL.
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            guard let target = request.url, LinkTitleStore.isSafeToFetch(target),
                  await LinkTitleStore.resolvesToPublicAddress(target.host ?? "")
            else { return nil }
            return request
        }
    }

    /// A name that passes the textual check can still point at the LAN
    /// ("192.168.0.1.nip.io", a record an attacker controls). The addresses it
    /// resolves to must all be public.
    nonisolated static func resolvesToPublicAddress(_ host: String) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo()
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = SOCK_STREAM
                var list: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else {
                    continuation.resume(returning: false)
                    return
                }
                defer { freeaddrinfo(list) }
                var cursor: UnsafeMutablePointer<addrinfo>? = first
                var isPublic = true
                while let entry = cursor?.pointee {
                    if let address = entry.ai_addr, !isPublicAddress(address, family: entry.ai_family) { isPublic = false }
                    cursor = entry.ai_next
                }
                continuation.resume(returning: isPublic)
            }
        }
    }

    nonisolated private static func isPublicAddress(_ address: UnsafeMutablePointer<sockaddr>, family: Int32) -> Bool {
        if family == AF_INET {
            return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                let value = UInt32(bigEndian: pointer.pointee.sin_addr.s_addr)
                return isPublicIPv4(UInt8(value >> 24), UInt8((value >> 16) & 0xFF))
            }
        }
        guard family == AF_INET6 else { return false }
        return address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
            let bytes = withUnsafeBytes(of: pointer.pointee.sin6_addr) { Array($0) }
            guard bytes.count == 16 else { return false }
            // ::, ::1, and v4-mapped / v4-compatible forms of a private v4 address.
            if bytes[0 ..< 10].allSatisfy({ $0 == 0 }) {
                if bytes[10] == 0xFF, bytes[11] == 0xFF { return isPublicIPv4(bytes[12], bytes[13]) }
                return false
            }
            // fe80::/10 link-local, fc00::/7 unique local, ff00::/8 multicast.
            if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return false }
            if bytes[0] & 0xFE == 0xFC || bytes[0] == 0xFF { return false }
            return true
        }
    }

    nonisolated private static func isPublicIPv4(_ first: UInt8, _ second: UInt8) -> Bool {
        switch first {
        case 0, 10, 127: return false
        case 100 where (64 ... 127).contains(second): return false
        case 169 where second == 254: return false
        case 172 where (16 ... 31).contains(second): return false
        case 192 where second == 168: return false
        case 224...: return false
        default: return true
        }
    }

    nonisolated private static func fetchTitle(_ url: URL) async -> String? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.httpCookieStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        // Plenty of sites turn away clients that do not look like a browser.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("pl-PL,pl;q=0.9,en;q=0.7", forHTTPHeaderField: "Accept-Language")

        do {
            guard await resolvesToPublicAddress(url.host ?? "") else { return nil }
            let (bytes, response) = try await session.bytes(for: request, delegate: RedirectGuard())
            guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else { return nil }
            let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? "text/html"
            guard contentType.contains("html") else { return nil }

            // The title is near the top; 96 KB is far more than enough and
            // keeps a huge page from being downloaded for one line.
            var data = Data()
            var sinceCheck = 0
            for try await byte in bytes {
                data.append(byte)
                sinceCheck += 1
                if sinceCheck >= 4096 {
                    sinceCheck = 0
                    if titleRange(in: data) != nil { break }
                }
                if data.count >= 98304 { break }
            }
            guard let range = titleRange(in: data) else { return nil }
            let encoding = textEncoding(header: http.textEncodingName, head: data.prefix(2048))
            let raw = data.subdata(in: range)
            let text = String(data: raw, encoding: encoding)
                ?? String(data: raw, encoding: .utf8)
                ?? String(data: raw, encoding: .isoLatin1)
            return text.flatMap(cleanTitle)
        } catch {
            return nil
        }
    }

    /// Byte range of the text between `<title…>` and `</title`.
    nonisolated private static func titleRange(in data: Data) -> Range<Int>? {
        // Case-folded ASCII copy, so a byte offset in it is valid in `data`
        // whatever the page's own encoding is.
        let lowered = Data(data.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 })
        guard let open = lowered.range(of: Data("<title".utf8)),
              let close = lowered.range(of: Data("</title".utf8), in: open.upperBound ..< lowered.endIndex),
              let tagEnd = lowered.range(of: Data(">".utf8), in: open.upperBound ..< close.lowerBound)
        else { return nil }
        return tagEnd.upperBound ..< close.lowerBound
    }

    nonisolated private static func textEncoding(header: String?, head: Data) -> String.Encoding {
        func encoding(named name: String) -> String.Encoding? {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            guard cf != kCFStringEncodingInvalidId else { return nil }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        }
        if let header, let found = encoding(named: header) { return found }
        let sniff = String(decoding: head, as: UTF8.self).lowercased()
        if let range = sniff.range(of: "charset=") {
            let name = String(sniff[range.upperBound...].prefix(while: { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }))
            if !name.isEmpty, let found = encoding(named: name) { return found }
        }
        return .utf8
    }

    nonisolated private static func cleanTitle(_ raw: String) -> String? {
        // One pass over every entity, so "&amp;lt;" becomes "&lt;" and not "<".
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
            "ndash": "–", "mdash": "—", "hellip": "…", "laquo": "«", "raquo": "»",
            "bull": "•", "middot": "·", "copy": "©", "reg": "®", "trade": "™",
            "euro": "€", "oacute": "ó", "Oacute": "Ó", "eacute": "é",
        ]
        var text = raw
        if let regex = try? NSRegularExpression(pattern: "&(#[xX][0-9A-Fa-f]+|#[0-9]+|[A-Za-z]+);") {
            let source = raw as NSString
            var result = ""
            var cursor = 0
            for match in regex.matches(in: raw, range: NSRange(location: 0, length: source.length)) {
                result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                let body = source.substring(with: match.range(at: 1))
                if body.hasPrefix("#") {
                    let isHex = body.hasPrefix("#x") || body.hasPrefix("#X")
                    let digits = String(body.dropFirst(isHex ? 2 : 1))
                    // Control characters (a "&#0;") never belong in a title.
                    if let code = UInt32(digits, radix: isHex ? 16 : 10), code > 31, let scalar = Unicode.Scalar(code) {
                        result += String(Character(scalar))
                    }
                } else if let value = named[body] {
                    result += value
                } else {
                    // Unknown entity: leave it as the page wrote it.
                    result += source.substring(with: match.range)
                }
                cursor = match.range.location + match.range.length
            }
            result += source.substring(from: cursor)
            text = result
        }

        let collapsed = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count > 160 ? String(collapsed.prefix(160)) + "…" : collapsed
    }
}

// MARK: - Tile content

/// What a smart entry shows in the clipboard tile instead of its raw text.
struct ClipboardSmartContent: View {
    let kind: ClipboardSmartKind
    let text: String

    var body: some View {
        switch kind {
        case let .url(url):
            ClipboardURLCard(url: url)
        case let .color(color):
            VStack(alignment: .leading, spacing: 3) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(color.swiftUIColor)
                    .frame(height: 30)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.2), lineWidth: 0.5))
                Text(color.hex)
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                Text(color.rgb)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
        case let .email(address):
            badged("E-mail", value: address, mono: false)
        case let .phone(dial):
            badged("Telefon", value: ClipboardSmart.formatted(phone: dial), mono: true)
        case let .ean(ean):
            badged("EAN-13", value: ean, mono: true)
        case let .nip(nip):
            badged("NIP", value: ClipboardSmart.formatted(nip: nip), mono: true)
        case let .longText(characters, words):
            VStack(alignment: .leading, spacing: 3) {
                Text(text)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                Text("\(characters.formatted(.number.locale(Polish.locale))) \(Polish.plural(characters, "znak", "znaki", "znaków")) · \(words.formatted(.number.locale(Polish.locale))) \(Polish.plural(words, "słowo", "słowa", "słów"))")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
        case .plain:
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func badged(_ label: String, value: String, mono: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(Color.white.opacity(0.12)))
            Text(value)
                .font(.system(size: 11, weight: .medium, design: mono ? .monospaced : .default))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ClipboardURLCard: View {
    let url: URL

    @ObservedObject private var store = LinkTitleStore.shared

    private var host: String {
        let value = url.host ?? url.absoluteString
        return value.hasPrefix("www.") ? String(value.dropFirst(4)) : value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(store.title(for: url) ?? host)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(store.title(for: url) == nil ? url.absoluteString : host)
                .font(.system(size: 8.5))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: url) { store.request(url) }
    }
}
