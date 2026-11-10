//
//  ScreenAssistantExtras.swift
//  FunNotch
//
//  "Asystent ekranu": pick a region of the screen and ask an AI about it.
//
//  The feature is invisible until used. `start()` only registers one palette
//  command; the crosshair, the panel and the child process all come into
//  existence when that command runs and are gone when the panel closes (see
//  ScreenAssistantController). The AI is a command-line client the user
//  already has, so Fun Notch stores and asks for no key.
//

import SwiftUI

enum ScreenAssistantExtras {
    @MainActor
    static func start() {
        PaletteCommandRegistry.shared.register(PaletteCommand(
            id: "screenassistant.ask",
            title: "Zapytaj o fragment ekranu",
            subtitle: "Zaznacz obszar i zapytaj AI",
            symbol: "viewfinder",
            keywords: ["ai", "ekran", "zrzut", "zapytaj", "asystent", "screen"],
            perform: { ScreenAssistantController.shared.begin() }
        ))
    }
}

struct ScreenAssistantSettings: View {
    private enum ClientStatus {
        case checking
        case found(String)
        case customMissing(String)
        case notFound
    }

    @AppStorage(ScreenAssistantPrefs.modelKey) private var model = ""
    @AppStorage(ScreenAssistantPrefs.instructionKey) private var instruction = ""
    @AppStorage(ScreenAssistantPrefs.commandKey) private var command = ""
    @State private var status = ClientStatus.checking

    var body: some View {
        SettingsCard(
            title: "Asystent ekranu",
            footer: "Zaznaczony fragment ekranu jest wysyłany do usługi AI skonfigurowanej w tym kliencie, razem z pytaniami z okna asystenta; dopóki nie zadasz pytania, nic nie jest wysyłane. Fun Notch nie przechowuje ani nie pyta o klucze API. Zrzut robi systemowe polecenie screencapture uruchamiane przez aplikację, dlatego potrzebne jest uprawnienie Nagrywanie ekranu (macOS zapyta przy pierwszym użyciu). Obraz leży w prywatnym folderze tymczasowym i jest usuwany po zamknięciu okna. Uruchom z palety poleceń: „Zapytaj o fragment ekranu”."
        ) {
            statusLine
            SettingsRow(
                title: "Model",
                subtitle: "Opcjonalnie. Puste pole to model domyślny klienta."
            ) {
                TextField("domyślny", text: $model)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
            SettingsRow(
                title: "Instrukcja",
                subtitle: "Dodawana przed każdym pytaniem. Puste pole przywraca domyślną: „\(ScreenAssistantPrefs.defaultInstruction)”"
            ) {
                TextField("domyślna", text: $instruction, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1 ... 4)
                    .frame(width: 220)
            }
            SettingsRow(
                title: "Własne polecenie",
                subtitle: "Zamiast omp i gemini. Użyj {image} (ścieżka zrzutu) i {prompt} (pytanie); cudzysłowy grupują argumenty, polecenie nie przechodzi przez powłokę."
            ) {
                TextField("np. mycli --image {image} {prompt}", text: $command)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
        }
        .task(id: command) {
            // Typing a command should not look the program up on every key.
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            status = await currentStatus()
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status {
        case .checking:
            SettingsStatus(text: "Szukam klienta AI…", symbol: "clock.fill", tint: .secondary)
        case .found(let name):
            SettingsStatus(text: "Używany klient: \(name).", symbol: "checkmark.circle.fill", tint: .green)
        case .customMissing(let program):
            SettingsStatus(
                text: "Nie znaleziono programu „\(program)” z własnego polecenia.",
                symbol: "exclamationmark.triangle.fill",
                tint: .orange
            )
        case .notFound:
            SettingsStatus(
                text: "Nie znaleziono klienta AI. Zainstaluj omp albo gemini (Gemini CLI) lub wpisz własne polecenie poniżej.",
                symbol: "exclamationmark.triangle.fill",
                tint: .orange
            )
        }
    }

    private func currentStatus() async -> ClientStatus {
        switch await ScreenAssistantLocator.resolve() {
        case .found(let resolved):
            return .found("\(resolved.displayName) (\(resolved.executable))")
        case .customMissing(let program):
            return .customMissing(program)
        case .notFound:
            return .notFound
        }
    }
}
