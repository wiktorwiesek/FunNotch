//
//  ShelfClipExtras.swift
//  FunNotch
//
//  Startup and settings for the shelf and clipboard extras: smart clipboard
//  actions, clipboard OCR search and the shelf converter / zip tools.
//

import SwiftUI
import Vision

/// Preferences for the extras. They live in UserDefaults under `extras.shelfclip.`
/// and default to on, so a missing key means "enabled".
enum ShelfClipPrefs {
    static let smartActionsKey = "extras.shelfclip.smartActions"
    static let linkTitlesKey = "extras.shelfclip.linkTitles"
    static let ocrKey = "extras.shelfclip.ocr"

    static var smartActions: Bool { value(smartActionsKey) }
    static var linkTitles: Bool { value(linkTitlesKey) }
    static var ocr: Bool { value(ocrKey) }

    private static func value(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}

@MainActor
enum ShelfClipExtras {
    private static var started = false

    /// Idempotent: views and the integrator may both call it.
    static func start() {
        guard !started else { return }
        started = true

        // A conversion that was running when the app quit leaves its staging
        // folder behind; nothing else would ever clean it up.
        ShelfManager.shared.purgeStaging()
        _ = ClipboardOCRIndex.shared
        _ = LinkTitleStore.shared

        // Image entries restored before this ran never reach record(), so give
        // whatever is already in the history a chance to be indexed.
        for entry in ClipboardManager.shared.entries {
            ClipboardOCRIndex.shared.index(entry)
        }

        PaletteCommandRegistry.shared.register(PaletteCommand(
            id: "shelfclip.zip-selection",
            title: "Spakuj Półkę do ZIP",
            subtitle: "Zaznaczone elementy albo cała Półka",
            symbol: "doc.zipper",
            keywords: ["zip", "archiwum", "spakuj", "półka", "polka"],
            perform: {
                let shelf = ShelfManager.shared
                let chosen = shelf.items.filter { shelf.selection.contains($0.id) }
                ShelfConverter.shared.run(.zip, on: chosen.isEmpty ? shelf.items : chosen)
            }
        ))
    }
}

struct ShelfClipExtrasSettings: View {
    @AppStorage(ShelfClipPrefs.smartActionsKey) private var smartActions = true
    @AppStorage(ShelfClipPrefs.linkTitlesKey) private var linkTitles = true
    @AppStorage(ShelfClipPrefs.ocrKey) private var ocr = true

    @ObservedObject private var titles = LinkTitleStore.shared

    private var ocrLanguages: String {
        let request = VNRecognizeTextRequest()
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let wanted = [("pl-PL", "polski"), ("en-US", "angielski")].filter { supported.contains($0.0) }
        return wanted.map(\.1).joined(separator: " i ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard(
                title: "Schowek",
                footer: "Rozpoznawanie tekstu działa na tym Macu, bez wysyłania obrazów. Wynik jest tylko w pamięci i znika razem z wpisem."
            ) {
                SettingsToggle(
                    title: "Inteligentne akcje",
                    subtitle: "Linki, kolory, adresy e-mail, telefony, numery EAN i NIP dostają własne przyciski.",
                    symbol: "wand.and.stars",
                    tint: SettingsStyle.blue,
                    isOn: $smartActions
                )
                SettingsToggle(
                    title: "Tytuły stron przy linkach",
                    subtitle: "Raz pobiera początek strony, żeby pokazać jej tytuł. Pomija linki wyglądające na jednorazowe.",
                    symbol: "link",
                    tint: SettingsStyle.blue,
                    isOn: $linkTitles
                )
                .disabled(!smartActions)
                SettingsToggle(
                    title: "Szukaj też w tekście z obrazów",
                    subtitle: "Wyszukiwarka schowka znajdzie słowa ze skopiowanych zrzutów i zdjęć.",
                    symbol: "text.viewfinder",
                    tint: SettingsStyle.blue,
                    isOn: $ocr
                )
                if ocr {
                    SettingsStatus(
                        text: ocrLanguages.isEmpty
                            ? "Rozpoznawanie tekstu nie obsługuje tu polskiego ani angielskiego."
                            : "Języki rozpoznawania: \(ocrLanguages).",
                        symbol: ocrLanguages.isEmpty ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                        tint: ocrLanguages.isEmpty ? .orange : .green
                    )
                }
                SettingsRow(
                    title: "Zapamiętane tytuły stron",
                    subtitle: Polish.count(titles.cachedCount, "wpis", "wpisy", "wpisów")
                ) {
                    Button("Wyczyść") { titles.clearCache() }
                        .disabled(titles.cachedCount == 0)
                }
            }

            SettingsCard(
                title: "Półka",
                footer: "Wyniki trafiają z powrotem na Półkę jako nowe elementy. Wszystko dzieje się lokalnie."
            ) {
                SettingsStatus(
                    text: "Klik prawym na elemencie: Konwertuj (obrazy, PDF, wideo, dźwięk), Usuń tło, Spakuj do ZIP, Rozpakuj.",
                    symbol: "arrow.triangle.2.circlepath",
                    tint: SettingsStyle.blue
                )
                SettingsStatus(
                    text: "Aby spakować kilka elementów, zaznacz je z ⌘ i wybierz „Spakuj” na pasku Półki.",
                    symbol: "doc.zipper",
                    tint: SettingsStyle.blue
                )
            }
        }
    }
}
