//
//  NotchViewModel.swift
//  FunNotch
//
//  One instance backs one notch window. It owns the open/closed state, the
//  measured geometry for its display, and the transient "sneak peek" and HUD
//  overlays that the collapsed notch shows.
//

import AppKit
import Combine
import SwiftUI

/// A transient message shown in the collapsed notch (track change, HUD, …).
struct SneakPeek: Equatable {
    var show: Bool = false
    var type: SneakContentType = .none
    var value: CGFloat = 0
    var icon: String = ""
    /// Identity of this particular announcement. A new one replays the
    /// entrance; repeated volume presses keep the same one, so the HUD reacts
    /// to each press instead of starting over.
    var token = UUID()
}

/// What the agents are up to, as far as the collapsed notch cares.
struct AgentActivity: Equatable {
    var active = 0
    var waiting = false
}

/// How a working agent is shown beside the cutout.
enum AgentPresentation {
    case none
    /// A small light at the inner edge of the right wing, beside whatever
    /// else is there.
    case pip
    /// Nothing else is beside the cutout, so the agent gets both wings.
    case wings
    /// A cat already in the row carries it, so the row gets no light of its
    /// own: the one that lives beside the cutout (see `CatResident`), or the
    /// music's.
    case cat
}

@MainActor
final class NotchViewModel: ObservableObject {
    /// Identifier of the display this notch is pinned to.
    let screenIdentifier: String

    @Published private(set) var notchState: NotchState = .closed
    @Published var currentTab: NotchTab = .home

    /// Collapsed measurements for this display.
    @Published var closedNotchSize: CGSize = CGSize(width: 185, height: 32)

    /// True while the pointer is inside the notch's hover region.
    @Published var isHovering: Bool = false

    /// A drag is in flight somewhere on screen, so the notch offers a drop target.
    @Published var dragDetectorTargeting: Bool = false
    @Published var isDropTargeted: Bool = false

    /// Hidden because fullscreen media is playing on this display.
    @Published var hiddenForFullscreen: Bool = false

    @Published var sneakPeek = SneakPeek()
    @Published var expandingView = SneakPeek()

    /// Set while the notch should refuse to close (menus, popovers, drags).
    @Published var pinnedOpen: Bool = false

    private var hoverWorkItem: DispatchWorkItem?
    private var closeWorkItem: DispatchWorkItem?
    private var sneakPeekWorkItem: DispatchWorkItem?
    private var expandingViewWorkItem: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    private let settings = Settings.shared

    /// True when the collapsed notch should widen to show album art and the
    /// spectrum on either side of the hardware cutout.
    @Published private(set) var showsMusicActivity = false

    /// Mirrored from the focus manager so geometry can react to it.
    @Published private(set) var focusIsActive = false

    /// What the on-screen widgets reported they need, per side.
    @Published private(set) var measuredWidgetWidths: [NotchSide: CGFloat] = [:]

    /// Mirrored from the agent sessions manager so geometry can react to it.
    @Published private(set) var agentActivity = AgentActivity()

    /// The pointer is in the menu-bar strip, off the cutout itself (see
    /// `NotchWindowController.isPointerOverMenuBarWings`). Set by the window
    /// manager from the pointer events it already receives, and released only
    /// after a short delay so a stray flick off the bar does not make the
    /// wings flicker back under the pointer.
    @Published private(set) var pointerOverMenuBar = false
    private var wingsRestoreWorkItem: DispatchWorkItem?
    /// How long the pointer must stay off the menu bar before the wings return.
    static let wingsRestoreDelay: TimeInterval = 0.4

    init(screen: NSScreen?) {
        screenIdentifier = screen?.displayIdentifier ?? ""
        closedNotchSize = measureClosedNotch(for: screen)

        NotificationCenter.default.publisher(for: .notchGeometryChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshGeometry() }
            .store(in: &cancellables)

        MusicManager.shared.$track
            .receive(on: RunLoop.main)
            .sink { [weak self] track in
                guard let self else { return }
                let shouldShow = !track.isEmpty
                guard shouldShow != self.showsMusicActivity else { return }
                withAnimation(.notchContent) { self.showsMusicActivity = shouldShow }
            }
            .store(in: &cancellables)

        AgentSessionsManager.shared.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions in
                guard let self else { return }
                let next = AgentActivity(
                    active: sessions.filter(\.status.isActive).count,
                    waiting: sessions.contains(where: \.status.isWaiting)
                )
                guard next != self.agentActivity else { return }
                withAnimation(.notchContent) { self.agentActivity = next }
            }
            .store(in: &cancellables)

