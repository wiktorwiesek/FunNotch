//
//  IslandCenter.swift
//  FunNotch
//
//  One general-purpose announcement for everything that is not music, power,
//  a download, a screenshot, a device, focus or an agent: Caps Lock, a drive
//  to eject, a colour picked, a message, a script finishing. Features post an
//  `Island`; the collapsed notch shows it in the same wing-and-chin layout as
//  every other live activity, with at most one button in the right wing.
//

import AppKit
import SwiftUI

struct IslandAction {
    /// Short, it sits in a wing: "Wysuń", "Kopiuj", "Odpowiedz".
    let title: String
    let perform: @MainActor () -> Void
}

struct Island: Identifiable {
    let id = UUID()
    /// SF Symbol shown in the left wing.
    var symbol: String
    var tint: Color = .white
    /// Bold part of the chin line, e.g. the app or device name.
    var title: String
    /// Softer rest of the chin line, e.g. " · podłączono". May be empty.
    var detail: String = ""
    /// Short value in the right wing when there is no action, e.g. "80%".
    var trailing: String?
    var action: IslandAction?
    /// Seconds on screen.
    var duration: Double = 3
    /// A passing remark ("Skopiowano"): never replaces another activity that
    /// is already on screen, it is simply dropped.
    var isQuiet = false
    /// Hook for the cat companion: set by islands that want it to peek in.
    var mascot = false
}

@MainActor
final class IslandCenter: ObservableObject {
    static let shared = IslandCenter()

    @Published private(set) var current: Island?

    private init() {}

    /// Shows `island` on every notch that is currently closed. A newer island
    /// replaces one still on screen, unless it is quiet.
    func post(_ island: Island) {
        // Only the symbol: island text can carry notification content and one-time codes.
        DiagnosticLog.write("island", island.symbol)
        // A quiet island must not rewrite `current` unless some notch really
        // shows it: the banner on screen reads it.
        if !island.isQuiet { current = island }
        NotchWindowManager.shared.broadcast { viewModel in
            guard viewModel.notchState == .closed else { return }
            if island.isQuiet {
                guard !viewModel.expandingView.show, !viewModel.sneakPeek.show else { return }
                current = island
            }
            viewModel.showExpandingView(type: .island, value: 0, icon: island.symbol, duration: island.duration)
        }
    }
}
