//
//  OpenNotchView.swift
//  FunNotch
//
//  The expanded panel: a header that straddles the camera housing, then either
//  the home view (player, agenda, mirror) or the shelf.
//

import AppKit
import SwiftUI

struct OpenNotchView: View {
    @EnvironmentObject private var viewModel: NotchViewModel
    @EnvironmentObject private var settings: Settings

    var body: some View {
        VStack(spacing: 0) {
            NotchHeader()
                .frame(height: max(viewModel.closedNotchSize.height, 30))

            Group {
                switch viewModel.currentTab {
                case .home:
                    NotchHomeView()
                case .shelf:
                    ShelfView()
                case .clipboard:
                    ClipboardView()
                case .focus:
                    FocusView()
                case .notes:
                    NotesView()
                case .notifications:
                    NotificationsTabView()
                case .game:
                    // Belt and braces: the tab is already gone from the header
                    // during a session, but nothing should be able to land here
                    // and start a game anyway.
                    if FocusManager.shared.isActive {
                        GameBlockedDuringFocus()
                    } else {
                        GameView()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .mediaExtrasOverlay()
            .transition(.opacity)
        }
        // Generous insets so nothing runs into the rounded corners.
        .padding(.horizontal, 22)
        .padding(.bottom, 20)
        .animation(.notchContent, value: viewModel.currentTab)
    }
}

/// Stands in for the game while a focus session is running.
private struct GameBlockedDuringFocus: View {
    @EnvironmentObject private var viewModel: NotchViewModel
    @ObservedObject private var focus = FocusManager.shared

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.7))
            Text("Nie podczas skupienia")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Text("Gry wrócą za \(focus.compactRemainingText).")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
            Button("Przejdź do minutnika") {
                FocusTabState.shared.mode = .focus
                withAnimation(.notchContent) { viewModel.currentTab = .focus }
            }
            .buttonStyle(NotchPressStyle())
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .notchControl(in: Capsule(), resting: true)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Header row. The middle is left empty so nothing ever hides behind the camera.
struct NotchHeader: View {
    @EnvironmentObject private var viewModel: NotchViewModel
    @EnvironmentObject private var settings: Settings
    @ObservedObject private var calendar = CalendarManager.shared
    @ObservedObject private var focus = FocusManager.shared
    @ObservedObject private var notify = NotifyCenter.shared
    /// Shared by the tabs so one glass marker slides between them.
    @Namespace private var tabSelection

    var body: some View {
        HStack(spacing: 0) {
            NotchGlassGroup {
                HStack(spacing: Self.tabSpacing) {
                    ForEach(availableTabs) { tab in
                        let labelled = viewModel.currentTab == tab && availableTabs.count <= 4
                        TabChip(
                            tab: tab,
                            isSelected: viewModel.currentTab == tab,
                            namespace: tabSelection,
                            // The header shares its row with the camera cutout, so
                            // only the selected tab is labelled, and only while
                            // there are few enough tabs for it to fit.
                            showsLabel: labelled,
                            width: labelled ? nil : Self.tabWidth(
                                count: availableTabs.count, cutoutWidth: viewModel.closedNotchSize.width
                            )
                        ) {
                            withAnimation(NotchGlassMotion.select) { viewModel.currentTab = tab }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Reserved space for the physical cutout.
            Color.clear.frame(width: viewModel.closedNotchSize.width)

            HStack(spacing: 8) {
                Spacer(minLength: 0)

                if settings.showBatteryIndicator {
                    BatteryPill()
                }

                // Sits beside the gear: the home screen is the thing you are
                // looking at when you decide you want it rearranged, so the way
                // to rearrange it belongs here rather than three levels into
                // Settings.
                HoverButton(systemName: "square.grid.2x2", size: 13, padding: 5) {
                    CustomizeWindowController.shared.show(tab: .home)
                    viewModel.close()
                }
                .help("Dostosuj notch")

                HoverButton(systemName: "gearshape", size: 13, padding: 5) {
                    SettingsWindowController.shared.show()
                    viewModel.close()
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    static let tabSpacing: CGFloat = 4

    /// Width of one tab button, chosen so every tab fits on its side of the
    /// camera. They used to size themselves, and seven of them ran past the
    /// edge of the cutout: the last one, Game, sat under the camera housing
    /// where it could not be seen or clicked.
    static func tabWidth(count: Int, cutoutWidth: CGFloat) -> CGFloat {
        // The space left of the cutout, less a margin so nothing hugs the
        // camera's edge.
        let side = (openNotchSize.width - 44 - cutoutWidth) / 2 - 8
        let tabs = CGFloat(max(count, 1))
        return max(min(34, (side - (tabs - 1) * tabSpacing) / tabs), 20)
    }

    private var availableTabs: [NotchTab] {
        NotchTab.allCases.filter { tab in
            switch tab {
            case .shelf: return settings.shelfEnabled
            case .clipboard: return settings.clipboardHistoryEnabled
            case .notes: return settings.showNotes
            case .notifications: return notify.showsTab
            // A focus session is a promise not to get distracted, and a game in
            // the notch is the most distracting thing in here.
            case .game: return !FocusManager.shared.isActive
            default: return true
            }
        }
    }
}

private struct TabChip: View {
    let tab: NotchTab
    let isSelected: Bool
    let namespace: Namespace.ID
    let showsLabel: Bool
    /// A fixed width, for icon-only tabs that have to share the row.
    var width: CGFloat?
    let action: () -> Void

    @State private var isHovering = false

    private let shape = Capsule()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 11, weight: .medium))
                if showsLabel {
                    Text(tab == .focus ? "Skupienie" : tab.title)
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .foregroundStyle(isSelected ? .white : .white.opacity(isHovering ? 0.85 : 0.55))
            .padding(.horizontal, width == nil ? 9 : 0)
            .frame(width: width)
            .padding(.vertical, 4)
            .contentShape(shape)
        }
        .buttonStyle(NotchPressStyle(scale: 0.94))
        .onHover { hovering in
            withAnimation(NotchGlassMotion.hover) { isHovering = hovering }
        }
        // The selected tab carries the shared marker; a hovered one a lighter
        // glass of its own that fades in and out.
        .background {
            if isHovering, !isSelected {
                NotchGlassSurface(shape: shape)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .notchSelection(isSelected, id: "tab", in: namespace, shape: shape)
        .notchHoverLift(isHovering && !isSelected, scale: 1.04)
        .help(tab.title)
    }
}

// MARK: - Home

struct NotchHomeView: View {
    var body: some View {
        HomeGridView()
    }
}

struct AlbumArtwork: View {
    @ObservedObject private var music = MusicManager.shared
    @EnvironmentObject private var settings: Settings
    @State private var isHovering = false

    private let side = MusicPlayerImageSizes.size.opened.width

    var body: some View {
        Button {
            music.openPlayingApp()
        } label: {
            ZStack {
                if let artwork = music.artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(
                        colors: [Color.white.opacity(0.18), Color.white.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "music.note")
                        .font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.6))
                }

                if isHovering {
                    Color.black.opacity(0.45)
                    Image(systemName: "arrow.up.forward.app.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: MusicPlayerImageSizes.cornerRadiusInset.opened))
            .overlay(
                RoundedRectangle(cornerRadius: MusicPlayerImageSizes.cornerRadiusInset.opened)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .notchHoverLift(isHovering, scale: 1.03)
        }
        .buttonStyle(NotchPressStyle(scale: 0.97))
        .disabled(music.track.bundleIdentifier == nil)
        .onHover { hovering in
            withAnimation(NotchGlassMotion.hover) { isHovering = hovering }
        }
        .overlay(alignment: .bottomTrailing) {
            if let icon = music.sourceAppIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .offset(x: 5, y: 5)
                    .shadow(radius: 2)
            }
        }
    }
}

/// The title, artist, lyrics, scrubber and transport beside the album art.
///
/// The column is as tall as its tile and not an inch taller. It used to stack
/// everything at a fixed size and pass the total up to the home row, so a
/// tile that was a few points short — or lyrics that added two lines — made
/// the whole notch layout grow and slide: the header scrolled off the top, the
/// bottom row off the bottom, and the transport row ended up under the art.
/// Now the content is laid out inside a box of exactly the offered size, from a
/// ladder of variants that gives up the least important thing first: the
/// second lyric line, then the stacked scrubber's time labels, then the
/// lyrics, then the scrubber. Every rung is a complete, correctly spaced
/// column; the last one is guaranteed to be short enough for any tile.
struct PlayerControls: View {
    @ObservedObject private var music = MusicManager.shared
    @ObservedObject private var lyrics = LyricsManager.shared
    @EnvironmentObject private var settings: Settings
    @AppStorage(MediaExtrasDefaults.lyricsEnabledKey) private var lyricsEnabled = true
    @AppStorage(MediaExtrasDefaults.lyricsInPlayerKey) private var lyricsInPlayer = true

    private enum ScrubberStyle { case stacked, inline, none }

    /// The heights and widths the rows are built with. The ladder adds them up
    /// to choose a rung, so every row below is framed to exactly these numbers.
    fileprivate enum Metrics {
        /// Gap between rows. Tight on purpose: the tile is about 100 points tall.
        static let rowSpacing: CGFloat = 2
        static let title: CGFloat = 17
        static let artist: CGFloat = 16
        /// The bar, and the times under it when they have a row of their own.
        static let slider: CGFloat = 12
        static let times: CGFloat = 11
        static let inlineScrubber: CGFloat = 12
        static let hint: CGFloat = 14
        static let transport: CGFloat = 24

        /// Glyph size and padding of the transport buttons; a button is
        /// `glyph + 2 * padding` wide.
        static let padding: CGFloat = 4
        static let smallGlyph: CGFloat = 11
        static let skipGlyph: CGFloat = 13
        static let playGlyph: CGFloat = 16
        static func width(glyph: CGFloat) -> CGFloat { glyph + 2 * padding }
    }

    /// Richest first. When there are no lyrics the first four collapse into
    /// the last three, which is harmless: the first that fits is used.
    private static let ladder: [(rows: LyricsPlayerBlock.Rows?, scrubber: ScrubberStyle)] = [
        (.two, .stacked), (.two, .inline), (.one, .stacked), (.one, .inline),
        (nil, .stacked), (nil, .inline), (nil, .none),
    ]

    var body: some View {
        // A clear base takes exactly the size the row offers, and the content
        // is drawn over it: nothing inside can ask the row for more.
        Color.clear
            .overlay(alignment: .topLeading) {
                if music.track.isEmpty {
                    emptyState
                } else {
                    player
                }
            }
    }

    // MARK: Ladder

    /// Only the rung that fits is ever built.
    ///
    /// This used to be a `ViewThatFits` over seven complete columns, each with
    /// its own transport row inside another `ViewThatFits`. SwiftUI keeps every
    /// rung alive to measure it, so the open notch carried seven copies of the
    /// player — about 150 buttons, 14 marquees, 18 scrubber views — and each
    /// change to the track or lyrics rebuilt all of them, 400 ms at a time and
    /// with a storm of `onDisappear`s. Every row has a fixed height and every
    /// button a fixed width, so the choice is arithmetic on the size the clear
    /// base was offered, which does not depend on what is drawn over it.
    private var player: some View {
        GeometryReader { proxy in
            let chosen = rung(fittingHeight: proxy.size.height)
            column(rows: chosen.rows, scrubber: chosen.scrubber, width: proxy.size.width)
        }
    }

    /// The first rung whose rows fit in `height`; the last always does.
    private func rung(fittingHeight height: CGFloat) -> (rows: LyricsPlayerBlock.Rows?, scrubber: ScrubberStyle) {
        for candidate in Self.ladder {
            let rows = LyricsPlayerBlock.rows(
                requested: candidate.rows, state: lyrics.state, enabled: lyricsEnabled, inPlayer: lyricsInPlayer
            )
            if columnHeight(rows: rows, scrubber: candidate.scrubber) <= height + 0.01 {
                return (rows, candidate.scrubber)
            }
        }
        return (nil, .none)
    }

    private func columnHeight(rows: LyricsPlayerBlock.Rows?, scrubber: ScrubberStyle) -> CGFloat {
        var heights: [CGFloat] = [Metrics.title, Metrics.artist]
        if let rows {
            heights.append(rows == .two ? LyricsPlayerBlock.twoHeight : LyricsPlayerBlock.oneHeight)
        }
        switch (music.track.hasTiming, scrubber) {
        case (_, .none): break
        case (false, _): heights.append(Metrics.hint)
        case (true, .stacked): heights.append(Metrics.slider + Metrics.times)
        case (true, .inline): heights.append(Metrics.inlineScrubber)
        }
        heights.append(Metrics.transport)
        return heights.reduce(0, +) + Metrics.rowSpacing * CGFloat(heights.count - 1)
    }

    /// One column. `rows` is what the lyrics can actually give (nothing while
    /// loading, one line for unsynced text), already capped by the rung.
    private func column(rows: LyricsPlayerBlock.Rows?, scrubber: ScrubberStyle, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            MarqueeText(text: music.track.title, font: .system(size: 14, weight: .semibold), lineHeight: Metrics.title)
                .foregroundStyle(.white)

            HStack(spacing: 4) {
                MarqueeText(text: music.track.artist, font: .system(size: 12), lineHeight: Metrics.artist)
                    .foregroundStyle(.white.opacity(0.6))
                MediaPlayerButtons()
            }
            .frame(height: Metrics.artist)

            if let rows {
                LyricsPlayerBlock(rows: rows)
            }

            switch (music.track.hasTiming, scrubber) {
            case (_, .none):
                EmptyView()
            case (false, _):
                noTimingHint
            case (true, .stacked):
                stackedScrubber
            case (true, .inline):
                inlineScrubber
            }

            transport(fittingWidth: width)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Nic nie gra")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text(hintText)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
            MediaPlayerButtons()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var hintText: String {
        if music.isNowPlayingDeprecated, settings.mediaController == .nowPlaying {
            return "macOS nie udostępnia już systemowych informacji „Teraz odtwarzane”. Wybierz Muzykę lub Spotify w Ustawieniach."
        }
        return "Zacznij coś odtwarzać. Źródło: \(settings.mediaController.title)."
    }

    // MARK: Scrubber

    /// Shown instead of the scrubber when the backend cannot report a
    /// position — a browser tab whose page we are not allowed to query. It
    /// stays on one line and leads somewhere, rather than being a paragraph of
    /// instructions sitting permanently under every track.
    @ViewBuilder
    private var noTimingHint: some View {
        if !settings.showPageAccessHint {
            // Switched off in settings: leave the space blank rather than
            // repeating something the user has already said they know about.
            Color.clear.frame(height: Metrics.hint)
        } else if music.activeControllerType == .browser {
            Button {
                SettingsWindowController.shared.show(tab: .media)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                    Text("Włącz dostęp do stron, aby zobaczyć postęp")
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .bold))
                }
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.4))
                .frame(height: Metrics.hint)
            }
            .buttonStyle(NotchPressStyle(scale: 0.97))
        } else {
            Text("Brak informacji o pozycji")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.4))
                .frame(height: Metrics.hint)
        }
    }

    private var slider: some View {
        PlaybackSlider(color: sliderColor)
    }

    private var elapsedLabel: some View {
        PlaybackTimeLabel(remaining: false)
    }

    private var remainingLabel: some View {
        PlaybackTimeLabel(remaining: true)
    }

    /// Times under the bar, as the player has always had them.
    private var stackedScrubber: some View {
        VStack(spacing: 0) {
            slider
            HStack {
                elapsedLabel
                Spacer()
                remainingLabel
            }
            .font(.system(size: 9))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.45))
            .frame(height: Metrics.times)
        }
    }

    /// Times either side of the bar: one row instead of two, for short tiles.
    private var inlineScrubber: some View {
        HStack(spacing: 5) {
            elapsedLabel
                .frame(minWidth: 24, alignment: .leading)
            slider
            remainingLabel
                .frame(minWidth: 24, alignment: .trailing)
        }
        .font(.system(size: 9))
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.45))
        .frame(height: Metrics.inlineScrubber)
    }

