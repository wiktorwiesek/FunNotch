//
//  NotchTools.swift
//  FunNotch
//
//  The tools that live outside the notch's tabs (the teleprompter, the
//  terminal, the screen assistant, the window switcher, the command palette),
//  as one menu behind a button in the open notch's header. They were reachable
//  only through the palette, which nobody finds without being told about it.
//

import AppKit

@MainActor
enum NotchTools {
    /// Built when the button is clicked, so the ticks say what is showing now.
    /// `done` runs after whichever tool was picked.
    static func menu(done: @escaping @MainActor () -> Void) -> [PointerMenu.Item] {
        func item(
            _ title: String, _ symbol: String, checked: Bool = false, _ perform: @escaping @MainActor () -> Void
        ) -> PointerMenu.Item {
            PointerMenu.Item(title: title, symbol: symbol, isChecked: checked) {
                done()
                perform()
            }
        }
        return [
            item("Teleprompter", "play.rectangle.fill", checked: TeleprompterController.shared.isVisible) {
                TeleprompterController.shared.toggle()
            },
            item("Tekst telepromptera…", "square.and.pencil") {
                TeleprompterEditorController.shared.show()
            },
            item("Terminal", "terminal", checked: NotchTerminalController.shared.isVisible) {
                NotchTerminalController.shared.toggle()
            },
            item("Zapytaj o fragment ekranu", "viewfinder") {
                ScreenAssistantController.shared.begin()
            },
            item("Przełącz okno", "macwindow") {
                PaletteController.shared.show(scope: .windows)
            },
            item("Paleta komend  ⌃⌥K", "command") {
                PaletteController.shared.show()
            },
        ]
    }
}
