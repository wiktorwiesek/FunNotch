//
//  NotchTools.swift
//  FunNotch
//
//  The tools that live outside the notch's tabs (the teleprompter, the
//  terminal, the screen assistant, the window switcher, the eyedropper, the
//  mixer, zipping the shelf), as one menu behind a button in the open notch's
//  header: nothing in the app has to be found by knowing its name.
//

import AppKit

@MainActor
enum NotchTools {
    /// Built when the button is clicked, so the ticks say what is showing now.
    /// `close` puts the notch away, for the tools that work outside it.
    static func menu(close: @escaping @MainActor () -> Void) -> [PointerMenu.Item] {
        func item(
            _ title: String, _ symbol: String, checked: Bool = false, enabled: Bool = true,
            closes: Bool = true, _ perform: @escaping @MainActor () -> Void
        ) -> PointerMenu.Item {
            PointerMenu.Item(title: title, symbol: symbol, isChecked: checked, isEnabled: enabled) {
                if closes { close() }
                perform()
            }
        }
        let terminal = NotchTerminalController.shared
        return [
            item("Teleprompter", "play.rectangle.fill", checked: TeleprompterController.shared.isVisible) {
                TeleprompterController.shared.toggle()
            },
            item("Tekst telepromptera…", "square.and.pencil") {
                TeleprompterEditorController.shared.show()
            },
            .separator,
            item("Terminal", "terminal", checked: terminal.isVisible) {
                terminal.toggle()
            },
            item("Zakończ sesję terminala", "xmark.rectangle", enabled: terminal.hasSession) {
                terminal.endSession()
            },
            .separator,
            item("Zapytaj o fragment ekranu", "viewfinder") {
                ScreenAssistantController.shared.begin()
            },
            item("Przełącz okno", "macwindow.on.rectangle") {
                WindowSwitcher.showMenu()
            },
            item("Pipeta kolorów", "eyedropper.halffull") {
                ColorPicker.pick()
            },
            .separator,
            // These two happen in the notch, so it stays.
            item("Mikser dźwięku", "slider.vertical.3", closes: false) {
                MediaOverlayState.shared.present(.mixer)
            },
            item("Spakuj Półkę do ZIP", "doc.zipper", enabled: !ShelfManager.shared.items.isEmpty, closes: false) {
                let shelf = ShelfManager.shared
                let chosen = shelf.items.filter { shelf.selection.contains($0.id) }
                ShelfConverter.shared.run(.zip, on: chosen.isEmpty ? shelf.items : chosen)
            },
        ]
    }
}