    private var sliderColor: Color {
        settings.sliderColor.resolved(albumArt: music.artworkColor, accent: settings.accentColor)
    }

    // MARK: Transport

    /// The tile's narrowest width leaves this column about 150 points, which
    /// seven buttons only just fit; narrower still and the extras go first —
    /// shuffle and repeat, then the thumbs — so play, previous and next are
    /// never the ones to be cut.
    private func transport(fittingWidth width: CGFloat) -> some View {
        let variants: [(shuffleAndRepeat: Bool, likes: Bool)] = [(true, true), (false, true), (false, false)]
        let chosen = variants.first { transportWidth(shuffleAndRepeat: $0.shuffleAndRepeat, likes: $0.likes) <= width + 0.01 }
            ?? (shuffleAndRepeat: false, likes: false)
        return transportRow(shuffleAndRepeat: chosen.shuffleAndRepeat, likes: chosen.likes)
            .frame(height: Metrics.transport)
    }

    /// What `transportRow` needs at its narrowest, with its spacers at zero.
    private func transportWidth(shuffleAndRepeat: Bool, likes: Bool) -> CGFloat {
        var width = Metrics.width(glyph: Metrics.skipGlyph) * 2 + Metrics.width(glyph: Metrics.playGlyph)
        if likes, music.track.likeStatus != nil { width += Metrics.width(glyph: Metrics.smallGlyph) * 2 }
        if shuffleAndRepeat, settings.showShuffleAndRepeat { width += Metrics.width(glyph: Metrics.smallGlyph) * 2 }
        return width
    }

