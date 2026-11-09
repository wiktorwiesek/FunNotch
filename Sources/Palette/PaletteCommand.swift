import SwiftUI

/// One entry the command palette can run. Feature managers register their own
/// commands from `start()` so the palette needs no knowledge of them.
struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    var subtitle: String? = nil
    let symbol: String
    var keywords: [String] = []
    let perform: @MainActor () -> Void
}

/// Shared list of palette commands. Registering an id that already exists
/// replaces it, which keeps repeated `start()` calls harmless.
@MainActor
final class PaletteCommandRegistry: ObservableObject {
    static let shared = PaletteCommandRegistry()

    @Published private(set) var commands: [PaletteCommand] = []

    func register(_ command: PaletteCommand) {
        if let index = commands.firstIndex(where: { $0.id == command.id }) {
            commands[index] = command
        } else {
            commands.append(command)
        }
    }
}
