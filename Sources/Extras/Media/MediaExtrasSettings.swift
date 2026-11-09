//
//  MediaExtrasSettings.swift
//  FunNotch
//
//  Settings for the media extras: lyrics, the sound mixer, the real spectrum.
//

import AppKit
import SwiftUI

struct MediaExtrasSettings: View {
    @AppStorage(MediaExtrasDefaults.lyricsEnabledKey) private var lyricsEnabled = true
    @AppStorage(MediaExtrasDefaults.lyricsInPlayerKey) private var lyricsInPlayer = true
    @AppStorage(MediaExtrasDefaults.lyricsInClosedNotchKey) private var lyricsInClosedNotch = false
    @AppStorage(MediaExtrasDefaults.mixerEnabledKey) private var mixerEnabled = true
    @AppStorage(MediaExtrasDefaults.realSpectrumKey) private var realSpectrum = false

    @ObservedObject private var lyrics = LyricsManager.shared
    @ObservedObject private var mixer = AudioMixerManager.shared

    @State private var permission = AudioCapturePermission.status

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            lyricsCard
            soundCard
        }
        .onAppear {
            MediaExtras.start()
            permission = AudioCapturePermission.status
        }
        // The permission is granted in System Settings, so look again when the
        // user comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permission = AudioCapturePermission.status
        }
        .onChange(of: mixer.permission) { _, _ in
            permission = AudioCapturePermission.status
        }
    }

    // MARK: Lyrics

    private var lyricsCard: some View {
        SettingsCard(
            title: "Teksty piosenek",
            footer: "Teksty pochodzą z LRCLIB. Fun Notch wysyła tam wykonawcę, tytuł, album i długość utworu; pobrane teksty zapisuje w ~/Library/Caches/FunNotch/lyrics."
        ) {
            SettingsToggle(
                title: "Pobieraj teksty",
                subtitle: "Działa z każdym źródłem muzyki, także z Kasetem.",
                symbol: "text.quote",
                tint: SettingsStyle.pink,
                isOn: $lyricsEnabled
            )
            if lyricsEnabled {
                SettingsToggle(
                    title: "Linie w odtwarzaczu",
                    subtitle: "Bieżąca i następna linia pod wykonawcą. Kliknięcie otwiera cały tekst.",
                    isOn: $lyricsInPlayer
                )
                SettingsToggle(
                    title: "Linia pod zamkniętym notchem",
                    subtitle: "Podczas grania pod notchem pojawia się aktualnie śpiewana linia.",
                    isOn: $lyricsInClosedNotch
                )
                SettingsStatus(text: lyricsStatus, symbol: lyricsStatusSymbol, tint: .secondary)
            }
            SettingsRow(title: "Pokaż cały tekst", subtitle: "To samo robi polecenie „Pokaż tekst piosenki” w palecie.") {
                Button("Pokaż") { MediaOverlayState.shared.present(.lyrics) }
            }
        }
    }

    private var lyricsStatus: String {
        switch lyrics.state {
        case .idle: return "Nic nie gra."
        case .loading: return "Szukam tekstu…"
        case .synced: return "Mam tekst z synchronizacją do bieżącego utworu."
        case .plain: return "Mam tekst bez synchronizacji, więc nie będzie się przewijał."
        case .instrumental: return "To utwór instrumentalny."
        case .notFound: return "Brak tekstu dla bieżącego utworu."
        case .unavailable: return "Nie udało się połączyć z LRCLIB."
        }
    }

    private var lyricsStatusSymbol: String {
        switch lyrics.state {
        case .synced, .plain: return "checkmark.circle.fill"
        case .unavailable: return "exclamationmark.triangle.fill"
        default: return "info.circle.fill"
        }
    }

    // MARK: Sound

    private var soundCard: some View {
        SettingsCard(
            title: "Dźwięk",
            footer: "Mikser i spektrum korzystają z przechwytywania dźwięku systemu, które wymaga zgody w Ustawieniach systemowych → Prywatność i ochrona → Nagrywanie dźwięku systemu. Mikser opóźnia dźwięk aplikacji o kilkadziesiąt milisekund."
        ) {
            SettingsToggle(
                title: "Mikser dźwięku",
                subtitle: "Przycisk w odtwarzaczu. Głośność do 150%, wyciszenie i korektor osobno dla każdej aplikacji.",
                symbol: "slider.vertical.3",
                tint: SettingsStyle.indigo,
                isOn: $mixerEnabled
            )
            SettingsRow(title: "Otwórz mikser", subtitle: "Polecenie „Mikser dźwięku” w palecie robi to samo.") {
                Button("Otwórz") { MediaOverlayState.shared.present(.mixer) }
            }
            SettingsToggle(
                title: "Prawdziwe spektrum",
                subtitle: "Słupki obok notcha reagują na dźwięk z głośników. macOS poprosi o zgodę na nagrywanie dźwięku systemu; bez niej słupki pokazują animację.",
                symbol: "waveform",
                tint: SettingsStyle.teal,
                isOn: $realSpectrum
            )
            permissionRow
        }
    }

    @ViewBuilder
    private var permissionRow: some View {
        if !isSupported {
            SettingsStatus(
                text: "Mikser i prawdziwe spektrum wymagają macOS 14.2 lub nowszego.",
                symbol: "exclamationmark.triangle.fill",
                tint: SettingsStyle.orange
            )
        } else {
            switch permission {
            case .granted:
                SettingsStatus(text: "Zgoda na nagrywanie dźwięku systemu jest udzielona.", symbol: "checkmark.circle.fill", tint: SettingsStyle.green)
            case .denied:
                SettingsRow(
                    title: "Brak zgody na nagrywanie dźwięku systemu",
                    subtitle: "Mikser nie działa, a spektrum pokazuje animację.",
                    symbol: "lock.slash.fill", tint: SettingsStyle.red
                ) {
                    Button("Otwórz ustawienia") { AudioCapturePermission.openSystemSettings() }
                }
            case .notDetermined, .unknown:
                SettingsRow(
                    title: "Zgoda jeszcze nie była pytana",
                    subtitle: "macOS zapyta przy pierwszym użyciu miksera lub spektrum.",
                    symbol: "questionmark.circle.fill", tint: SettingsStyle.gray
                ) {
                    Button("Zapytaj teraz") {
                        mixer.requestPermission()
                    }
                }
            }
        }
    }

    private var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }
}