    private func transportRow(shuffleAndRepeat: Bool, likes: Bool) -> some View {
        // One glass group, so a hovered button blends with its neighbours.
        NotchGlassGroup {
            transportButtons(shuffleAndRepeat: shuffleAndRepeat, likes: likes)
        }
    }

    private func transportButtons(shuffleAndRepeat: Bool, likes: Bool) -> some View {
        let likeStatus = likes ? music.track.likeStatus : nil
        let extras = shuffleAndRepeat && settings.showShuffleAndRepeat
        return HStack(spacing: 0) {
            if let likeStatus {
                HoverButton(
                    systemName: likeStatus == .liked ? "hand.thumbsup.fill" : "hand.thumbsup",
                    size: Metrics.smallGlyph,
                    padding: Metrics.padding,
                    isActive: likeStatus == .liked,
                    tint: settings.accentColor
                ) { music.toggleLike() }
            }
            if extras {
                HoverButton(
                    systemName: "shuffle",
                    size: Metrics.smallGlyph,
                    padding: Metrics.padding,
                    isActive: music.track.isShuffled,
                    tint: settings.accentColor
                ) { music.toggleShuffle() }
            }

            Spacer(minLength: 0)

            HoverButton(systemName: "backward.fill", size: Metrics.skipGlyph, padding: Metrics.padding) {
                music.previousTrack()
            }

            HoverButton(
                systemName: music.isPlaying ? "pause.fill" : "play.fill",
                size: Metrics.playGlyph,
                padding: Metrics.padding,
                resting: true
            ) { music.togglePlayPause() }

            HoverButton(systemName: "forward.fill", size: Metrics.skipGlyph, padding: Metrics.padding) {
                music.nextTrack()
            }

            Spacer(minLength: 0)

            if extras {
                HoverButton(
                    systemName: music.track.repeatMode.symbol,
                    size: Metrics.smallGlyph,
                    padding: Metrics.padding,
                    isActive: music.track.repeatMode != .off,
                    tint: settings.accentColor,
                    badge: music.track.repeatMode.badge
                ) { music.cycleRepeat() }
            }

            if let likeStatus {
                HoverButton(
                    systemName: likeStatus == .disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                    size: Metrics.smallGlyph,
                    padding: Metrics.padding,
                    isActive: likeStatus == .disliked,
                    tint: settings.accentColor
                ) { music.toggleDislike() }
            }
        }
    }
}

