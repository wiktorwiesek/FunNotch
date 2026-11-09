//
//  MediaExtras.swift
//  FunNotch
//
//  Entry point for the media extras: synced lyrics, the per-app sound mixer
//  and the real audio spectrum. Holds their settings keys, starts their
//  managers and registers the palette commands.
//

import AppKit
import SwiftUI

/// Settings for the media extras. Plain `UserDefaults` under the `extras.media`
/// prefix, so the settings view can bind the same keys with `@AppStorage`.
enum MediaExtrasDefaults {
    static let autoSourceKey = "extras.media.autoSource"
    static let lyricsEnabledKey = "extras.media.lyricsEnabled"
    static let lyricsInPlayerKey = "extras.media.lyricsInPlayer"
    static let lyricsInClosedNotchKey = "extras.media.lyricsInClosedNotch"
    static let mixerEnabledKey = "extras.media.mixerEnabled"
    static let realSpectrumKey = "extras.media.realSpectrum"

    private static func bool(_ key: String, _ fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }

    /// Follow whichever player started most recently instead of staying on
    /// the source picked in settings.
    static var autoSource: Bool { bool(autoSourceKey, true) }
    /// Fetching lyrics at all. Off means no network request is ever made.
    static var lyricsEnabled: Bool { bool(lyricsEnabledKey, true) }
    /// The current and next line under the artist in the open player.
    static var lyricsInPlayer: Bool { bool(lyricsInPlayerKey, true) }
    /// The current line in the strip under the closed notch.
    static var lyricsInClosedNotch: Bool { bool(lyricsInClosedNotchKey, false) }
    /// The mixer button in the player. Saved per-app levels keep applying.
    static var mixerEnabled: Bool { bool(mixerEnabledKey, true) }
    /// Drive the spectrum bars from the system output instead of an animation.
    /// Opt-in: it makes macOS ask for permission to record system audio.
    static var realSpectrum: Bool { bool(realSpectrumKey, false) }
}

@MainActor
enum MediaExtras {
    private static var started = false

    static func start() {
        guard !started else { return }
        started = true

        LyricsManager.shared.start()
        AudioMixerManager.shared.start()
        SpectrumAnalyzer.shared.start()

        PaletteCommandRegistry.shared.register(PaletteCommand(
            id: "media.lyrics",
            title: "Pokaż tekst piosenki",
            subtitle: "Tekst granego utworu w otwartym notchu",
            symbol: "text.quote",
            keywords: ["tekst", "piosenka", "lyrics", "słowa", "muzyka"]
        ) {
            MediaOverlayState.shared.present(.lyrics)
        })

        PaletteCommandRegistry.shared.register(PaletteCommand(
            id: "media.mixer",
            title: "Mikser dźwięku",
            subtitle: "Głośność i korektor osobno dla każdej aplikacji",
            symbol: "slider.vertical.3",
            keywords: ["mikser", "głośność", "dźwięk", "volume", "mixer", "equalizer", "korektor"]
        ) {
            MediaOverlayState.shared.present(.mixer)
        })
    }
}

// MARK: - Overlay

/// Which of the media panels covers the open notch's content, if any. A panel
/// of its own, rather than a tile, so it works whatever the home layout is.
@MainActor
final class MediaOverlayState: ObservableObject {
    static let shared = MediaOverlayState()

    enum Mode { case none, lyrics, mixer }

    @Published var mode: Mode = .none

    private init() {}

    /// Opens the notch on the display the pointer is on, with `mode` showing.
    func present(_ mode: Mode) {
        self.mode = mode
        NotchWindowManager.shared.activeViewModel?.open()
    }

    func dismiss() {
        withAnimation(.notchContent) { mode = .none }
    }
}

private struct MediaOverlayHost: View {
    @ObservedObject private var state = MediaOverlayState.shared

    var body: some View {
        ZStack {
            // A real view to hang `onDisappear` on: an empty one never fires it.
            // The panels are for this opening only; the next one starts clean.
            Color.clear
                .allowsHitTesting(false)
                .onDisappear { MediaOverlayState.shared.mode = .none }
            switch state.mode {
            case .none:
                EmptyView()
            case .lyrics:
                MediaPanelFrame(title: "Tekst piosenki", symbol: "text.quote") { LyricsFullView() }
            case .mixer:
                MediaPanelFrame(title: "Mikser dźwięku", symbol: "slider.vertical.3") { AudioMixerPanel() }
            }
        }
        .animation(.notchContent, value: state.mode)
    }
}

/// Title bar with a back button, shared by both panels. Opaque, because it sits
/// over whatever tab is showing.
private struct MediaPanelFrame<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    MediaOverlayState.shared.dismiss()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 9, weight: .bold))
                        Text("Wróć")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)

                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 0)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black)
        .transition(.opacity)
    }
}

extension View {
    /// Lets the lyrics and mixer panels cover the open notch's content.
    func mediaExtrasOverlay() -> some View {
        overlay { MediaOverlayHost() }
    }
}
