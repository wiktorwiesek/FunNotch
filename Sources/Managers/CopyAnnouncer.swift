//
//  CopyAnnouncer.swift
//  FunNotch
//
//  The quiet "Skopiowano" island after something lands on the clipboard. At
//  most one per interval; a burst of copies collapses into the newest. The
//  copied text is only ever shown, never logged.
//

import AppKit
import SwiftUI

@MainActor
final class CopyAnnouncer {
    static let shared = CopyAnnouncer()

    /// Shorter than the throttle, so one island has left before the next may come.
    static let islandDuration = 1.4
    static let interval: TimeInterval = 1.5

    private var coalescer = CopyCoalescer<Island>(interval: CopyAnnouncer.interval)
    private var releaseWork: DispatchWorkItem?

    private init() {}

    func note(_ payload: ClipboardEntry.Payload) {
        guard ShelfClipPrefs.copiedIsland else { return }
        let island = Self.island(for: payload)
        let now = Date()

        if let ready = coalescer.offer(island, at: now) {
            IslandCenter.shared.post(ready)
            return
        }
        // Held back: one timer is enough, it picks up whatever is newest.
        guard releaseWork == nil, let delay = coalescer.delay(at: now) else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.releaseWork = nil
                if let ready = self.coalescer.release(at: Date()) {
                    IslandCenter.shared.post(ready)
                }
            }
        }
        releaseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    static func island(for payload: ClipboardEntry.Payload) -> Island {
        var symbol = "doc.on.doc"
        var tint = Color.white
        let preview: String

        switch payload {
        case let .text(text):
            preview = CopyPreviewText.oneLine(text)
            // Colour and link detection is cheap only for short single-line
            // text; anything longer is plain.
            if text.utf8.count <= 300 {
                switch ClipboardSmart.detect(text) {
                case let .color(color):
                    symbol = "circle.fill"
                    tint = color.swiftUIColor
                case .url:
                    symbol = "link"
                default:
                    break
                }
            }
        case .image:
            symbol = "photo"
            preview = "obraz"
        case let .files(urls):
            symbol = "doc"
            preview = urls.count == 1
                ? CopyPreviewText.middleTruncated(urls[0].lastPathComponent, limit: CopyPreviewText.maxLength)
                : Polish.count(urls.count, "plik", "pliki", "plików")
        }

        return Island(
            symbol: symbol,
            tint: tint,
            title: "Skopiowano",
            detail: " · " + preview,
            duration: islandDuration,
            isQuiet: true,
            cat: .peek
        )
    }
}
