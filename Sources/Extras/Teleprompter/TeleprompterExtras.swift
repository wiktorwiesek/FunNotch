//
//  TeleprompterExtras.swift
//  FunNotch
//
//  Entry point and settings card of the teleprompter. `start()` only adds two
//  commands to the palette; the panel, the editor, the audio engine and the
//  script do not exist until one of those commands (or a settings button) is
//  used, and everything is released again when the panel or the window closes.
//

import SwiftUI

enum TeleprompterExtras {
    @MainActor
    static func start() {
        PaletteCommandRegistry.shared.register(PaletteCommand(
            id: "teleprompter.toggle",
            title: "Teleprompter: pokaż lub ukryj",
            subtitle: "Tekst pod kamerą, niewidoczny w udostępnianiu ekranu",
            symbol: "play.rectangle.fill",
            keywords: ["teleprompter", "prompter", "tekst", "przemówienie", "czytanie", "kamera"],
            perform: { TeleprompterController.shared.toggle() }
        ))
        PaletteCommandRegistry.shared.register(PaletteCommand(
            id: "teleprompter.edit",
            title: "Teleprompter: edytuj tekst",
            symbol: "square.and.pencil",
            keywords: ["teleprompter", "prompter", "skrypt", "tekst", "edytor"],
            perform: { TeleprompterEditorController.shared.show() }
        ))
    }
}

struct TeleprompterSettings: View {
    @ObservedObject private var store = TeleprompterStore.shared

    var body: some View {
        SettingsCard(
            title: "Teleprompter",
            footer: "Panel wisi pod notchem i jest niewidoczny w udostępnianiu ekranu, zrzutach i nagraniach. Podążanie za głosem rozpoznaje mowę na tym Macu, jeśli macOS ma model dla języka (inaczej robią to serwery Apple); mikrofon działa tylko, gdy teleprompter czyta z włączoną tą opcją. Skrypt jest zapisany lokalnie w folderze Fun Notch."
        ) {
            SettingsSlider(
                title: "Tempo (słów na minutę)",
                value: $store.wordsPerMinute,
                range: TeleprompterStore.speedRange,
                step: 5
            ) { "\(Int($0))" }

            SettingsSlider(
                title: "Rozmiar tekstu (pt)",
                value: $store.fontSize,
                range: TeleprompterStore.fontSizeRange,
                step: 1
            ) { "\(Int($0))" }

            SettingsToggle(
                title: "Podążaj za głosem",
                subtitle: "Tekst przesuwa się, gdy czytasz na głos, a przy ciszy czeka. Bez zgody na mikrofon przewija się według tempa.",
                symbol: "mic.fill",
                tint: SettingsStyle.red,
                isOn: $store.voiceFollow
            )

            SettingsToggle(
                title: "Odbicie lustrzane",
                subtitle: "Odwraca tekst poziomo, do czytania przez szybę lustrzaną.",
                symbol: "arrow.left.and.right",
                tint: SettingsStyle.purple,
                isOn: $store.mirrored
            )

            SettingsRow(
                title: "Skrypt",
                subtitle: "Spacja czyta lub wstrzymuje, strzałki ↑ ↓ zmieniają tempo, ← cofa, Esc zamyka (po kliknięciu panelu).",
                symbol: "text.alignleft",
                tint: SettingsStyle.blue
            ) {
                HStack(spacing: 8) {
                    Button("Edytuj…") { TeleprompterEditorController.shared.show() }
                    Button("Pokaż teleprompter") { TeleprompterController.shared.show() }
                }
            }
        }
    }
}
