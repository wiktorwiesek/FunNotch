//
//  CatResident.swift
//  FunNotch
//
//  The cat as a pet that lives in the closed notch: always there, left of the
//  cutout, doing what fits the moment. It types while an agent works and waves
//  when one waits (it is then the agent light, count included), bobs while
//  music plays, sits and looks about while someone is at the Mac, and curls up
//  asleep once nobody has touched it for a few minutes.
//
//  Where it shows and the room it takes are decided in `DecorLayout`; rows
//  that already have the cat in another role do not get a second one.
//

import AppKit
import SwiftUI

/// Whether anyone is at the keyboard or pointer. Asked of the system every few
/// seconds, which needs no permission, and only while the screen is on.
@MainActor
final class CatPresence: ObservableObject {
    static let shared = CatPresence()

    /// Nothing has been typed, clicked or moved for `dozeAfter` seconds.
    @Published private(set) var isAway = false

    static let dozeAfter: TimeInterval = 180

    private var timer: Timer?

    private init() {
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            guard !SystemActivityMonitor.isScreenIdle else { return }
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 1.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    private func refresh() {
        // ~0 is kCGAnyInputEventType, which Swift does not import.
        guard let anyInput = CGEventType(rawValue: ~0) else { return }
        let away = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput) >= Self.dozeAfter
        if away != isAway { isAway = away }
    }

    /// Fixes the answer, for snapshots.
    func injectPreview(away: Bool) {
        timer?.invalidate()
        timer = nil
        isAway = away
    }
}

/// The cat at the inner edge of the left wing.
struct ResidentCat: View {
    @EnvironmentObject private var viewModel: NotchViewModel
    @ObservedObject private var agents = AgentSessionsManager.shared
    @ObservedObject private var music = MusicManager.shared
    @ObservedObject private var presence = CatPresence.shared

    static let size: CGFloat = 20
    /// Clear of the camera housing, the way the widgets beside it are.
    static let cameraGap: CGFloat = 9
    /// Against the widgets' own inset, or the notch's rounded corner.
    static let outerGap: CGFloat = 4
    static let width = size + cameraGap + outerGap

    var body: some View {
        let carriesAgents = viewModel.agentPresentation == .cat
        HStack(spacing: 2) {
            if carriesAgents, agents.activeCount > 1 {
                AgentCountLabel(count: agents.activeCount)
            }
            CatView(state: mood.state, size: Self.size, tint: mood.tint)
        }
        .padding(.trailing, Self.cameraGap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .help(carriesAgents ? agents.activitySummary : "")
        .transition(.scale(scale: 0.4).combined(with: .opacity))
    }

    private var mood: (state: CatState, tint: Color) {
        if viewModel.agentPresentation == .cat {
            if agents.waitingCount > 0 { return (.waiting, AgentPalette.waiting) }
            return (.working, (agents.headline?.agent ?? .claude).tint)
        }
        if music.isPlaying { return (.music, CatPalette.musicDefault) }
        return (presence.isAway ? .sleeping : .awake, .white.opacity(0.7))
    }
}