        FocusManager.shared.$isActive
            .receive(on: RunLoop.main)
            .sink { [weak self] active in
                guard let self, self.focusIsActive != active else { return }
                withAnimation(.notchContent) { self.focusIsActive = active }
                // Starting a session while the game is open would otherwise
                // leave it running behind a tab that no longer exists.
                if active, self.currentTab == .game {
                    FocusTabState.shared.mode = .focus
                    withAnimation(.notchContent) { self.currentTab = .focus }
                }
            }
            .store(in: &cancellables)
    }

    var screen: NSScreen? {
        NSScreen.screen(withIdentifier: screenIdentifier) ?? NSScreen.main
    }

    func refreshGeometry() {
        closedNotchSize = measureClosedNotch(for: screen)
    }

    // MARK: - Open / close

    func open() {
        guard notchState == .closed else { return }
        cancelPendingClose()
        withAnimation(.notchOpen) {
            notchState = .open
        }
        if settings.openShelfByDefault, settings.shelfEnabled, dragDetectorTargeting {
            currentTab = .shelf
        }
        performHaptic()
    }

    func close() {
        guard notchState == .open else { return }
        guard !pinnedOpen else { return }
        withAnimation(.notchClose) {
            notchState = .closed
        }
        // Reset back to the default tab so the next open is predictable,
        // unless the user has asked for the last tab to be remembered.
        if !settings.rememberLastTab {
            currentTab = .home
        }
        sneakPeek.show = false
    }

    func toggle() {
        notchState == .open ? close() : open()
    }

    // MARK: - Hover driven behaviour

    /// Called by the mouse tracker whenever the pointer enters or leaves the
    /// notch's active region.
    func setHovering(_ hovering: Bool) {
        guard isHovering != hovering else { return }
        isHovering = hovering

        if hovering {
            cancelPendingClose()
            guard settings.openNotchOnHover, notchState == .closed else { return }
            let work = DispatchWorkItem { [weak self] in
                // A pointer that came for a banner's button does not open the
                // notch: that would take the button from under it, and after
                // the press, the keyboard from the reply being typed.
                guard let self, self.isHovering, !self.isShowingActionBanner else { return }
                self.open()
            }
            hoverWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + settings.minimumHoverDuration, execute: work)
        } else {
            hoverWorkItem?.cancel()
            hoverWorkItem = nil
            guard notchState == .open, !pinnedOpen else { return }
            // Small grace period so brushing past the edge does not slam it shut.
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.isHovering else { return }
                self.close()
            }
            closeWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }
    }

    // MARK: - Menu bar tucking

    /// Reports whether the pointer is over the menu bar beside the cutout.
    /// Entering collapses at once — the same move event must already see the
    /// small hover rect, or brushing past a wing would open the notch — while
    /// leaving waits `wingsRestoreDelay`.
    func setPointerOverMenuBar(_ over: Bool) {
        if over && settings.hideWingsAtMenuBar {
            wingsRestoreWorkItem?.cancel()
            wingsRestoreWorkItem = nil
            guard !pointerOverMenuBar else { return }
            withAnimation(.notchContent) { pointerOverMenuBar = true }
        } else {
            // Called on every pointer move; bail out cheaply when idle.
            guard pointerOverMenuBar, wingsRestoreWorkItem == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.wingsRestoreWorkItem = nil
                withAnimation(.notchContent) { self.pointerOverMenuBar = false }
            }
            wingsRestoreWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.wingsRestoreDelay, execute: work)
        }
    }

    /// True while the closed notch is drawn as the plain cutout, wings and
    /// all live activities beside it dropped. Never during a drag — the drop
    /// zone has to stay a big target — and never for the open notch.
    var wingsTucked: Bool {
        pointerOverMenuBar && settings.hideWingsAtMenuBar
            && notchState == .closed && !dragDetectorTargeting
    }

    /// True while an announcement with a button in its wing is on screen
    /// ("Odpowiedz", "Kopiuj kod", "Wysuń"). The button has to take the
    /// pointer where it is drawn, so for as long as it is there the wings
    /// are not given back to the menu bar and hovering does not open the notch.
    var isShowingActionBanner: Bool {
        guard isShowingStandardHUD, expandingView.type == .island, let island = IslandCenter.shared.current else { return false }
        return island.action != nil || island.onTap != nil
    }

    /// Does what a click on the island on screen is for, and takes the island
    /// away. False when there is none, or it has nothing of its own to do.
    func performIslandTap() -> Bool {
        guard isShowingStandardHUD, expandingView.type == .island, let tap = IslandCenter.shared.current?.onTap
        else { return false }
        tap()
        // The pointer came for the island, not to open the notch: a hover
        // still counting down must not open it now that the island is gone.
        hoverWorkItem?.cancel()
        hoverWorkItem = nil
        expandingViewWorkItem?.cancel()
        withAnimation(.smooth) { expandingView.show = false }
        return true
    }

    /// Size of the area that takes the pointer (hover and clicks), as opposed
    /// to the drawn size. Announcements (HUD, track peek) still play in full
    /// while tucked — they are transient and the user asked for them — but
    /// only the plain cutout is interactive, so they never swallow clicks
    /// meant for the menus beneath their wings. One with a button is the
    /// exception: a button nobody can press is no button.
    var interactiveSize: CGSize {
        wingsTucked && !isShowingActionBanner ? closedNotchSize : contentSize
    }

    /// Sets state directly, bypassing animation. Used by the snapshot renderer.
    func setPreviewState(_ state: NotchState) {
        notchState = state
    }

    /// Forces the music live activity on, for snapshots.
    func setPreviewMusicActivity(_ visible: Bool) {
        showsMusicActivity = visible
    }

    /// Forces the focus live activity on, for snapshots.
    func setPreviewFocusActivity(_ active: Bool) {
        focusIsActive = active
    }

    /// Forces the menu-bar tuck, for snapshots.
    func setPreviewPointerOverMenuBar(_ over: Bool) {
        pointerOverMenuBar = over
    }

    /// Forces the agent live activity, for snapshots.
    func setPreviewAgentActivity(_ activity: AgentActivity) {
        agentActivity = activity
    }

    private func cancelPendingClose() {
        closeWorkItem?.cancel()
        closeWorkItem = nil
    }

    private func performHaptic() {
        guard settings.enableHaptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    // MARK: - Transient overlays

    /// Shows the compact "now playing" peek shown on track changes.
    func showSneakPeek(type: SneakContentType, value: CGFloat = 0, icon: String = "", duration: Double? = nil) {
        sneakPeekWorkItem?.cancel()
        withAnimation(.smooth) {
            sneakPeek = SneakPeek(show: true, type: type, value: value, icon: icon)
        }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.smooth) { self?.sneakPeek.show = false }
        }
        sneakPeekWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (duration ?? settings.waitInterval), execute: work)
    }

    /// Shows the wider HUD strip used for volume / brightness / backlight.
    func showExpandingView(type: SneakContentType, value: CGFloat, icon: String, duration: Double = 2.0) {
        expandingViewWorkItem?.cancel()
        var next = SneakPeek(show: true, type: type, value: value, icon: icon)
        if type == .hud, expandingView.show, expandingView.type == .hud {
            next.token = expandingView.token
        }
        withAnimation(.smooth) {
            expandingView = next
        }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.smooth) { self?.expandingView.show = false }
        }
        expandingViewWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    // MARK: - Derived geometry

    /// Width added on each side of the cutout for the music live activity.
    static let musicActivityInset: CGFloat = MusicPlayerImageSizes.size.closed.width + 12
    /// Width the countdown needs beside the cutout: "45 min" is about 38
    /// points, and it needs a margin against the rounded corner.
    static let focusActivityInset: CGFloat = 54
    /// The agent light beside other activities, and its width with a count.
    static let agentPipWidth: CGFloat = 32
    static let agentPipWidthWithCount: CGFloat = 43
    /// Each wing when a working agent has the cutout to itself.
    static let agentWingInset: CGFloat = 46

    /// True when the announcement strip is showing below the cutout.
    var isShowingStandardHUD: Bool {
        expandingView.show && notchState == .closed
    }

    /// True when the notch is standing in as a drop target for a live drag.
    /// A drag is an active gesture, so it outranks any transient HUD.
    var isShowingDropZone: Bool {
        notchState == .closed && dragDetectorTargeting && settings.shelfEnabled
    }

    /// True when the collapsed notch is carrying the focus countdown.
    var showsFocusActivity: Bool {
        focusIsActive && settings.focusShowInClosedNotch
    }

    /// True when the peek strip below the cutout is showing a track change.
    var isShowingStandardMusicPeek: Bool {
        sneakPeek.show && sneakPeek.type == .music && settings.sneakPeekStyle == .standard
    }

    /// The widgets to show beside the cutout right now, if any.
    var activeWidgets: (leading: [NotchWidget], trailing: [NotchWidget]) {
        guard notchState == .closed, settings.idleWidgetsEnabled else { return ([], []) }
        return (settings.idleLeftWidgets, settings.idleRightWidgets)
    }

    /// Whether the artwork and spectrum take their places beside the cutout.
    /// Something can be playing without them being drawn — the user may have
    /// handed that space to the widgets instead.
    var showsClosedMediaActivity: Bool {
        showsMusicActivity && settings.closedMediaDisplay.showsMedia
    }

    /// Widgets only get the stage when nothing more urgent is using it — except
    /// for music, where the user decides who yields.
    var isShowingWidgets: Bool {
        guard notchState == .closed else { return false }
        guard !isShowingDropZone, !isShowingStandardHUD else { return false }
        guard !isShowingStandardMusicPeek else { return false }

        let widgets = activeWidgets
        guard !widgets.leading.isEmpty || !widgets.trailing.isEmpty else { return false }

        // A focus countdown still wins outright; it owns the right-hand side.
        guard !showsFocusActivity else { return false }
        guard showsMusicActivity else { return true }
        return settings.closedMediaDisplay.showsWidgets
    }

    /// True when a Claude Code or Codex session is working or waiting.
    var showsAgentActivity: Bool {
        settings.agentActivityEnabled && agentActivity.active > 0
    }

    /// Where the agent light goes, given what else is beside the cutout.
    var agentPresentation: AgentPresentation {
        guard notchState == .closed, showsAgentActivity else { return .none }
        guard !isShowingDropZone, !isShowingStandardHUD, !isShowingStandardMusicPeek else { return .none }
        let sidesTaken = isShowingWidgets || showsClosedMediaActivity || showsFocusActivity
        guard sidesTaken else { return .wings }
        return showsResidentCat || musicCatCarriesAgents ? .cat : .pip
    }

    var agentPipWidth: CGFloat {
        agentActivity.active > 1 ? Self.agentPipWidthWithCount : Self.agentPipWidth
    }

    /// The spectrum's place beside the cutout: wider by a count's worth while
    /// its cat stands in for more than one busy agent.
    var closedVisualizerWidth: CGFloat {
        let counts = musicCatCarriesAgents && agentPresentation == .cat && agentActivity.active > 1
        return Self.musicActivityInset + (counts ? Self.agentPipWidthWithCount - Self.agentPipWidth : 0)
    }

    /// Space taken beside the cutout by the live activities, left and right,
    /// plus whatever the decorations (timer mascot, idle animation) add.
    var closedActivityInsets: (leading: CGFloat, trailing: CGFloat) {
        decorAdjustedInsets(baseClosedActivityInsets)
    }

    /// The live activities' own space, before any decoration.
    var baseClosedActivityInsets: (leading: CGFloat, trailing: CGFloat) {
        if isShowingDropZone { return (110, 110) }

        var leading: CGFloat = 0
        var trailing: CGFloat = 0

        if showsClosedMediaActivity, !isShowingStandardMusicPeek {
            leading = Self.musicActivityInset
            trailing = closedVisualizerWidth
        }

        if showsFocusActivity {
            // The countdown takes the right side; the left keeps the artwork,
            // or picks up the focus glyph when nothing is playing.
            trailing = Self.focusActivityInset
            leading = max(leading, Self.musicActivityInset)
        }

        if isShowingWidgets {
            let widgets = activeWidgets
            // Prefer what the widget actually measured; the declared width is
            // only a first guess for the very first layout pass. Added rather
            // than assigned, so widgets sharing the row with the artwork and
            // spectrum get their own space instead of overlapping them.
            leading += widgets.leading.isEmpty
                ? 0
                : (measuredWidgetWidths[.leading] ?? Self.estimatedWidth(of: widgets.leading))
            trailing += widgets.trailing.isEmpty
                ? 0
                : (measuredWidgetWidths[.trailing] ?? Self.estimatedWidth(of: widgets.trailing))
        }

        switch agentPresentation {
        case .none, .cat:
            // The cat's room is a decoration's, added with the others.
            break
        case .pip:
            trailing += agentPipWidth
        case .wings:
            leading = max(leading, Self.agentWingInset)
            trailing = max(trailing, Self.agentWingInset)
        }

        return (leading, trailing)
    }

    /// Width of each wing of the collapsed notch. The notch is drawn centred
    /// on the camera, so both wings take the wider side's width, and the
    /// narrower side's content sits against the camera with black beyond it.
    ///
    /// The two sides used to be added together instead. Whenever they differed,
    /// the gap left for the camera landed off-centre by half the difference,
    /// and whatever sat against the camera on the wider side ended up under
    /// it. Beside a clock and a battery, the working-agent light was hidden
    /// that way.
    var closedWingWidth: CGFloat {
        guard !wingsTucked else { return 0 }
        let insets = closedActivityInsets
        // The window has a fixed width. Past it, a notch would have its sides
        // sliced off by the window's edge instead of ending in its rounded
        // corners, so extra widgets overflow into the clip rather than widen it.
        let room = max((windowSize.width - closedNotchSize.width) / 2, 0)
        return min(max(insets.leading, insets.trailing), room)
    }

    private static func estimatedWidth(of widgets: [NotchWidget]) -> CGFloat {
        widgets.reduce(0) { $0 + $1.estimatedWidth } + CGFloat(max(widgets.count - 1, 0)) * 12
    }

    /// Widths reported by the widgets currently on screen.
    func updateMeasuredWidgetWidths(_ widths: [NotchSide: CGFloat]) {
        // While tucked the widgets are gone and report nothing; keeping the
        // last measurement avoids a width jump when they come back.
        guard !wingsTucked else { return }
        let widgets = activeWidgets
        var filtered = widths
        if widgets.leading.isEmpty { filtered[.leading] = nil }
        if widgets.trailing.isEmpty { filtered[.trailing] = nil }

        guard filtered != measuredWidgetWidths else { return }
        withAnimation(.notchContent) { measuredWidgetWidths = filtered }
    }

    /// Content size for the current state, excluding shadow padding.
    var contentSize: CGSize {
        switch notchState {
        case .closed:
            var size = closedNotchSize

            if isShowingDropZone {
                size.height += 26
            } else if isShowingStandardHUD {
                let style = LiveActivityMetrics.style(for: expandingView.type)
                size.width = max(size.width + style.wing * 2, style.minimumWidth)
                size.height += style.chin
                return size
            } else if isShowingStandardMusicPeek {
                let style = LiveActivityMetrics.banner
                size.width = max(size.width + style.wing * 2, style.minimumWidth)
                size.height += style.chin
                return size
            }

            size.width += closedWingWidth * 2
            return size

        case .open:
            return openNotchSize
        }
    }

    /// Development aid: `--render-preview` runs on whatever display this Mac
    /// has, which is usually one with a notch, so island mode could never be
    /// captured without this.
    var previewForceIsland = false

    /// True when this panel is floating on a display with no physical notch.
    var isIsland: Bool {
        guard settings.nonNotchStyle == .island else { return false }
        if previewForceIsland { return true }
        guard let screen else { return false }
        return !screen.hasPhysicalNotch
    }

    /// How far the island sits below the top of the screen. Zero on a real
    /// notch, where the panel is flush with the hardware.
    var islandTopGap: CGFloat {
        isIsland ? settings.islandTopGap : 0
    }

    var topCornerRadius: CGFloat {
        notchState == .open ? cornerRadiusInsets.opened.top : cornerRadiusInsets.closed.top
    }

    var bottomCornerRadius: CGFloat {
        notchState == .open ? cornerRadiusInsets.opened.bottom : cornerRadiusInsets.closed.bottom
    }
}

extension Animation {
    /// Spring used when the notch expands — slightly bouncy, like the reference.
    static let notchOpen = Animation.spring(response: 0.4, dampingFraction: 0.75, blendDuration: 0.2)
    /// Slightly faster and flatter on the way back in.
    static let notchClose = Animation.spring(response: 0.32, dampingFraction: 0.85, blendDuration: 0.1)
    static let notchContent = Animation.spring(response: 0.35, dampingFraction: 0.8)
}
