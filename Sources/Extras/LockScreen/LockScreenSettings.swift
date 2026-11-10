//
//  LockScreenSettings.swift
//  FunNotch
//
//  Settings for the lock-screen widgets. The master switch is the existing
//  "Pokazuj na ekranie blokady" (`Settings.showOnLockScreen`); this card only
//  holds the per-widget switches and says whether the feature can work at all.
//

import SwiftUI

struct LockScreenSettings: View {
    @ObservedObject private var controller = LockScreenController.shared
    @ObservedObject private var settings = Settings.shared

    @AppStorage(LockScreenPrefs.nowPlayingKey) private var nowPlaying = true
    @AppStorage(LockScreenPrefs.focusKey) private var focus = true
    @AppStorage(LockScreenPrefs.chargingKey) private var charging = true
    @AppStorage(LockScreenPrefs.weatherKey) private var weather = true

    var body: some View {
        SettingsCard(
            title: "Ekran blokady",
            footer: "Wyświetlanie widgetów nad ekranem blokady opiera się na nieudokumentowanej części macOS i może przestać działać po aktualizacji systemu. Widgety pojawiają się tylko po zablokowaniu ekranu i znikają po odblokowaniu; gdy nie ma nic do pokazania, ekran blokady zostaje bez zmian."
        ) {
            status
            SettingsToggle(
                title: "Odtwarzacz",
                subtitle: "Okładka, tytuł i przyciski poprzedni / odtwórz / następny.",
                symbol: "play.circle.fill",
                tint: SettingsStyle.pink,
                isOn: $nowPlaying
            )
            SettingsToggle(
                title: "Skupienie i minutnik",
                subtitle: "Pozostały czas trwającej sesji skupienia lub minutnika.",
                symbol: "timer",
                tint: SettingsStyle.orange,
                isOn: $focus
            )
            SettingsToggle(
                title: "Ładowanie",
                subtitle: "Poziom baterii, gdy komputer jest podłączony do zasilania.",
                symbol: "bolt.fill",
                tint: SettingsStyle.green,
                isOn: $charging
            )
            SettingsToggle(
                title: "Pogoda",
                subtitle: "Ostatnio pobrana temperatura; ekran blokady nie pobiera nowej.",
                symbol: "cloud.sun.fill",
                tint: SettingsStyle.blue,
                isOn: $weather
            )
        }
        .onAppear { controller.checkAvailability() }
    }

    @ViewBuilder
    private var status: some View {
        if controller.isAvailable == false {
            SettingsStatus(
                text: "Niedostępne w tej wersji macOS — brakuje funkcji systemowej potrzebnej do rysowania nad ekranem blokady.",
                symbol: "exclamationmark.triangle.fill",
                tint: .orange
            )
        } else if !settings.showOnLockScreen {
            SettingsStatus(
                text: "Wyłączone. Włącz „Pokazuj na ekranie blokady”, aby widgety się pojawiały.",
                symbol: "moon.zzz.fill",
                tint: .secondary
            )
        } else {
            SettingsStatus(
                text: "Włączone — widgety pojawią się po zablokowaniu ekranu.",
                symbol: "checkmark.circle.fill",
                tint: .green
            )
        }
    }
}