/// The scrubber bar. It observes `PlaybackClock` on its own so the playhead's
/// five updates a second redraw the bar, not the whole player around it.
private struct PlaybackSlider: View {
    let color: Color

    @ObservedObject private var music = MusicManager.shared
    @ObservedObject private var playback = MusicManager.shared.playback

    var body: some View {
        NotchSlider(
            value: $playback.elapsed,
            range: 0 ... max(music.track.duration, 1),
            color: color,
            height: 4,
            isEnabled: music.track.duration > 0,
            onEditingChanged: { editing in
                music.isScrubbing = editing
                if !editing {
                    music.seek(to: playback.elapsed)
                }
            }
        )
        .frame(height: PlayerControls.Metrics.slider)
        // The slider can leave mid-drag (the source changes to one without
        // timing, the player is replaced by the empty state); its drag then
        // never ends, and a stuck flag would freeze the playhead and lyrics.
        // Only written when set: an assignment publishes whether or not the
        // value changed, and this runs for every slider that goes away.
        .onDisappear { if music.isScrubbing { music.isScrubbing = false } }
    }
}

/// Elapsed or remaining time, isolated for the same reason as the bar.
private struct PlaybackTimeLabel: View {
    let remaining: Bool

    @ObservedObject private var music = MusicManager.shared
    @ObservedObject private var playback = MusicManager.shared.playback

