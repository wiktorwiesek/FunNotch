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
}

@MainActor
final class IslandCenter: ObservableObject {
    static let shared = IslandCenter()

    @Published private(set) var current: Island?

    private init() {}

    /// Shows `island` on every notch that is currently closed. A newer island
    /// replaces one still on screen.
    func post(_ island: Island) {
        current = island
        DiagnosticLog.write("island", island.title + island.detail)
        NotchWindowManager.shared.broadcast { viewModel in
            guard viewModel.notchState == .closed else { return }
            viewModel.showExpandingView(type: .island, value: 0, icon: island.symbol, duration: island.duration)
        }
    }
}
