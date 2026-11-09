//
//  PaletteSettings.swift
//  FunNotch
//
//  The cards for the command palette, meant to sit inside the "Dodatki" page:
//  the hot key, text snippets, search engines, Shortcuts, translation, the
//  calculator and the eyedropper.
//

import ApplicationServices
import SwiftUI

struct PaletteSettings: View {
    @ObservedObject private var hotKey = PaletteHotKey.shared
    @ObservedObject private var snippets = SnippetStore.shared
    @ObservedObject private var engines = SearchEngineStore.shared
    @ObservedObject private var shortcuts = PaletteShortcuts.shared
    @ObservedObject private var history = CalculatorHistory.shared

    @State private var hotKeyEnabled = PaletteHotKey.shared.isEnabled
    @State private var accessibilityGranted = AXIsProcessTrusted()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            paletteCard
            snippetsCard
            enginesCard
            shortcutsCard
            toolsCard
        }
        .onAppear {
            PaletteExtras.start()
            accessibilityGranted = AXIsProcessTrusted()
            shortcuts.refresh()
        }
        // The permission is granted in System Settings, so look again when the
        // user comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = AXIsProcessTrusted()
        }
    }

    // MARK: Palette

    private var paletteCard: some View {
        SettingsCard(
            title: "Paleta komend",
            footer: "Wyszukuje polecenia, karty notcha, aplikacje, skróty, schowek i pliki. Przedrostki: = kalkulator, t tłumaczenie, s szablony tekstu, f tylko pliki, g/yt/a/ddg/gh/w wyszukiwarki."
        ) {
            SettingsToggle(
                title: "Skrót ⌃⌥K",
                subtitle: "Otwiera paletę z każdej aplikacji, bez żadnych uprawnień.",
                symbol: "command.square.fill",
                tint: SettingsStyle.indigo,
                isOn: Binding(
                    get: { hotKeyEnabled },
                    set: { value in
                        hotKeyEnabled = value
                        hotKey.isEnabled = value
                    }
                )
            )
            switch hotKey.status {
            case .active:
                SettingsStatus(text: "Skrót jest aktywny.", symbol: "checkmark.circle.fill", tint: SettingsStyle.green)
            case .off:
                SettingsStatus(text: "Skrót jest wyłączony.", symbol: "minus.circle.fill", tint: SettingsStyle.gray)
            case .failed:
                SettingsStatus(
                    text: "Nie udało się zarejestrować ⌃⌥K. Prawdopodobnie zajmuje go inna aplikacja.",
                    symbol: "exclamationmark.triangle.fill", tint: SettingsStyle.orange
                )
            }
            SettingsRow(title: "Otwórz paletę teraz") {
                Button("Otwórz") { PaletteController.shared.show() }
            }
        }
    }

    // MARK: Snippets

    private var snippetsCard: some View {
        SettingsCard(
            title: "Szablony tekstu",
            footer: "W palecie wpisz „s” i nazwę szablonu. Tekst trafia do schowka i, jeśli Fun Notch ma uprawnienie Dostępność, od razu do aplikacji, w której pracujesz."
        ) {
            if snippets.items.isEmpty {
                SettingsRow(title: "Brak szablonów", subtitle: "Dodaj pierwszy, na przykład odpowiedź na częste pytanie klienta.")
            }
            ForEach($snippets.items) { $snippet in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField("Nazwa", text: $snippet.name)
                            .textFieldStyle(.roundedBorder)
                        Button(role: .destructive) {
                            snippets.items.removeAll { $0.id == snippet.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("Usuń szablon")
                    }
                    TextEditor(text: $snippet.text)
                        .font(.system(size: 12))
                        .frame(height: 64)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            SettingsRow(title: "Nowy szablon") {
                Button("Dodaj") { snippets.add() }
            }
            if accessibilityGranted {
                SettingsStatus(
                    text: "Uprawnienie Dostępność jest przyznane, szablony wklejają się same.",
                    symbol: "checkmark.circle.fill", tint: SettingsStyle.green
                )
            } else {
                SettingsRow(
                    title: "Wklejanie od razu",
                    subtitle: "Bez uprawnienia Dostępność szablon tylko trafia do schowka, a Ty wklejasz go ⌘V."
                ) {
                    Button("Przyznaj uprawnienie") { PaletteClipboard.requestAccessibility() }
                }
            }
        }
    }

    // MARK: Search engines

    private var enginesCard: some View {
        SettingsCard(
            title: "Wyszukiwarki",
            footer: "Adres musi zawierać %s w miejscu szukanej frazy, na przykład https://example.com/?q=%s. Własny przedrostek ma pierwszeństwo przed wbudowanym."
        ) {
            SettingsRow(
                title: "Wbudowane",
                subtitle: SearchEngineStore.builtIn.map { "\($0.prefix) – \($0.name)" }.joined(separator: " · ")
            )
            ForEach($engines.custom) { $engine in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField("Nazwa", text: $engine.name)
                            .textFieldStyle(.roundedBorder)
                        TextField("Przedrostek", text: $engine.prefix)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                        Button(role: .destructive) {
                            engines.custom.removeAll { $0.id == engine.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("Usuń wyszukiwarkę")
                    }
                    TextField("Adres z %s", text: $engine.template)
                        .textFieldStyle(.roundedBorder)
                    if !engine.isValid {
                        Text("Uzupełnij nazwę, przedrostek bez spacji i adres z %s.")
                            .font(.system(size: 11))
                            .foregroundStyle(SettingsStyle.orange)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            SettingsRow(title: "Nowa wyszukiwarka") {
                Button("Dodaj") { engines.add() }
            }
        }
    }

    // MARK: Shortcuts

    private var shortcutsCard: some View {
        SettingsCard(
            title: "Skróty Apple",
            footer: "Skróty z aplikacji Skróty pojawiają się w palecie po wpisaniu ich nazwy. Wynik uruchomienia widać w notchu."
        ) {
            SettingsRow(
                title: "Dostępne skróty",
                subtitle: shortcutsSubtitle,
                symbol: "bolt.square.fill",
                tint: SettingsStyle.pink
            ) {
                Button("Odśwież") { shortcuts.refresh() }
                    .disabled(shortcuts.isLoading)
            }
        }
    }

    private var shortcutsSubtitle: String {
        if let problem = shortcuts.problem { return problem }
        if shortcuts.isLoading && shortcuts.names.isEmpty { return "Wczytuję…" }
        return Polish.count(shortcuts.names.count, "skrót", "skróty", "skrótów")
    }

    // MARK: Translation, calculator, eyedropper

    private var toolsCard: some View {
        SettingsCard(
            title: "Tłumacz, kalkulator i pipeta",
            footer: "Tłumaczenie „t tekst” działa na urządzeniu: polski na angielski, inne języki na polski. Przy pierwszym użyciu macOS może poprosić o pobranie języka."
        ) {
            if PaletteTranslation.isOnDeviceSupported {
                SettingsStatus(
                    text: "Tłumaczenie na urządzeniu jest dostępne.",
                    symbol: "checkmark.circle.fill", tint: SettingsStyle.green
                )
            } else {
                SettingsStatus(
                    text: "Tłumaczenie na urządzeniu wymaga macOS 15. Zamiast niego otworzy się Tłumacz Google.",
                    symbol: "info.circle.fill", tint: SettingsStyle.orange
                )
            }
            SettingsRow(
                title: "Historia kalkulatora",
                subtitle: history.entries.isEmpty
                    ? "Pusta"
                    : Polish.count(history.entries.count, "wynik", "wyniki", "wyników")
            ) {
                Button("Wyczyść") { history.clear() }
                    .disabled(history.entries.isEmpty)
            }
            SettingsRow(
                title: "Pipeta kolorów",
                subtitle: "Kliknięty kolor jest kopiowany jako HEX.",
                symbol: "eyedropper.halffull",
                tint: SettingsStyle.teal
            ) {
                Button("Wybierz kolor") { ColorPicker.pick() }
            }
        }
    }
}
