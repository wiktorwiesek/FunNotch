//
//  WindowSnapSettings.swift
//  FunNotch
//
//  The "Okna" section of the Extras page: both window features and the
//  Accessibility permission they share.
//

import SwiftUI

struct WindowSnapSettings: View {
    @ObservedObject private var manager = WindowSnapManager.shared
    @ObservedObject private var dragger = ModifierWindowDragger.shared

    @AppStorage(WindowSnapKeys.notchSnap) private var notchSnap = false
    @AppStorage(WindowSnapKeys.modifierDrag) private var modifierDrag = false
    @AppStorage(WindowSnapKeys.modifier) private var modifierRaw = WindowDragModifier.controlOption.rawValue

    /// The permission is changed in System Settings, so the page re-checks it
    /// while it is on screen instead of waiting for a notification.
    private let recheck = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var modifier: WindowDragModifier {
        WindowDragModifier(rawValue: modifierRaw) ?? .controlOption
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            accessCard
            notchSnapCard
            modifierDragCard
        }
        .onReceive(recheck) { _ in manager.apply() }
        .onChange(of: notchSnap) { manager.apply() }
        .onChange(of: modifierDrag) { manager.apply() }
        .onChange(of: modifierRaw) { manager.apply() }
    }

    // MARK: - Accessibility

    private var accessCard: some View {
        SettingsCard(
            title: "Okna",
            footer: "Przesuwanie cudzych okien działa przez uprawnienie Dostępność. Po każdej przebudowie "
                + "programu z nowym podpisem macOS może je cofnąć — wtedy włącz je ponownie."
        ) {
            SettingsRow(
                title: "Dostępność",
                subtitle: manager.accessibilityGranted
                    ? "Fun Notch może przesuwać i zmieniać rozmiar okien innych programów."
                    : "Bez tego okien innych programów nie da się przesuwać, więc obie funkcje poniżej nie działają.",
                symbol: "figure.stand",
                tint: SettingsStyle.blue
            ) {
                if manager.accessibilityGranted {
                    Label("Przyznana", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                } else {
                    Button("Zezwól…") { manager.requestAccess() }
                }
            }
        }
    }

    // MARK: - Notch snapping

    private var notchSnapCard: some View {
        SettingsCard(
            footer: "Strefy pojawiają się tylko przy notchu, na środku górnej krawędzi. Boki i rogi ekranu zostają "
                + "wolne dla programów takich jak Rectangle, więc oba rozwiązania można mieć włączone naraz. "
                + "Rectangle ma własną akcję na górnej krawędzi, dlatego upuszczaj okno na strefie, nie przy samej krawędzi."
        ) {
            SettingsToggle(
                title: "Przyciąganie okien do notcha",
                subtitle: "Przeciągnij okno za pasek tytułu pod notch i upuść je na strefie: połowa, trzecia część, "
                    + "ćwiartka lub cały obszar roboczy ekranu, bez trybu pełnoekranowego.",
                symbol: "rectangle.split.2x2.fill",
                tint: SettingsStyle.indigo,
                isOn: $notchSnap
            )
            if notchSnap {
                if manager.accessibilityGranted {
                    SettingsStatus(
                        text: "Działa. Strefy uwzględniają pasek menu i Dock na ekranie, nad którym puszczasz okno.",
                        symbol: "checkmark.circle.fill",
                        tint: .green
                    )
                } else {
                    missingAccessLine
                }
            }
        }
    }

    // MARK: - Modifier dragging

    private var modifierDragCard: some View {
        SettingsCard {
            SettingsToggle(
                title: "Przesuwanie i zmiana rozmiaru z klawiszem",
                subtitle: "Przytrzymaj klawisze i przeciągnij okno w dowolnym miejscu, aby je przesunąć. "
                    + "Prawy przycisk myszy zmienia rozmiar od najbliższego rogu.",
                symbol: "arrow.up.left.and.arrow.down.right",
                tint: SettingsStyle.teal,
                isOn: $modifierDrag
            )
            if modifierDrag {
                SettingsPicker(title: "Klawisze", selection: $modifierRaw) {
                    ForEach(WindowDragModifier.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                if !manager.accessibilityGranted {
                    missingAccessLine
                } else if dragger.isActive {
                    SettingsStatus(
                        text: "Działa. Przytrzymaj \(modifier.glyphs) i przeciągnij okno; z prawym przyciskiem zmienisz rozmiar.",
                        symbol: "checkmark.circle.fill",
                        tint: .green
                    )
                } else {
                    SettingsStatus(
                        text: dragger.lastError ?? "Nie działa — nie udało się uruchomić przechwytywania myszy.",
                        symbol: "exclamationmark.triangle.fill",
                        tint: .orange
                    )
                }
            }
        }
    }

    private var missingAccessLine: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Włączone, ale nie działa: brakuje uprawnienia Dostępność.")
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Zezwól…") { manager.requestAccess() }
                .controlSize(.small)
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
