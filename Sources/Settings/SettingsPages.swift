//
//  SettingsPages.swift
//  FunNotch
//
//  The pages of the settings window. Each is a short run of cards, and each
//  setting says in a few words what it does — the long explanations the old
//  window carried under every switch are gone, and so are the switches for
//  things almost nobody changes.
//

import AVFoundation
import AppKit
import EventKit
import SwiftUI

// MARK: - Previews in the notch

/// Fires the real announcements, so a switch can be seen doing its job.
@MainActor
enum LiveActivityPreview {
    static func show(_ type: SneakContentType, value: CGFloat = 1, icon: String = "", duration: Double = 3.2) {
        NotchWindowManager.shared.broadcast { viewModel in
            guard viewModel.notchState == .closed else { return }
            viewModel.showExpandingView(type: type, value: value, icon: icon, duration: duration)
        }
    }

    /// Three presses up, so the bar is seen moving rather than just sitting.
    static func hud(_ kind: HUDManager.Kind = .volume) {
        let steps: [Float] = [0.38, 0.5, 0.62]
        for (index, value) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.28) {
                HUDManager.shared.injectPreview(kind, value: value)
            }
        }
    }

    static func battery() {
        let battery = BatteryManager.shared
        show(.battery, value: CGFloat(battery.level), icon: battery.symbolName)
    }

    static func bluetooth() {
        let monitor = BluetoothMonitor.shared
        if let device = monitor.devices.first(where: \.isConnected) {
            monitor.injectPreviewChange(name: device.name, connected: true, battery: device.battery)
            show(.bluetooth, value: CGFloat(device.battery ?? 0), icon: device.symbol)
        } else {
            monitor.injectPreviewChange(name: "AirPods Pro", connected: true, battery: 0.82)
            show(.bluetooth, value: 0.82, icon: "airpods.pro")
        }
    }

    static func track() {
        NotchWindowManager.shared.broadcast { viewModel in
            guard viewModel.notchState == .closed else { return }
            viewModel.showSneakPeek(type: .music)
        }
    }
}

// MARK: - General

struct GeneralPage: View {
    @ObservedObject private var settings = Settings.shared
    @State private var launchAtLogin = LoginItemManager.isEnabled

