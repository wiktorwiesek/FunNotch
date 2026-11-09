//
//  ActivityRules.swift
//  FunNotch
//
//  The decisions behind the "Skopiowano" and AirDrop islands, kept free of
//  AppKit and of every singleton so a harness can compile this one file and
//  drive it with fixed inputs: copy throttling, the one-line copy preview, and
//  telling an AirDrop arrival from an ordinary download.
//

import Foundation

// MARK: - Copy throttle

/// Lets one item through per `interval` and holds back the rest, keeping only
/// the newest of a burst. Time is passed in, so tests need no sleeping.
struct CopyCoalescer<Item> {
    let interval: TimeInterval
    private var lastShown: Date?
    private(set) var pending: Item?

    init(interval: TimeInterval) {
        self.interval = interval
    }

    /// The item to show right now, or nil when it was held back (it replaces
    /// whatever was held before it).
    mutating func offer(_ item: Item, at now: Date) -> Item? {
        if let lastShown, now.timeIntervalSince(lastShown) < interval {
            pending = item
            return nil
        }
        pending = nil
        lastShown = now
        return item
    }

    /// Seconds until the held item may be shown; nil when nothing is held.
    func delay(at now: Date) -> TimeInterval? {
        guard pending != nil else { return nil }
        guard let lastShown else { return 0 }
        return max(0, lastShown.addingTimeInterval(interval).timeIntervalSince(now))
    }

    /// Hands out the held item, to be shown now.
    mutating func release(at now: Date) -> Item? {
        guard let item = pending else { return nil }
        pending = nil
        lastShown = now
        return item
    }
}

// MARK: - Copy preview

enum CopyPreviewText {
    static let maxLength = 28

    /// Whitespace runs collapsed to one space, then cut in the middle so both
    /// the start and the end (a file extension, a URL's last segment) survive.
    static func oneLine(_ text: String, limit: Int = maxLength) -> String {
        // A copied log can be megabytes; only the head is ever shown.
        let head = text.prefix(400)
        let collapsed = head.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return middleTruncated(collapsed, limit: limit)
    }

    static func middleTruncated(_ text: String, limit: Int) -> String {
        guard limit > 1, text.count > limit else { return text }
        let keep = limit - 1
        let tail = keep / 2
        let head = keep - tail
        return String(text.prefix(head)) + "…" + String(text.suffix(tail))
    }
}

// MARK: - Where a new file came from

enum DownloadOrigin: Equatable {
    /// The quarantine record names `sharingd`, the AirDrop daemon.
    case airDrop
    /// Quarantined by a browser, mail client, chat app and so on.
    case other
    /// No quarantine record (yet). AirDrop may still be about to stamp it.
    case unknown
}

enum AirDropDetector {
    static let quarantineAttribute = "com.apple.quarantine"

    /// The record is `flags;hexTimestamp;agentName;UUID`, e.g.
    /// `0081;6ac79e1f;sharingd;C9912826-…` for a photo AirDropped from an
    /// iPhone and `0081;…;Vivaldi;…` for a browser download.
    static func origin(forQuarantine value: String?) -> DownloadOrigin {
        guard let value, !value.isEmpty else { return .unknown }
        let fields = value.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count >= 3 else { return .other }
        let agent = fields[2].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return agent == "sharingd" ? .airDrop : .other
    }

    static func origin(of url: URL) -> DownloadOrigin {
        origin(forQuarantine: quarantine(of: url))
    }

    static func quarantine(of url: URL) -> String? {
        url.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path else { return nil }
            // The record is a few dozen bytes; a size far past that is not one.
            let size = getxattr(path, quarantineAttribute, nil, 0, 0, XATTR_NOFOLLOW)
            guard size > 0, size <= 1024 else { return nil }
            var buffer = [UInt8](repeating: 0, count: size)
            let read = getxattr(path, quarantineAttribute, &buffer, size, 0, XATTR_NOFOLLOW)
            guard read > 0 else { return nil }
            return String(decoding: buffer.prefix(read), as: UTF8.self)
        }
    }
}

// MARK: - Routing a finished file

enum DownloadRoute: Equatable {
    /// The ordinary "pobrano" activity.
    case download
    /// The AirDrop island; the generic download activity is suppressed.
    case airDrop
    /// Quarantine not stamped yet: look again shortly before deciding.
    case recheck
    /// Not a new arrival (a file moved in from elsewhere).
    case ignore

    /// How often an unstamped file is looked at again, and how long between.
    static let maxRechecks = 2
    static let recheckDelay: TimeInterval = 1.2

    /// `createdAt` can be the *sender's* date for an AirDropped file, so it
    /// only counts for files that are not AirDrop. Whether a name is new to
    /// the folder is decided earlier by the directory diff.
    static func decide(
        origin: DownloadOrigin,
        createdAt: Date?,
        watchStartedAt: Date,
        rechecksDone: Int
    ) -> DownloadRoute {
        if origin == .airDrop { return .airDrop }
        if origin == .unknown, rechecksDone < maxRechecks { return .recheck }
        guard let createdAt, createdAt >= watchStartedAt.addingTimeInterval(-2) else { return .ignore }
        return .download
    }
}
