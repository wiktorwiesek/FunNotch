//
//  NotchGestures.swift
//  FunNotch
//
//  Two-finger swipes on the notch: down opens it, up closes it, and sideways
//  goes to the next or previous track (or steps ten seconds, if asked).
//
//  Only scroll events that are already on their way to the notch's own panel
//  are looked at, through a local monitor. A global one would have the window
//  server hand the app every scroll made anywhere on the Mac, which is the
//  kind of cost the pointer tracking already pays and nothing here is worth.
//

import AppKit
import SwiftUI

@MainActor
enum NotchGestures {
    static let openKey = "extras.gestures.open"
    static let mediaKey = "extras.gestures.media"
    static let seekKey = "extras.gestures.seek"

    private static var openEnabled: Bool { UserDefaults.standard.object(forKey: openKey) as? Bool ?? true }
    private static var mediaEnabled: Bool { UserDefaults.standard.object(forKey: mediaKey) as? Bool ?? true }
    /// Sideways steps ten seconds instead of changing the track.
    private static var seeks: Bool { UserDefaults.standard.bool(forKey: seekKey) }

    /// Points a swipe has to travel before it counts.
    private static let threshold: CGFloat = 36
    static let seekStep: TimeInterval = 10

    private static var monitor: Any?
    private static var travelled = CGSize.zero
    /// One swipe does one thing, however far the fingers go on.
    private static var spent = false

    /// Safe to call repeatedly: one monitor.
    static func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            MainActor.assumeIsolated { handle(event) } ? nil : event
        }
    }

    enum Swipe: Equatable { case down, up, left, right }

    /// Which way the fingers went once they have gone far enough, with the
    /// axis they did not mean ignored. `natural` is the system's "natural
    /// scrolling": with it on, the deltas already follow the fingers.
    static func swipe(travelled: CGSize, natural: Bool) -> Swipe? {
        let horizontal = abs(travelled.width)
        let vertical = abs(travelled.height)
        guard max(horizontal, vertical) >= threshold else { return nil }
        let sign: CGFloat = natural ? 1 : -1
        if vertical > horizontal * 1.5 { return travelled.height * sign > 0 ? .down : .up }
        if horizontal > vertical * 1.5 { return travelled.width * sign > 0 ? .right : .left }
        return nil
    }

    /// True when the event was a swipe's and must not reach what is under it.
    private static func handle(_ event: NSEvent) -> Bool {
        // A trackpad or a Magic Mouse, fingers still down: a wheel has no
        // phases, and the glide after the fingers lift is not a gesture.
        guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty, !event.phase.isEmpty,
              let model = NotchWindowManager.shared.viewModel(owning: event.window)
        else { return false }

        if event.phase.contains(.began) {
            travelled = .zero
            spent = false
        }
        // The rest of a swipe that has done its work stays the swipe's.
        guard !spent else { return true }
        travelled.width += event.scrollingDeltaX
        travelled.height += event.scrollingDeltaY
        guard let swipe = swipe(travelled: travelled, natural: event.isDirectionInvertedFromDevice) else {
            // Nothing in the closed notch scrolls, so nothing is taken from
            // anyone by holding the event; the open one has lists.
            return model.notchState == .closed
        }
        guard perform(swipe, on: model, event: event) else { return false }
        spent = true
        return true
    }

    private static func perform(_ swipe: Swipe, on model: NotchViewModel, event: NSEvent) -> Bool {
        let open = model.notchState == .open
        // In the open notch a list under the pointer owns the scroll.
        if open, isOverScrollView(event) { return false }

        switch swipe {
        case .down:
            guard openEnabled, !open else { return false }
            model.open()
        case .up:
            guard openEnabled, open, !model.pinnedOpen else { return false }
            model.close()
        case .left, .right:
            let music = MusicManager.shared
            guard mediaEnabled, !music.track.isEmpty, !open || model.currentTab == .home else { return false }
            // Left brings the next one in, as on a phone; scrubbing follows the fingers.
            if seeks {
                let target = music.displayedElapsed + (swipe == .right ? seekStep : -seekStep)
                music.seek(to: min(max(target, 0), max(music.track.duration, 0)))
            } else if swipe == .left {
                music.nextTrack()
            } else {
                music.previousTrack()
            }
            if Settings.shared.enableHaptics {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }
        return true
    }

    private static func isOverScrollView(_ event: NSEvent) -> Bool {
        var view = event.window?.contentView?.hitTest(event.locationInWindow)
        while let current = view {
            if current is NSScrollView { return true }
            view = current.superview
        }
        return false
    }
}

/// The gestures' section of the settings.
struct GestureSettings: View {
    @AppStorage(NotchGestures.openKey) private var opens = true
    @AppStorage(NotchGestures.mediaKey) private var media = true
    @AppStorage(NotchGestures.seekKey) private var seeks = false

    var body: some View {
        SettingsCard(
            title: "Gesty gładzika",
            footer: "Gesty działają tylko wtedy, gdy wskaźnik jest nad notchem. Na liście w otwartym notchu przewijanie należy do listy."
        ) {
            SettingsToggle(
                title: "Otwieranie i zamykanie",
                subtitle: "Dwa palce w dół otwierają notch, w górę go zamykają.",
                symbol: "arrow.up.and.down",
                tint: SettingsStyle.blue,
                isOn: $opens
            )
            SettingsToggle(
                title: "Sterowanie muzyką",
                subtitle: "Dwa palce w lewo lub w prawo nad notchem.",
                symbol: "arrow.left.and.right",
                tint: SettingsStyle.pink,
                isOn: $media
            )
            if media {
                SettingsToggle(
                    title: "Przewijaj o 10 sekund",
                    subtitle: "Zamiast zmieniać utwór, gest przesuwa odtwarzanie do przodu lub do tyłu.",
                    symbol: "goforward.10",
                    tint: SettingsStyle.gray,
                    isOn: $seeks
                )
            }
        }
    }
}