    var body: some View {
        Text((remaining ? max(music.track.duration - playback.elapsed, 0) : playback.elapsed).playbackTimestamp)
    }
}

// MARK: - Mirror

struct MirrorPane: View {
    @ObservedObject private var webcam = WebcamManager.shared
    @EnvironmentObject private var settings: Settings

    var body: some View {
        Group {
            if webcam.isRunning {
                CameraPreview(session: webcam.session)
            } else if webcam.hasCamera, webcam.isAccessBlocked {
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    ZStack {
                        Color.white.opacity(0.08)
                        VStack(spacing: 5) {
                            Image(systemName: "video.slash")
                                .font(.system(size: 18))
                                .foregroundStyle(.white.opacity(0.6))
                            Text("Włącz dostęp do kamery")
                                .font(.system(size: 9))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .padding(.horizontal, 6)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Fun Notch nie ma dostępu do kamery. Kliknij, aby otworzyć Prywatność i ochrona → Kamera.")
            } else {
                ZStack {
                    Color.white.opacity(0.08)
                    VStack(spacing: 5) {
                        Image(systemName: webcam.hasCamera ? "web.camera" : "video.slash")
                            .font(.system(size: 18))
                            .foregroundStyle(.white.opacity(0.6))
                        Text(webcam.hasCamera ? "Lusterko" : "Brak kamery")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(mirrorShape)
        .overlay(mirrorShape.stroke(Color.white.opacity(0.1), lineWidth: 1))
        .onAppear { webcam.start() }
        .onDisappear { webcam.stop() }
    }

    private var mirrorShape: AnyShape {
        settings.mirrorShape == .circle
            ? AnyShape(Circle())
            : AnyShape(RoundedRectangle(cornerRadius: 12))
    }
}
