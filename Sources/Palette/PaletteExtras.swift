//
//  PaletteExtras.swift
//  FunNotch
//
//  Startup for the command palette and the tools around it.
//

import AppKit
import Foundation

@MainActor
enum PaletteExtras {
    /// Safe to call repeatedly (settings calls it from `onAppear` too).
    static func start() {
        PaletteHotKey.shared.start()
        PaletteAppIndex.shared.refresh()
        PaletteShortcuts.shared.refresh()

        PaletteCommandRegistry.shared.register(PaletteCommand(
            id: "palette.colorPicker",
            title: "Pipeta kolorów",
            subtitle: "Kliknij kolor na ekranie, a HEX trafi do schowka",
            symbol: "eyedropper.halffull",
            keywords: ["kolor", "color", "hex", "pipeta", "eyedropper", "rgb"],
            perform: { ColorPicker.pick() }
        ))
        PaletteCommandRegistry.shared.register(PaletteCommand(
            id: "palette.translateClipboard",
            title: "Przetłumacz schowek",
            subtitle: "Tłumaczy skopiowany tekst w palecie",
            symbol: "character.bubble.fill",
            keywords: ["tlumacz", "translate", "tłumaczenie", "schowek"],
            perform: {
                let text = NSPasteboard.general.string(forType: .string)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                // Newlines would end the query field's single line, and a long
                // paragraph is not what a quick translation is for.
                let single = text.replacingOccurrences(of: "\n", with: " ")
                PaletteController.shared.show(query: "t " + String(single.prefix(400)))
            }
        ))
    }
}
