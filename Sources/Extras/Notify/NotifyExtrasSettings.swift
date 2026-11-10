//
//  NotifyExtrasSettings.swift
//  FunNotch
//
//  Settings for the notification islands and the Powiadomienia tab, shown on
//  the "Dodatki" page. Each source says plainly whether it is working and what
//  macOS permission it is waiting for.
//

import SwiftUI

struct NotifyExtrasSettings: View {
    @ObservedObject private var center = NotifyCenter.shared
    @ObservedObject private var watcher = NotificationBannerWatcher.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard(
                title: "Powiadomienia w notchu",
                footer: "Fun Notch czyta baner powiadomienia przez Dostępność, bo macOS nie udostępnia innego sposobu. Zastąpiony baner nie pojawia się na ekranie, ale powiadomienie zostaje w Centrum powiadomień; alerty, które czekają na odpowiedź, pokazują się jak zwykle. Nic nie jest wysyłane poza ten komputer."
            ) {
                SettingsToggle(
                    title: "Czytaj powiadomienia",
                    subtitle: "Pokazuje nadawcę i treść w notchu, gdy pojawi się baner.",
                    symbol: "bell.badge.fill",
                    tint: SettingsStyle.red,
                    isOn: $center.captureEnabled
                )
                if center.captureEnabled {
                    SettingsToggle(
                        title: "Wyspa w notchu",
                        subtitle: "Pokazuje powiadomienie w zamkniętym notchu.",
                        symbol: "capsule.fill",
                        tint: SettingsStyle.green,
                        isOn: $center.islandsEnabled,
                        preview: previewIsland
                    )
                    if center.islandsEnabled {
                        SettingsToggle(
                            title: "Zastępuj banery systemowe",
                            subtitle: "Gdy notch pokazuje powiadomienie, baner macOS nie wysuwa się w rogu ekranu.",
                            symbol: "rectangle.on.rectangle.slash",
                            tint: SettingsStyle.purple,
                            isOn: $center.hidesBanners
                        )
                    }
                    if center.islandsEnabled {
                        SettingsPicker(
                            title: "Z których aplikacji",
                            symbol: "app.badge.fill",
                            tint: SettingsStyle.blue,
                            selection: $center.islandScope
                        ) {
                            ForEach(NotifyCenter.IslandScope.allCases) { scope in
                                Text(scope.title).tag(scope)
                            }
                        }
                        SettingsToggle(
                            title: "Pokazuj treść",
                            subtitle: "Po wyłączeniu wyspa mówi tylko, od kogo jest powiadomienie.",
                            symbol: "text.alignleft",
                            tint: SettingsStyle.gray,
                            isOn: $center.showPreview
                        )
                        SettingsToggle(
                            title: "Kody jednorazowe",
                            subtitle: "Gdy w powiadomieniu jest kod, wyspa ma przycisk „Kopiuj kod”.",
                            symbol: "key.fill",
                            tint: SettingsStyle.yellow,
                            isOn: $center.codeDetection
                        )
                    }
                    accessibilityStatus
                }
            }

            SettingsCard(
                title: "Lustro powiadomień",
                footer: "Karta Powiadomienia pokazuje ostatnie 50 powiadomień: te złapane od uruchomienia Fun Notch i, jeśli to możliwe, te, które trzyma Centrum powiadomień."
            ) {
                SettingsToggle(
                    title: "Karta Powiadomienia",
                    subtitle: "Dodaje kartę z listą powiadomień do otwartego notcha.",
                    symbol: "bell.fill",
                    tint: SettingsStyle.orange,
                    isOn: $center.showsTab
                )
                SettingsToggle(
                    title: "Czytaj bazę Centrum powiadomień",
                    subtitle: "Dodaje do listy powiadomienia sprzed uruchomienia aplikacji.",
                    symbol: "internaldrive.fill",
                    tint: SettingsStyle.indigo,
                    isOn: $center.readsDatabase
                )
                if center.readsDatabase {
                    databaseStatus
                }
            }
        }
    }

    private func previewIsland() {
        IslandCenter.shared.post(Island(
            symbol: "message.fill", tint: .green,
            title: "Anna", detail: " · Będę za dziesięć minut",
            action: IslandAction(title: "Otwórz") {},
            duration: 4,
            cat: .texting
        ))
    }

    @ViewBuilder
    private var accessibilityStatus: some View {
        switch watcher.state {
        case .watching:
            SettingsStatus(
                text: "Działa — banery są odczytywane.",
                symbol: "checkmark.circle.fill",
                tint: .green
            )
        case .needsAccessibility:
            SettingsStatus(
                text: "Brak uprawnienia Dostępność. Włącz Fun Notch w Ustawieniach systemowych → Prywatność i ochrona → Dostępność.",
                symbol: "exclamationmark.triangle.fill",
                tint: .orange
            )
            SettingsRow(title: "Uprawnienie Dostępność") {
                Button("Zezwól…") { center.openAccessibilitySettings() }
            }
        case .waitingForNotificationCenter:
            SettingsStatus(
                text: "Centrum powiadomień nie odpowiada. Fun Notch spróbuje ponownie za chwilę.",
                symbol: "clock.fill",
                tint: .secondary
            )
        case .stopped:
            EmptyView()
        }
    }

    @ViewBuilder
    private var databaseStatus: some View {
        switch center.databaseState {
        case .active:
            SettingsStatus(
                text: "Działa — baza jest czytana co kilka sekund.",
                symbol: "checkmark.circle.fill",
                tint: .green
            )
        case .needsFullDiskAccess:
            SettingsStatus(
                text: "Brak Pełnego dostępu do dysku. Włącz Fun Notch w Ustawieniach systemowych → Prywatność i ochrona → Pełny dostęp do dysku, a potem uruchom aplikację ponownie. Bez tego lista pokazuje tylko to, co Fun Notch zobaczy na żywo.",
                symbol: "exclamationmark.triangle.fill",
                tint: .orange
            )
            SettingsRow(title: "Pełny dostęp do dysku") {
                Button("Otwórz ustawienia…") { center.openFullDiskAccessSettings() }
            }
        case .missing:
            SettingsStatus(
                text: "Nie znaleziono bazy powiadomień. Ta wersja macOS trzyma ją w innym miejscu.",
                symbol: "questionmark.circle.fill",
                tint: .secondary
            )
        case let .failed(message):
            SettingsStatus(text: message, symbol: "exclamationmark.triangle.fill", tint: .orange)
        case .checking:
            SettingsStatus(text: "Sprawdzanie…", symbol: "circle.dashed", tint: .secondary)
        case .off:
            EmptyView()
        }
    }
}