    var body: some View {
        SettingsPage(
            title: "Ogólne",
            subtitle: "Uruchamianie, pasek menu i otwieranie notcha.",
            symbol: SettingsTab.general.symbol,
            tint: SettingsTab.general.tint
        ) {
            SettingsCard(title: "Uruchamianie") {
                SettingsToggle(title: "Otwieraj po zalogowaniu", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, value in
                        settings.launchAtLogin = value
                        LoginItemManager.setEnabled(value)
                    }
                SettingsToggle(title: "Ikona na pasku menu", isOn: $settings.menubarIcon)
                if settings.menubarIcon {
                    SettingsPicker(title: "Ikona", selection: $settings.menubarGlyph) {
                        ForEach(MenuBarGlyph.allCases) { glyph in
                            Text(glyph.title).tag(glyph)
                        }
                    }
                    SettingsPicker(title: "Obok ikony", selection: $settings.menubarReadout) {
                        ForEach(MenuBarReadout.allCases) { readout in
                            Text(readout.title).tag(readout)
                        }
                    }
                }
            }

            SettingsCard(title: "Otwieranie") {
                SettingsToggle(
                    title: "Otwieraj po najechaniu",
                    subtitle: "W przeciwnym razie kliknij notch.",
                    isOn: $settings.openNotchOnHover
                )
                if settings.openNotchOnHover {
                    SettingsRow(title: "Opóźnienie po najechaniu") {
                        Picker("", selection: hoverDelay) {
                            Text("Natychmiast").tag(0.05)
                            Text("Krótkie").tag(0.25)
                            Text("Długie").tag(0.6)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                SettingsToggle(
                    title: "Większy obszar najechania",
                    subtitle: "Notch otwiera się też po najechaniu tuż pod nim.",
                    isOn: $settings.extendHoverArea
                )
                SettingsToggle(
                    title: "Chowaj skrzydła przy pasku menu",
                    subtitle: "Po najechaniu na pasek menu obok notcha jego boki zwijają się, żeby nie zasłaniać menu i ikon.",
                    isOn: $settings.hideWingsAtMenuBar
                )
                SettingsToggle(title: "Reakcje haptyczne", isOn: $settings.enableHaptics)
            }

            SettingsCard(title: "Ekrany") {
                SettingsPicker(title: "Pokazuj notch na", selection: displayChoice) {
                    Text("ekranie z kursorem").tag(DisplayChoice.pointer)
                    Text("każdym ekranie").tag(DisplayChoice.all)
                    Divider()
                    Text("ekranie wbudowanym").tag(DisplayChoice.fixed(""))
                    if NSScreen.screens.count > 1 {
                        ForEach(NSScreen.screens, id: \.displayIdentifier) { screen in
                            Text(screen.localizedName).tag(DisplayChoice.fixed(screen.displayIdentifier))
                        }
                    }
                }
                SettingsPicker(title: "W aplikacjach pełnoekranowych", selection: $settings.hideNotchOption) {
                    Text("Ukryj notch").tag(HideNotchOption.always)
                    Text("Ukryj podczas odtwarzania multimediów").tag(HideNotchOption.nowPlayingOnly)
                    Text("Zostaw widoczny").tag(HideNotchOption.never)
                }
            }

            SettingsCard(title: "Prywatność") {
                SettingsToggle(
                    title: "Ukryj przed nagrywaniem ekranu",
                    subtitle: "Zrzuty ekranu i udostępniany ekran nie będą zawierać notcha.",
                    isOn: $settings.hideFromScreenRecording
                )
                SettingsToggle(title: "Pokazuj na ekranie blokady", isOn: $settings.showOnLockScreen)
            }
        }
    }

    /// The three delays offered, with whatever is stored snapped to the nearest.
    private var hoverDelay: Binding<Double> {
        Binding(
            get: {
                let stored = settings.minimumHoverDuration
                return [0.05, 0.25, 0.6].min { abs($0 - stored) < abs($1 - stored) } ?? 0.05
            },
            set: { settings.minimumHoverDuration = $0 }
        )
    }

    private enum DisplayChoice: Hashable {
        case pointer
        case all
        case fixed(String)
    }

    /// Two switches and a display name, as the one question they answer.
    private var displayChoice: Binding<DisplayChoice> {
        Binding(
            get: {
                if settings.showOnAllDisplays { return .all }
                if settings.automaticallySwitchDisplay { return .pointer }
                return .fixed(settings.preferredScreenName)
            },
            set: { choice in
                switch choice {
                case .all:
                    settings.showOnAllDisplays = true
                case .pointer:
                    settings.showOnAllDisplays = false
                    settings.automaticallySwitchDisplay = true
                case let .fixed(name):
                    settings.showOnAllDisplays = false
                    settings.automaticallySwitchDisplay = false
                    settings.preferredScreenName = name
                }
            }
        )
    }
}

// MARK: - Live Activities

struct LiveActivitiesPage: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var music = MusicManager.shared
    @ObservedObject private var navigation = SettingsNavigation.shared

    var body: some View {
        SettingsPage(
            title: "Aktywności na żywo",
            subtitle: "Co notch pokazuje, gdy coś się dzieje. Naciśnij ▶, aby zobaczyć przykład.",
            symbol: SettingsTab.activities.symbol,
            tint: SettingsTab.activities.tint
        ) {
            SettingsCard(title: "Głośność i jasność") {
                SettingsToggle(
                    title: "Pokazuj w notchu",
                    subtitle: "Zamiast systemowych paneli głośności i jasności.",
                    symbol: "speaker.wave.2.fill",
                    tint: SettingsStyle.purple,
                    isOn: hudEnabled,
                    preview: { LiveActivityPreview.hud() }
                )
                if settings.hudEnabled {
                    SettingsRow(title: "Obejmuje") {
                        HStack(spacing: 6) {
                            ChipToggle(title: "Głośność", symbol: "speaker.wave.2.fill", isOn: $settings.hudShowsVolume)
                            ChipToggle(title: "Jasność", symbol: "sun.max.fill", isOn: $settings.hudShowsBrightness)
                                .disabled(!DisplayBrightness.isAvailable)
                            ChipToggle(title: "Klawiatura", symbol: "keyboard.fill", isOn: $settings.hudShowsBacklight)
                                .disabled(!KeyboardBacklight.isAvailable)
                        }
                    }
                    HUDStatusLine()
                }
            }

            SettingsCard(title: "Komunikaty") {
                SettingsToggle(
                    title: "Zmiana utworu",
                    subtitle: "Okładka i tytuł, gdy zaczyna się nowy utwór.",
                    symbol: "music.note",
                    tint: SettingsStyle.pink,
                    isOn: $settings.enableSneakPeek,
                    preview: music.track.isEmpty ? nil : { LiveActivityPreview.track() }
                )
                SettingsToggle(
                    title: "Ładowanie",
                    subtitle: "Podłączenie i odłączenie zasilania.",
                    symbol: "bolt.fill",
                    tint: SettingsStyle.green,
                    isOn: $settings.showPowerStatusNotifications,
                    preview: { LiveActivityPreview.battery() }
                )
                SettingsToggle(
                    title: "Urządzenia Bluetooth",
                    subtitle: "Łączenie słuchawek i klawiatur.",
                    symbol: "airpods",
                    tint: SettingsStyle.blue,
                    isOn: $settings.bluetoothActivity,
                    preview: { LiveActivityPreview.bluetooth() }
                )
                SettingsToggle(
                    title: "Pobrane",
                    subtitle: "Po zakończeniu pobierania.",
                    symbol: "arrow.down.circle.fill",
                    tint: SettingsStyle.teal,
                    isOn: $settings.catchDownloads,
                    preview: { LiveActivityPreview.show(.download, icon: "arrow.down.circle.fill") }
                )
                SettingsToggle(
                    title: "Zrzuty ekranu",
                    subtitle: "Nowe zrzuty ekranu trafiają na półkę.",
                    symbol: "camera.viewfinder",
                    tint: SettingsStyle.gray,
                    isOn: $settings.catchScreenshots,
                    preview: { LiveActivityPreview.show(.screenshot, icon: "camera.viewfinder") }
                )
            }

            SettingsCard {
                SettingsRow(
                    title: "Agenci AI",
                    subtitle: "Początek i koniec sesji Claude Code oraz moment, gdy sesja czeka na Ciebie.",
                    symbol: SettingsTab.agents.symbol,
                    tint: SettingsTab.agents.tint
                ) {
                    Button("Ustawienia agentów") { navigation.tab = .agents }
                }
            }
        }
    }

    /// Turning the HUD on asks for Accessibility; turning it off lets go of the keys.
    private var hudEnabled: Binding<Bool> {
        Binding(
            get: { settings.hudEnabled },
            set: { on in
                settings.hudEnabled = on
                if on { HUDManager.shared.requestAccessAndStart() } else { HUDManager.shared.stop() }
            }
        )
    }
}

/// Says plainly whether the HUD is actually intercepting anything.
private struct HUDStatusLine: View {
    @ObservedObject private var hud = HUDManager.shared

    var body: some View {
        if hud.isIntercepting {
            SettingsStatus(
                text: "Działa — panele systemowe nie będą się pojawiać.",
                symbol: "checkmark.circle.fill",
                tint: .green
            )
        } else {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(hud.lastError ?? "Do przechwytywania klawiszy potrzebne jest uprawnienie Dostępność.")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Zezwól…") { HUDManager.shared.requestAccessAndStart() }
                    .controlSize(.small)
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Agents

struct AgentsPage: View {
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        SettingsPage(
            title: "Agenci AI",
            subtitle: "Sesje Claude Code, Codex i omp na żywo w notchu.",
            symbol: SettingsTab.agents.symbol,
            tint: SettingsTab.agents.tint
        ) {
            RunningAgentsCard()

            SettingsCard(
                title: "W notchu",
                footer: "Fun Notch czyta listę uruchomionych sesji, którą Claude Code zapisuje w ~/.claude/sessions, oraz listę z rozszerzenia funnotch-sessions dla omp w ~/.omp/notch-sessions. Treść rozmów nigdy nie jest otwierana."
            ) {
                SettingsToggle(
                    title: "Pokazuj pracujące sesje",
                    subtitle: "Animacja Claude obok kamery, gdy sesja pracuje.",
                    isOn: $settings.agentActivityEnabled
                )
                SettingsToggle(
                    title: "Gdy sesja się zaczyna",
                    isOn: $settings.agentAnnounceStart,
                    preview: { AgentSessionsManager.shared.injectPreview(.started) }
                )
                SettingsToggle(
                    title: "Gdy sesja się kończy",
                    subtitle: "Wraz z czasem jej trwania.",
                    isOn: $settings.agentAnnounceFinish,
                    preview: { AgentSessionsManager.shared.injectPreview(.finished(194)) }
                )
                SettingsToggle(
                    title: "Gdy sesja czeka na Ciebie",
                    subtitle: "Prośby o zgodę i pytania.",
                    isOn: $settings.agentAnnounceWaiting,
                    preview: { AgentSessionsManager.shared.injectPreview(.needsInput("permission prompt")) }
                )
            }
        }
    }
}

/// Every session Fun Notch can see right now.
private struct RunningAgentsCard: View {
    @ObservedObject private var agents = AgentSessionsManager.shared

    var body: some View {
        SettingsCard(title: "Uruchomione teraz") {
            if agents.sessions.isEmpty {
                SettingsStatus(
                    text: agents.hasScanned
                        ? "Brak uruchomionych sesji. Uruchom Claude Code lub omp, a sesja od razu pojawi się tutaj."
                        : "Wyszukiwanie…",
                    symbol: "sparkles",
                    tint: AgentPalette.claude
                )
            } else {
                ForEach(agents.sessions) { session in
                    SettingsAgentRow(session: session)
                }
            }
        }
    }
}

private struct SettingsAgentRow: View {
    let session: AgentSessionsManager.Session

    var body: some View {
        HStack(spacing: 11) {
            indicator
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(detailColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(time(now: context.date))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button("Pokaż") { AgentSessionsManager.shared.bringForward(session) }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .animation(.easeOut(duration: 0.2), value: session.status)
    }

    @ViewBuilder
    private var indicator: some View {
        switch session.status {
        case .working:
            AgentWorkingGlyph(agent: session.agent, size: 14)
        case .waiting:
            AgentWaitingGlyph(size: 14)
        case .idle:
            Image(systemName: session.lastTurnDuration == nil ? "moon.zzz.fill" : "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(session.lastTurnDuration == nil ? Color.secondary : Color.green)
        }
    }

    private var detail: String {
        var place = "\(session.agent.rawValue) · \(session.project)"
        if let usage = session.usage { place += " · \(usage.summary)" }
        switch session.status {
        case .working:
            if session.activity == nil, session.backgroundAgents > 0 {
                return "W tle: \(Polish.count(session.backgroundAgents, "agent", "agenty", "agentów")) — \(place)"
            }
            return "\(session.activity.map { "Uruchamia \($0)" } ?? "Pracuje") — \(place)"
        case let .waiting(reason): return "\(AgentSessionsManager.waitingText(reason)) — \(place)"
        case .idle:
            if let duration = session.lastTurnDuration {
                return "Zakończono w \(AgentSessionsManager.duration(duration)) — \(place)"
            }
            return "Bezczynny — \(place)"
        }
    }

    private var detailColor: Color {
        switch session.status {
        case .working: return AgentPalette.claude
        case .waiting: return .orange
        case .idle: return .secondary
        }
    }

    private func time(now: Date) -> String {
        if session.status.isActive {
            return AgentSessionsManager.clock(now.timeIntervalSince(session.turnStartedAt ?? session.statusSince))
        }
        if now.timeIntervalSince(session.statusSince) < 60 { return "teraz" }
        return "\(AgentSessionsManager.ago(session.statusSince, now: now)) temu"
    }
}

// MARK: - Media

struct MediaPage: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var music = MusicManager.shared

    var body: some View {
        SettingsPage(
            title: "Multimedia",
            subtitle: "Skąd notch odczytuje, co jest odtwarzane, i jak wygląda odtwarzacz.",
            symbol: SettingsTab.media.symbol,
            tint: SettingsTab.media.tint
        ) {
            SettingsCard(title: "Źródło") {
                SettingsPicker(title: "Odczytuj dane z", selection: $settings.mediaController) {
                    ForEach(MediaControllerType.allCases) { type in
                        Text(type.title).tag(type)
                    }
                }
                if music.isNowPlayingDeprecated, settings.mediaController == .nowPlaying {
                    SettingsStatus(
                        text: "macOS nie udostępnia już aplikacjom systemowych informacji „Teraz odtwarzane”, więc Fun Notch korzysta z dowolnego uruchomionego odtwarzacza.",
                        symbol: "info.circle.fill",
                        tint: .secondary
                    )
                }
                if let active = music.activeControllerType, active != settings.mediaController {
                    SettingsStatus(
                        text: "Obecne źródło: \(active.title).",
                        symbol: "arrow.triangle.branch",
                        tint: .secondary
                    )
                }
            }

            if settings.mediaController == .browser {
                SettingsCard(title: "Przeglądarka") {
                    BrowserPageAccessHelp()
                        .padding(14)
                }
            }

            SettingsCard(title: "Odtwarzacz") {
                SettingsToggle(title: "Dopasuj kolory odtwarzacza do okładki", isOn: $settings.playerColorTinting)
                SettingsToggle(title: "Przyciski losowego odtwarzania i powtarzania", isOn: $settings.showShuffleAndRepeat)
                SettingsToggle(
                    title: "Spektrum obok notcha",
                    subtitle: "Animowane słupki podczas odtwarzania.",
                    isOn: $settings.useMusicVisualizer
                )
            }
        }
    }
}

/// Without page access the notch only sees a tab's title, which has no artist,
/// no artwork and no position. The switch that fixes it is buried in a
/// different place in every browser, so spell each one out.
private struct BrowserPageAccessHelp: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var access = BrowserScriptAccess.shared
    @State private var showingSteps = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("YouTube, Spotify, SoundCloud i inne odtwarzacze w przeglądarce pokazują tytuł od razu. Okładka, wykonawca i pasek postępu wymagają zgody przeglądarki na mały skrypt.")
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button("Włącz dostęp do stron") { access.enable() }
                    .disabled(access.outcome == .working)
                Button(showingSteps ? "Ukryj kroki" : "Ustawię ręcznie") { showingSteps.toggle() }
                    .buttonStyle(.link)
            }

            if access.outcome != .idle {
                Label(access.outcome.message, systemImage: access.outcome.isGood
                    ? "checkmark.circle.fill"
                    : "info.circle")
                    .foregroundStyle(access.outcome.isGood ? Color.green : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showingSteps {
                ForEach(Self.steps, id: \.browser) { step in
                    if BrowserMediaController.installedBrowsers.contains(step.browser) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(step.browser)
                                .fontWeight(.semibold)
                                .frame(width: 104, alignment: .leading)
                            Text(step.path)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Toggle("Informuj w notchu, gdy karta nie podaje postępu", isOn: $settings.showPageAccessHint)
                .toggleStyle(.checkbox)
        }
        .font(.system(size: 11.5))
        .fixedSize(horizontal: false, vertical: true)
    }

    private static let steps: [(browser: String, path: String)] = [
        ("Safari", "Ustawienia → Zaawansowane → Pokaż funkcje dla twórców stron internetowych, potem Programowanie → Zezwalaj na JavaScript z Apple Events"),
        ("Google Chrome", "Widok → Dla programistów → Zezwalaj na JavaScript z Apple Events"),
        ("Brave Browser", "Widok → Dla programistów → Zezwalaj na JavaScript z Apple Events"),
        ("Microsoft Edge", "Widok → Dla programistów → Zezwalaj na JavaScript z Apple Events"),
        ("Arc", "Widok → Dla programistów → Zezwalaj na JavaScript z Apple Events"),
    ]
}

// MARK: - Shelf & Clipboard

struct ShelfClipboardPage: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var shelf = ShelfManager.shared
    @ObservedObject private var clipboard = ClipboardManager.shared

    var body: some View {
        SettingsPage(
            title: "Półka i schowek",
            subtitle: "Miejsce na pliki i historia tego, co kopiujesz.",
            symbol: SettingsTab.shelf.symbol,
            tint: SettingsTab.shelf.tint
        ) {
            SettingsCard(title: "Półka") {
                SettingsToggle(
                    title: "Półka",
                    subtitle: "Upuść pliki na notch, aby zachować je na później.",
                    isOn: $settings.shelfEnabled
                )
                if settings.shelfEnabled {
                    SettingsToggle(title: "Otwieraj półkę po rozpoczęciu przeciągania", isOn: $settings.openShelfByDefault)
                    SettingsToggle(title: "Wykrywaj przeciąganie z dowolnego miejsca na ekranie", isOn: $settings.expandedDragDetection)
                    SettingsToggle(
                        title: "Kopiuj zamiast przenosić",
                        subtitle: "Po przeciągnięciu oryginał zostaje na swoim miejscu.",
                        isOn: $settings.copyOnDrag
                    )
                    if !settings.copyOnDrag {
                        SettingsToggle(title: "Usuwaj elementy po wyciągnięciu z półki", isOn: $settings.autoRemoveShelfItems)
                    }
                    SettingsPicker(title: "Usuwaj elementy", selection: $settings.shelfExpiryHours) {
                        Text("Nigdy").tag(0)
                        Text("Po 1 godz.").tag(1)
                        Text("Po 6 godz.").tag(6)
                        Text("Po 1 dniu").tag(24)
                        Text("Po 1 tygodniu").tag(168)
                    }
                }
            }

            if settings.shelfEnabled {
                SettingsCard(title: "Dodawaj automatycznie") {
                    SettingsToggle(title: "Nowe zrzuty ekranu", isOn: $settings.catchScreenshots)
                    if settings.catchScreenshots {
                        SettingsToggle(title: "Także nagrania ekranu", isOn: $settings.catchScreenRecordings)
                    }
                    SettingsToggle(title: "Ukończone pobrania", isOn: $settings.downloadsToShelf)
                        .disabled(!settings.catchDownloads)
                }

                SettingsCard(
                    title: "Foldery docelowe",
                    footer: "Każdy folder staje się na Półce celem dostępnym jednym kliknięciem."
                ) {
                    ForEach(settings.shelfFolderTargets, id: \.self) { path in
                        SettingsRow(title: (path as NSString).lastPathComponent, subtitle: (path as NSString).deletingLastPathComponent) {
                            Button {
                                settings.shelfFolderTargets.removeAll { $0 == path }
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    SettingsRow(title: settings.shelfFolderTargets.isEmpty ? "Brak folderów" : "Dodaj kolejny") {
                        Button("Dodaj folder…", action: pickFolder)
                    }
                }
            }

            SettingsCard(
                title: "Schowek",
                footer: "Hasła i treści oznaczone jako prywatne nigdy nie są zapisywane. Po ponownym uruchomieniu zachowywany jest tylko tekst."
            ) {
                SettingsToggle(title: "Zapamiętuj to, co kopiuję", isOn: $settings.clipboardHistoryEnabled)
                if settings.clipboardHistoryEnabled {
                    SettingsPicker(title: "Przechowuj", selection: $settings.clipboardHistoryLimit) {
                        ForEach([10, 20, 50, 100], id: \.self) { count in
                            Text(Polish.count(count, "element", "elementy", "elementów")).tag(count)
                        }
                    }
                    SettingsPicker(title: "Usuwaj wpisy", selection: $settings.clipboardExpiryHours) {
                        Text("Po 1 godz.").tag(1)
                        Text("Po 8 godz.").tag(8)
                        Text("Po 1 dniu").tag(24)
                        Text("Po 3 dniach").tag(72)
                        Text("Po 1 tygodniu").tag(168)
                        Text("Po 30 dniach").tag(720)
                        Text("Nigdy").tag(0)
                    }
                    SettingsRow(title: "Zapisano: \(clipboard.entries.count)") {
                        Button("Wyczyść historię", role: .destructive) { clipboard.clear() }
                            .disabled(clipboard.entries.isEmpty)
                    }
                }
            }
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var targets = settings.shelfFolderTargets
        for url in panel.urls where !targets.contains(url.path) {
            targets.append(url.path)
        }
        settings.shelfFolderTargets = targets
    }
}

// MARK: - Focus

struct FocusPage: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var focus = FocusManager.shared
    @State private var editingSites = false
    @State private var editingApps = false

    var body: some View {
        SettingsPage(
            title: "Skupienie",
            subtitle: "Sesje skupienia, minutniki, stoper i mniej rozpraszaczy.",
            symbol: SettingsTab.focus.symbol,
            tint: SettingsTab.focus.tint
        ) {
            SettingsCard(title: "Sesje") {
                SettingsRow(title: "Domyślna długość", subtitle: "Albo przeciągnij tarczę w notchu.") {
                    Picker("", selection: $settings.focusDefaultMinutes) {
                        // The dial sets any five minutes, so whatever it was
                        // left on has to be one of the choices here too.
                        ForEach(Array(Set([15, 25, 45, 60, 90, settings.focusDefaultMinutes])).sorted(), id: \.self) { minutes in
                            Text("\(minutes) min").tag(minutes)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsToggle(
                    title: "Cykle Pomodoro",
                    subtitle: "Po sesji przerwa, a potem znów praca.",
                    isOn: $settings.focusPomodoro
                )
                if settings.focusPomodoro {
                    SettingsPicker(title: "Długość przerwy", selection: $settings.focusBreakMinutes) {
                        ForEach([3, 5, 10, 15], id: \.self) { minutes in
                            Text("\(minutes) min").tag(minutes)
                        }
                    }
                }
                SettingsToggle(title: "Wstrzymuj muzykę na początku sesji", isOn: $settings.focusPauseMusic)
                SettingsToggle(title: "Odliczanie obok notcha", isOn: $settings.focusShowInClosedNotch)
                if focus.isActive {
                    SettingsRow(title: "Trwa teraz", subtitle: "Pozostało: \(focus.remainingText)") {
                        Button("Zatrzymaj") { focus.stop() }
                    }
                }
            }

            SettingsCard(title: "Rozpraszacze") {
                SettingsToggle(
                    title: "Blokuj rozpraszające strony",
                    subtitle: browserNote,
                    isOn: $settings.focusBlockWebsites
                )
                SettingsRow(
                    title: "Zablokowane strony",
                    subtitle: settings.focusBlocklist.isEmpty ? "Brak" : settings.focusBlocklist.prefix(3).joined(separator: ", ") + (settings.focusBlocklist.count > 3 ? " i jeszcze \(settings.focusBlocklist.count - 3)" : "")
                ) {
                    Button("Edytuj…") { editingSites = true }
                }
                SettingsRow(
                    title: "Aplikacje do ukrycia",
                    subtitle: settings.focusBlockedApps.isEmpty ? "Brak" : Polish.count(settings.focusBlockedApps.count, "aplikacja", "aplikacje", "aplikacji")
                ) {
                    Button("Edytuj…") { editingApps = true }
                }
            }

            SettingsCard(
                title: "Skróty",
                footer: "Nazwy muszą pasować do skrótów w aplikacji Skróty — to najprostszy sposób na włączenie trybu Skupienia w macOS."
            ) {
                SettingsRow(title: "Uruchom na początku sesji") {
                    TextField("", text: $settings.focusStartShortcut, prompt: Text("Nazwa skrótu"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 190)
                }
                SettingsRow(title: "Uruchom na końcu sesji") {
                    TextField("", text: $settings.focusEndShortcut, prompt: Text("Nazwa skrótu"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 190)
                }
            }

            SettingsCard(title: "Dotychczas") {
                SettingsRow(
                    title: Polish.count(settings.focusSessionsCompleted, "sesja", "sesje", "sesji"),
                    subtitle: "Czas skupienia: \(focusedTime)"
                ) {
                    Button("Wyzeruj") {
                        settings.focusSessionsCompleted = 0
                        settings.focusMinutesTotal = 0
                    }
                }
            }
        }
        .sheet(isPresented: $editingSites) { BlocklistEditor() }
        .sheet(isPresented: $editingApps) { BlockedAppsEditor() }
    }

    private var browserNote: String {
        let browsers = FocusManager.supportedInstalledBrowsers
        return browsers.isEmpty
            ? "Wymaga Safari, Chrome, Brave, Edge lub Arc."
            : "Działa w: \(browsers.joined(separator: ", "))."
    }

    private var focusedTime: String {
        let minutes = settings.focusMinutesTotal
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) godz. \(minutes % 60) min"
    }
}

private struct BlocklistEditor: View {
    @ObservedObject private var settings = Settings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var newSite = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Zablokowane strony")
                .font(.title3.weight(.semibold))
            HStack {
                TextField("example.com", text: $newSite)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Dodaj", action: add)
                    .disabled(cleaned.isEmpty)
            }
            List {
                ForEach(settings.focusBlocklist, id: \.self) { site in
                    HStack {
                        Image(systemName: "globe").foregroundStyle(.secondary)
                        Text(site)
                        Spacer()
                        Button {
                            settings.focusBlocklist.removeAll { $0 == site }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(minHeight: 220)
            HStack {
                Button("Przywróć domyślne") { settings.focusBlocklist = Settings.defaultBlocklist }
                Button("Usuń wszystkie") { settings.focusBlocklist = [] }
                    .disabled(settings.focusBlocklist.isEmpty)
                Spacer()
                Button("Gotowe") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420, height: 420)
    }

    private var cleaned: String {
        newSite
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "www.", with: "")
            .components(separatedBy: "/")
            .first ?? ""
    }

    private func add() {
        let site = cleaned
        guard !site.isEmpty, !settings.focusBlocklist.contains(site) else { return }
        settings.focusBlocklist.append(site)
        newSite = ""
    }
}

private struct BlockedAppsEditor: View {
    @ObservedObject private var settings = Settings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Aplikacje do ukrycia")
                .font(.title3.weight(.semibold))
            Text("Ukryte na czas sesji, po jej zakończeniu wracają.")
                .font(.callout)
                .foregroundStyle(.secondary)
            List {
                ForEach(settings.focusBlockedApps, id: \.self) { identifier in
                    HStack(spacing: 8) {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable()
                                .frame(width: 18, height: 18)
                            Text(url.deletingPathExtension().lastPathComponent)
                        } else {
                            Image(systemName: "questionmark.app")
                            Text(identifier)
                        }
                        Spacer()
                        Button {
                            settings.focusBlockedApps.removeAll { $0 == identifier }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(minHeight: 200)
            HStack {
                Button("Dodaj aplikację…", action: pick)
                Spacer()
                Button("Gotowe") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420, height: 400)
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        var blocked = settings.focusBlockedApps
        for url in panel.urls {
            guard let identifier = Bundle(url: url)?.bundleIdentifier else { continue }
            if !blocked.contains(identifier) { blocked.append(identifier) }
        }
        settings.focusBlockedApps = blocked
    }
}

// MARK: - Calendar

struct CalendarPage: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var manager = CalendarManager.shared

    var body: some View {
        SettingsPage(
            title: "Kalendarz",
            subtitle: "Co pokazuje agenda na ekranie startowym.",
            symbol: SettingsTab.calendar.symbol,
            tint: SettingsTab.calendar.tint
        ) {
            SettingsCard(title: "Agenda") {
                SettingsToggle(title: "Ukryj wydarzenia całodniowe", isOn: $settings.hideAllDayEvents)
                SettingsToggle(title: "Pokazuj pełne tytuły wydarzeń", isOn: $settings.showFullEventTitles)
                SettingsToggle(title: "Uwzględniaj przypomnienia", isOn: $settings.showReminders)
                if settings.showReminders {
                    SettingsToggle(title: "Ukryj ukończone przypomnienia", isOn: $settings.hideCompletedReminders)
                }
                SettingsToggle(
                    title: "Wypełniaj pusty dzień przykładami",
                    subtitle: "Oznaczone jako „Przykład”, nigdy nie liczą się jako następne wydarzenie.",
                    isOn: $settings.showSampleAgenda
                )
            }

            SettingsCard(
                title: "Kalendarze",
                footer: manager.hasEventAccess ? "Wyłącz wszystkie, aby uwzględnić każdy kalendarz." : nil
            ) {
                if !manager.hasEventAccess {
                    SettingsRow(title: "Dostęp do kalendarza", subtitle: "Potrzebny do pokazywania wydarzeń.") {
                        Button("Zezwól…") { manager.requestAccess() }
                    }
                } else if manager.calendars.isEmpty {
                    SettingsStatus(text: "Nie znaleziono kalendarzy.", symbol: "calendar", tint: .secondary)
                } else {
                    ForEach(manager.calendars, id: \.calendarIdentifier) { calendar in
                        CalendarToggleRow(calendar: calendar)
                    }
                }
            }
        }
    }
}

private struct CalendarToggleRow: View {
    let calendar: EKCalendar

    @ObservedObject private var settings = Settings.shared

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(nsColor: NSColor(cgColor: calendar.cgColor) ?? .systemBlue))
                .frame(width: 10, height: 10)
            Text(calendar.title)
                .font(.system(size: 13))
            Spacer()
            Toggle("", isOn: binding)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { settings.selectedCalendarIdentifiers.contains(calendar.calendarIdentifier) },
            set: { isOn in
                var identifiers = settings.selectedCalendarIdentifiers
                if isOn {
                    identifiers.append(calendar.calendarIdentifier)
                } else {
                    identifiers.removeAll { $0 == calendar.calendarIdentifier }
                }
                settings.selectedCalendarIdentifiers = identifiers
            }
        )
    }
}

// MARK: - About

struct AboutPage: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var updates = UpdateManager.shared
    @State private var autoUpdate = UpdateManager.shared.automaticallyChecks
    @State private var confirmingReset = false

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(spacing: 10) {
                AppMark(size: 76)
                Text("Fun Notch")
                    .font(.system(size: 24, weight: .bold))
                Text("Wersja \(version)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("Twój notch — przydatny i trochę zabawny.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    Link("funnotch.xyz", destination: URL(string: "https://funnotch.xyz")!)
                    Link("GitHub", destination: URL(string: "https://github.com/JoshuaT1105/FunNotch")!)
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 4)

            SettingsCard(title: "Aktualizacje") {
                SettingsToggle(title: "Sprawdzaj aktualizacje automatycznie", isOn: $autoUpdate)
                    .onChange(of: autoUpdate) { _, value in updates.automaticallyChecks = value }
                SettingsRow(
                    title: "Sprawdź teraz",
                    subtitle: updates.lastCheckedAt.map {
                        "Ostatnio sprawdzono: \($0.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Polish.locale)))"
                    } ?? "Jeszcze nie sprawdzano"
                ) {
                    Button("Sprawdź aktualizacje") { updates.checkForUpdates() }
                        .disabled(!updates.canCheckForUpdates)
                }
            }

            HealthCheckCard()

            SettingsCard(title: "Rozwiązywanie problemów") {
                SettingsRow(title: "Uruchom ponownie Fun Notch") {
                    Button("Uruchom ponownie") { LoginItemManager.relaunch() }
                }
                SettingsRow(title: "Zresetuj wszystkie ustawienia", subtitle: "Wszystkie ustawienia wrócą do wartości domyślnych.") {
                    Button("Resetuj…") { confirmingReset = true }
                }
                SettingsRow(title: "Zakończ Fun Notch") {
                    Button("Zakończ") { NSApp.terminate(nil) }
                }
            }
        }
        .confirmationDialog("Zresetować wszystkie ustawienia?", isPresented: $confirmingReset) {
            Button("Zresetuj wszystkie ustawienia", role: .destructive) { settings.resetAll() }
        } message: {
            Text("Półka, historia schowka i notatki zostaną zachowane.")
        }
    }
}

/// Everything here depends on a permission or on a switch inside another app,
/// and when one is missing the feature quietly does less — which from the
/// outside looks exactly like a bug. This says which it is.
private struct HealthCheckCard: View {
    @ObservedObject private var report = DiagnosticsReport.shared
    @State private var showingReport = false

    private var problems: [DiagnosticsReport.Row] {
        report.sections.flatMap(\.rows).filter {
            if case .missing = $0.verdict { return true }
            return false
        }
    }

    var body: some View {
        SettingsCard(title: "Diagnostyka") {
            if problems.isEmpty {
                SettingsStatus(
                    text: "Wszystko, czego potrzebuje Fun Notch, działa.",
                    symbol: "checkmark.seal.fill",
                    tint: .green
                )
            } else {
                ForEach(problems.prefix(4)) { row in
                    SettingsRow(title: row.label, subtitle: row.remedy ?? row.verdict.text) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            SettingsRow(title: "Pełny raport", subtitle: "Uprawnienia, źródła multimediów i ostatni dziennik.") {
                Button("Otwórz…") { showingReport = true }
            }
        }
        .onAppear { report.refresh() }
        .sheet(isPresented: $showingReport) {
            DiagnosticsReportView()
        }
    }
}

/// The full diagnostics report, with the log and a copyable summary.
private struct DiagnosticsReportView: View {
    @ObservedObject private var report = DiagnosticsReport.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showingLog = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(report.sections) { section in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(section.title)
                                .font(.headline)
                            ForEach(section.rows) { row in
                                DiagnosticsRow(row: row)
                            }
                        }
                    }

                    if !report.recentLog.isEmpty {
                        DisclosureGroup("Ostatnie wpisy dziennika", isExpanded: $showingLog) {
                            Text(report.recentLog.joined(separator: "\n"))
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 4)
                        }
                        .font(.headline)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Text("Sprawdzono: \(report.generated.formatted(Date.FormatStyle(date: .omitted, time: .standard).locale(Polish.locale)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Pokaż dziennik") {
                    NSWorkspace.shared.activateFileViewerSelecting([DiagnosticLog.fileURL])
                }
                Button(copied ? "Skopiowano" : "Kopiuj raport") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.plainText, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                Button("Sprawdź ponownie") { report.refresh() }
                Button("Gotowe") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 640, height: 540)
        .onAppear { report.refresh() }
    }
}

private struct DiagnosticsRow: View {
    let row: DiagnosticsReport.Row

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: row.verdict.symbol)
                .foregroundStyle(tint)
                .frame(width: 14)
            Text(row.label)
                .frame(width: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.verdict.text)
                    .textSelection(.enabled)
                if let remedy = row.remedy {
                    Text(remedy)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var tint: Color {
        switch row.verdict {
        case .good: return .green
        case .missing: return .orange
        case .unknown: return .secondary
        }
    }
}
