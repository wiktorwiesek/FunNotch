//
//  SystemExtrasSettings.swift
//  FunNotch
//
//  The cards for the system extras, meant to sit inside the "Dodatki" page.
//  Every value lives in UserDefaults under `extras.system.*`; the managers
//  read the same keys, so changes apply at once.
//

import SwiftUI

struct SystemExtrasSettings: View {
    // Keep awake
    @AppStorage(KeepAwakeManager.keepDisplayKey) private var keepDisplay = true
    @AppStorage(KeepAwakeManager.defaultMinutesKey) private var defaultMinutes = 0
    @AppStorage(KeepAwakeManager.announceKey) private var announceKeepAwake = true

    // Microphone, privacy, sound
    @AppStorage(MicMuteManager.announceKey) private var announceMic = true
    @AppStorage(PrivacyIndicatorManager.announceKey) private var announcePrivacy = true
    @AppStorage(AudioOutputManager.announceKey) private var announceOutput = true

    // Keyboard, drives, battery
    @AppStorage(CapsLockWatcher.announceKey) private var announceCaps = true
    @AppStorage(VolumeMountWatcher.announceKey) private var announceVolumes = true
    @AppStorage(BatteryAlertWatcher.chargeEnabledKey) private var chargeAlert = true
    @AppStorage(BatteryAlertWatcher.chargeLevelKey) private var chargeLevel = 80
    @AppStorage(BatteryAlertWatcher.lowEnabledKey) private var lowAlert = true
    @AppStorage(BatteryAlertWatcher.lowLevelKey) private var lowLevel = 20

    // Home quick actions
    @AppStorage("extras.system.quickActions.keepAwake") private var quickKeepAwake = true
    @AppStorage("extras.system.quickActions.mic") private var quickMic = true
    @AppStorage("extras.system.quickActions.output") private var quickOutput = true

    @ObservedObject private var keepAwake = KeepAwakeManager.shared
    @ObservedObject private var mic = MicMuteManager.shared
    @ObservedObject private var output = AudioOutputManager.shared

