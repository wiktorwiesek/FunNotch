//
//  LyricsViews.swift
//  FunNotch
//
//  Lyrics in the open player: two lines under the artist, and a full panel
//  that follows the song.
//

import SwiftUI

/// The current and next line, or a short note that the text is unsynced. A
/// button: it opens the full panel. The player decides how many rows it can
/// spare (see `PlayerControls`), so this view only ever draws what it is told
/// to and has a fixed height for each choice — it can never push the
/// controls under it out of their tile.
struct LyricsPlayerBlock: View {
    enum Rows { case one, two }

    @ObservedObject private var lyrics = LyricsManager.shared
    var rows: Rows = .two

    /// Two lines of synced text.
    static let twoHeight: CGFloat = 28
    /// The current line alone, or a single quiet note.
    static let oneHeight: CGFloat = 15

    /// How many rows can be shown for `state`, no more than `requested`; nil
    /// when there is nothing worth showing (no lyrics, still searching,
    /// switched off).
    static func rows(requested: Rows?, state: LyricsState, enabled: Bool, inPlayer: Bool) -> Rows? {
        guard let requested, enabled, inPlayer else { return nil }
        switch state {
        case .synced: return requested
        case .plain: return .one
        case .idle, .loading, .instrumental, .notFound, .unavailable: return nil
        }
    }

    var body: some View {
        Button {
            withAnimation(.notchContent) { MediaOverlayState.shared.mode = .lyrics }
        } label: {
            content
                .frame(
                    maxWidth: .infinity,
                    minHeight: height, maxHeight: height,
                    alignment: .topLeading
                )
                .clipped()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Pokaż cały tekst")
    }

    private var height: CGFloat { rows == .two ? Self.twoHeight : Self.oneHeight }

    @ViewBuilder
    private var content: some View {
        switch lyrics.state {
        case .synced:
            VStack(alignment: .leading, spacing: 1) {
                Text(lyrics.currentText ?? "♪")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .id(lyrics.currentIndex)
                    .transition(.opacity)
                if rows == .two {
                    Text(lyrics.nextText ?? " ")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
            }
            .animation(.easeOut(duration: 0.2), value: lyrics.currentIndex)
        case .plain:
            note("Tekst bez synchronizacji · kliknij, aby przeczytać")
        case .loading, .instrumental, .notFound, .unavailable, .idle:
            EmptyView()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(.white.opacity(0.4))
            .lineLimit(1)
    }
}

/// Every line, the current one lit and kept near the middle.
struct LyricsFullView: View {
    @ObservedObject private var lyrics = LyricsManager.shared
    @ObservedObject private var music = MusicManager.shared
    @AppStorage(MediaExtrasDefaults.lyricsEnabledKey) private var enabled = true

    var body: some View {
        if !enabled {
            message(
                symbol: "text.quote",
                text: "Teksty są wyłączone",
                detail: "Włącz je w Ustawieniach, w sekcji Dodatki."
            )
        } else if music.track.isEmpty {
            message(symbol: "music.note", text: "Nic nie gra", detail: nil)
        } else {
            switch lyrics.state {
            case .synced:
                syncedList
            case .plain:
                plainText
            case .loading, .idle:
                message(symbol: "magnifyingglass", text: "Szukam tekstu…", detail: nil)
            case .instrumental:
                message(symbol: "pianokeys", text: "Utwór instrumentalny", detail: nil)
            case .notFound:
                message(symbol: "text.badge.xmark", text: "Brak tekstu", detail: "LRCLIB nie ma tego utworu.")
            case .unavailable:
                message(
                    symbol: "wifi.exclamationmark",
                    text: "Nie udało się pobrać tekstu",
                    detail: "Sprawdź połączenie z internetem."
                )
            }
        }
    }

    private var syncedList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    Color.clear.frame(height: 30)
                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                        let isCurrent = index == lyrics.currentIndex
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.system(size: isCurrent ? 16 : 13, weight: isCurrent ? .bold : .medium))
                            .foregroundStyle(.white.opacity(opacity(for: index)))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .id(index)
                    }
                    Color.clear.frame(height: 40)
                }
                .padding(.horizontal, 4)
            }
            .onChange(of: lyrics.currentIndex) { _, index in
                guard let index else { return }
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(index, anchor: .center) }
            }
            // A new song reuses the same row ids, so without this the list
            // stays scrolled to wherever the previous one was.
            .onChange(of: lyrics.lines) { _, _ in
                proxy.scrollTo(lyrics.currentIndex ?? 0, anchor: .center)
            }
            .onAppear {
                if let index = lyrics.currentIndex { proxy.scrollTo(index, anchor: .center) }
            }
            .animation(.easeOut(duration: 0.25), value: lyrics.currentIndex)
        }
        // Fades the lines out at the top and bottom edge.
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.18),
                    .init(color: .black, location: 0.82),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    /// Brightest at the current line, fading with distance.
    private func opacity(for index: Int) -> Double {
        guard let current = lyrics.currentIndex else { return 0.45 }
        let distance = abs(index - current)
        if distance == 0 { return 1 }
        return max(0.5 - Double(distance) * 0.1, 0.18)
    }

    private var plainText: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ten tekst nie ma znaczników czasu, więc nie przewija się sam.")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
                Text(lyrics.plain ?? "")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 4)
        }
    }

    private func message(symbol: String, text: String, detail: String?) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(.white.opacity(0.5))
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The two small buttons beside the artist: full lyrics and the mixer.
struct MediaPlayerButtons: View {
    @AppStorage(MediaExtrasDefaults.lyricsEnabledKey) private var lyricsEnabled = true
    @AppStorage(MediaExtrasDefaults.mixerEnabledKey) private var mixerEnabled = true

    var body: some View {
        HStack(spacing: 0) {
            if lyricsEnabled {
                HoverButton(systemName: "text.quote", size: 11, padding: 2) {
                    withAnimation(.notchContent) { MediaOverlayState.shared.mode = .lyrics }
                }
                .help("Tekst piosenki")
            }
            if mixerEnabled {
                HoverButton(systemName: "slider.vertical.3", size: 11, padding: 2) {
                    withAnimation(.notchContent) { MediaOverlayState.shared.mode = .mixer }
                }
                .help("Mikser dźwięku")
            }
        }
    }
}