    /// Only the hour and minute of this are used.
    @State private var untilTime = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            keepAwakeCard
            microphoneCard
            privacyCard
            soundCard
            batteryCard
            keyboardAndDrivesCard
            quickActionsCard
        }
        .onAppear { SystemExtras.start() }
    }

    // MARK: Keep awake

    private var keepAwakeCard: some View {
        SettingsCard(
            title: "Nie usypiaj",
            footer: "Mac nie zaśnie z bezczynności, dopóki funkcja jest włączona. Zamknięcie aplikacji ją wyłącza."
        ) {
            SettingsRow(title: keepAwake.isActive ? "Włączone" : "Wyłączone", subtitle: keepAwakeSubtitle,
                        symbol: KeepAwakeManager.activeSymbol, tint: SettingsStyle.orange) {
                Button(keepAwake.isActive ? "Wyłącz" : "Włącz") { keepAwake.toggle() }
            }
            SettingsPicker(
                title: "Domyślny czas",
                subtitle: "Dla przycisku, widżetu i polecenia bez wyboru czasu.",
                selection: $defaultMinutes
            ) {
                Text("Bez limitu").tag(0)
                Text("15 minut").tag(15)
                Text("1 godzina").tag(60)
                Text("2 godziny").tag(120)
            }
            SettingsRow(title: "Do godziny") {
                HStack(spacing: 8) {
                    DatePicker("", selection: $untilTime, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .environment(\.locale, Polish.locale)
                    Button("Włącz") {
                        let parts = Calendar.current.dateComponents([.hour, .minute], from: untilTime)
                        keepAwake.activate(untilHour: parts.hour ?? 0, minute: parts.minute ?? 0)
                    }
                }
            }
            SettingsToggle(
                title: "Nie wygaszaj też ekranu",
                subtitle: "Zmiana działa od następnego włączenia.",
                isOn: $keepDisplay
            )
            SettingsToggle(title: "Pokazuj komunikat w notchu", isOn: $announceKeepAwake)
        }
    }

    private var keepAwakeSubtitle: String? {
        guard keepAwake.isActive else { return nil }
        return KeepAwakeManager.summary(until: keepAwake.endDate)
            .capitalizedFirst
    }

    // MARK: Microphone

    private var microphoneCard: some View {
        SettingsCard(
            title: "Mikrofon",
            footer: "Wyciszenie dotyczy całego systemu: mikrofon milknie we wszystkich aplikacjach."
        ) {
            SettingsRow(title: mic.isMuted ? "Wyciszony" : "Włączony",
                        subtitle: mic.deviceName ?? "Brak mikrofonu",
                        symbol: mic.isMuted ? "mic.slash.fill" : "mic.fill", tint: SettingsStyle.red) {
                Button(mic.isMuted ? "Włącz" : "Wycisz") { mic.toggle() }
                    .disabled(!mic.isSupported)
            }
            if !mic.isSupported, mic.deviceName != nil {
                SettingsStatus(
                    text: "To urządzenie nie ma ani przełącznika wyciszenia, ani regulacji głośności wejścia, więc nie da się go wyciszyć.",
                    symbol: "exclamationmark.triangle.fill", tint: SettingsStyle.orange
                )
                .padding(14)
            }
            SettingsToggle(title: "Pokazuj komunikat w notchu", isOn: $announceMic)
        }
    }

    // MARK: Privacy

    private var privacyCard: some View {
        SettingsCard(
            title: "Wskaźnik prywatności",
            footer: "Zielona kropka: kamera w użyciu. Pomarańczowa: mikrofon. Widżet „Wskaźnik prywatności” dodasz w Dostosuj → Obok notcha."
        ) {
            SettingsToggle(
                title: "Komunikat, gdy kamera lub mikrofon zaczyna działać",
                symbol: "video.fill", tint: SettingsStyle.green,
                isOn: $announcePrivacy,
                preview: {
                    IslandCenter.shared.post(Island(
                        symbol: "video.fill", tint: .green, title: "Kamera", detail: "w użyciu", duration: 3
                    ))
                }
            )
            PrivacyStatusRow()
        }
    }

    // MARK: Sound

    private var soundCard: some View {
        SettingsCard(title: "Wyjście dźwięku") {
            SettingsRow(title: "Bieżące wyjście",
                        subtitle: output.current?.name ?? "Brak urządzenia",
                        symbol: output.current?.symbol ?? "speaker.slash", tint: SettingsStyle.purple) {
                Button("Zmień…") { output.showMenu() }
            }
            SettingsToggle(title: "Komunikat po zmianie wyjścia", isOn: $announceOutput)
        }
    }

    // MARK: Battery

    private var batteryCard: some View {
        SettingsCard(
            title: "Bateria",
            footer: "Komunikat o naładowaniu pojawia się raz na ładowanie, gdy bateria dojdzie do wybranego poziomu."
        ) {
            SettingsToggle(
                title: "Naładowana do wybranego poziomu",
                symbol: "battery.100.bolt", tint: SettingsStyle.green,
                isOn: $chargeAlert,
                preview: {
                    IslandCenter.shared.post(Island(
                        symbol: "battery.100.bolt", tint: .green, title: "Bateria",
                        detail: "naładowana do \(chargeLevel)%", trailing: "\(chargeLevel)%", duration: 4
                    ))
                }
            )
            if chargeAlert {
                SettingsSlider(
                    title: "Poziom naładowania",
                    value: Binding(get: { Double(chargeLevel) }, set: { chargeLevel = Int($0) }),
                    range: 80 ... 100, step: 5,
                    format: { "\(Int($0))%" }
                )
            }
            SettingsToggle(
                title: "Niski poziom baterii",
                symbol: "battery.25", tint: SettingsStyle.orange,
                isOn: $lowAlert,
                preview: {
                    IslandCenter.shared.post(Island(
                        symbol: "battery.25", tint: .orange, title: "Bateria",
                        detail: "niski poziom", trailing: "\(lowLevel)%", duration: 4
                    ))
                }
            )
            if lowAlert {
                SettingsSlider(
                    title: "Próg",
                    value: Binding(get: { Double(lowLevel) }, set: { lowLevel = Int($0) }),
                    range: 5 ... 30, step: 5,
                    format: { "\(Int($0))%" }
                )
            }
        }
    }

    // MARK: Keyboard and drives

    private var keyboardAndDrivesCard: some View {
        SettingsCard(title: "Klawiatura i dyski") {
            SettingsToggle(
                title: "Caps Lock",
                subtitle: "Komunikat po włączeniu i wyłączeniu.",
                symbol: "capslock.fill", tint: SettingsStyle.gray,
                isOn: $announceCaps,
                preview: {
                    IslandCenter.shared.post(Island(
                        symbol: "capslock.fill", tint: .orange, title: "Caps Lock", detail: "włączony", duration: 1.6
                    ))
                }
            )
            SettingsToggle(
                title: "Dyski zewnętrzne",
                subtitle: "Komunikat po podłączeniu, z przyciskiem „Wysuń”.",
                symbol: "externaldrive.fill", tint: SettingsStyle.blue,
                isOn: $announceVolumes
            )
        }
    }

    // MARK: Quick actions

    private var quickActionsCard: some View {
        SettingsCard(
            title: "Szybkie akcje na ekranie głównym",
            footer: "Przyciski dochodzą do rzędu „Szybkie akcje”. Prawy przycisk myszy na „Nie usypiaj” pokazuje wybór czasu."
        ) {
            SettingsToggle(title: "Nie usypiaj", symbol: KeepAwakeManager.activeSymbol, tint: SettingsStyle.orange, isOn: $quickKeepAwake)
            SettingsToggle(title: "Wyciszenie mikrofonu", symbol: "mic.fill", tint: SettingsStyle.red, isOn: $quickMic)
            SettingsToggle(title: "Wyjście dźwięku", symbol: "speaker.wave.2.fill", tint: SettingsStyle.purple, isOn: $quickOutput)
        }
    }
}

/// Live camera and microphone state, so the indicator can be tested from here.
private struct PrivacyStatusRow: View {
    @ObservedObject private var privacy = PrivacyIndicatorManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsStatus(
                text: privacy.cameraActive
                    ? "Kamera w użyciu: " + privacy.cameraNames.joined(separator: ", ")
                    : "Kamera nie jest używana",
                symbol: "circle.fill", tint: privacy.cameraActive ? .green : .secondary
            )
            SettingsStatus(
                text: privacy.microphoneActive
                    ? "Mikrofon w użyciu: " + privacy.microphoneNames.joined(separator: ", ")
                    : "Mikrofon nie jest używany",
                symbol: "circle.fill", tint: privacy.microphoneActive ? .orange : .secondary
            )
            SettingsStatus(
                text: privacy.screenActive
                    ? "Ekran jest nagrywany lub udostępniany"
                    : "Ekran nie jest nagrywany",
                symbol: "circle.fill", tint: privacy.screenActive ? .purple : .secondary
            )
        }
        .padding(14)
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
