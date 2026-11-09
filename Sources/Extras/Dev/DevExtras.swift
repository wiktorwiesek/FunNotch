//
//  DevExtras.swift
//  FunNotch
//
//  Startup and settings for the developer extras: the local API, terminal
//  activity, the GitHub and AI-usage tiles and the app launcher.
//

import AppKit
import SwiftUI

@MainActor
enum DevExtras {
    /// Starts everything. Idempotent, like every manager's `start()`.
    static func start() {
        LocalAPIManager.shared.start()
        GitHubManager.shared.start()
        AIUsageManager.shared.start()

        PaletteCommandRegistry.shared.register(PaletteCommand(
            id: "dev.github.ci",
            title: "Otwórz CI Project",
            subtitle: "GitHub Actions w przeglądarce",
            symbol: "checkmark.seal",
            keywords: ["github", "ci", "actions", "build", "testy", "deploy"],
            perform: {
                Task { @MainActor in
                    if let url = await GitHubManager.shared.projectActionsURL() {
                        NSWorkspace.shared.open(url)
                    } else {
                        IslandCenter.shared.post(Island(
                            symbol: "exclamationmark.triangle.fill", tint: SettingsStyle.orange,
                            title: "GitHub", detail: " · nie znaleziono repozytorium Project"
                        ))
                    }
                }
            }
        ))
        PaletteCommandRegistry.shared.register(PaletteCommand(
            id: "dev.ai.usage",
            title: "Zużycie AI dzisiaj",
            subtitle: "Koszt i tokeny z logów omp i Claude Code",
            symbol: "sparkles",
            keywords: ["ai", "tokeny", "koszt", "claude", "omp", "usage", "wydatki"],
            perform: { AIUsageManager.shared.announceToday() }
        ))
    }
}

// MARK: - Settings

struct DevExtrasSettings: View {
    @ObservedObject private var api = LocalAPIManager.shared
    @ObservedObject private var github = GitHubManager.shared
    @ObservedObject private var usage = AIUsageManager.shared
    @ObservedObject private var launcher = LauncherStore.shared

    @AppStorage(GitHubManager.reposKey) private var repos = ""
    @AppStorage(GitHubManager.ciIslandsKey) private var ciIslands = true
    @AppStorage(AIUsageManager.alertKey) private var alertUSD = 0.0

    @State private var tokenShown = false
    @State private var copied: String?
    @State private var shellInstalled = DevShellActivity.isInstalled
    @State private var shellMinimum = DevShellActivity.minimumSeconds
    @State private var shellError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            apiCard
            terminalCard
            githubCard
            usageCard
            launcherCard
        }
        .onAppear {
            shellInstalled = DevShellActivity.isInstalled
            usage.addSubscriber()
        }
        .onDisappear { usage.removeSubscriber() }
    }

    // MARK: Local API

    private var apiCard: some View {
        SettingsCard(
            title: "Lokalne API",
            footer: "Skrypty i narzędzia mogą wysyłać komunikaty do notcha: POST /island, /activity/start i /activity/end. Serwer słucha tylko na 127.0.0.1 i przyjmuje wyłącznie żądania z tokenem."
        ) {
            SettingsToggle(
                title: "Lokalne API",
                subtitle: "127.0.0.1:\(LocalAPIManager.port), z tokenem w Pęku kluczy",
                symbol: "network",
                tint: SettingsStyle.teal,
                isOn: Binding(get: { api.isEnabled }, set: { api.setEnabled($0) })
            )
            if api.isEnabled {
                if let error = api.lastError {
                    SettingsStatus(text: error, symbol: "exclamationmark.triangle.fill", tint: SettingsStyle.orange)
                } else if api.isListening {
                    SettingsStatus(
                        text: api.runningActivities > 0
                            ? "Nasłuchuje. Trwające zadania: \(api.runningActivities)."
                            : "Nasłuchuje na 127.0.0.1:\(LocalAPIManager.port).",
                        symbol: "checkmark.circle.fill",
                        tint: SettingsStyle.green
                    )
                } else {
                    SettingsStatus(text: "Uruchamianie…", symbol: "clock", tint: SettingsStyle.gray)
                }
                SettingsRow(title: "Token", subtitle: tokenShown ? api.revealToken() : "Ukryty") {
                    HStack(spacing: 6) {
                        Button(tokenShown ? "Ukryj" : "Pokaż") { tokenShown.toggle() }
                        Button(copied == "token" ? "Skopiowano" : "Kopiuj") {
                            copy(api.revealToken(), as: "token")
                        }
                        Button("Wygeneruj nowy") {
                            api.regenerateToken()
                            copied = nil
                        }
                    }
                    .controlSize(.small)
                }
                SettingsRow(title: "Przykład curl", subtitle: "Gotowe polecenie z Twoim tokenem") {
                    Button(copied == "curl" ? "Skopiowano" : "Kopiuj") {
                        copy(api.curlExample(), as: "curl")
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: Terminal

    private var terminalCard: some View {
        SettingsCard(
            title: "Terminal",
            footer: "Dopisuje do ~/.zshrc wyraźnie oznaczony blok i usuwa go po wyłączeniu. Wysyłana jest tylko nazwa komendy, nigdy jej argumenty, a token jest odczytywany z Pęku kluczy w trakcie działania. Zmiana działa w nowych oknach terminala."
        ) {
            SettingsToggle(
                title: "Powiadamiaj o długich komendach",
                subtitle: "Wyspa po zakończeniu komendy: nazwa, czas i wynik",
                symbol: "terminal",
                tint: SettingsStyle.indigo,
                isOn: Binding(get: { shellInstalled }, set: setShell)
            )
            SettingsPicker(title: "Dotyczy komend dłuższych niż", selection: $shellMinimum) {
                ForEach([5, 10, 30, 60, 120], id: \.self) { seconds in
                    Text(seconds >= 60 ? "\(seconds / 60) min" : "\(seconds) s").tag(seconds)
                }
            }
            .onChange(of: shellMinimum) { _, value in
                DevShellActivity.minimumSeconds = value
                if shellInstalled { setShell(true) }
            }
            if let shellError {
                SettingsStatus(text: shellError, symbol: "exclamationmark.triangle.fill", tint: SettingsStyle.red)
            } else if shellInstalled, !api.isEnabled {
                SettingsStatus(
                    text: "Lokalne API jest wyłączone, więc terminal nic nie pokaże. Włącz je powyżej.",
                    symbol: "exclamationmark.triangle.fill",
                    tint: SettingsStyle.orange
                )
            }
        }
    }

    private func setShell(_ enabled: Bool) {
        do {
            if enabled {
                try DevShellActivity.install(minimumSeconds: shellMinimum)
            } else {
                try DevShellActivity.remove()
            }
            shellError = nil
        } catch {
            shellError = "Nie udało się zmienić ~/.zshrc: \(error.localizedDescription)"
        }
        shellInstalled = DevShellActivity.isInstalled
    }

    // MARK: GitHub

    private var githubCard: some View {
        SettingsCard(
            title: "GitHub",
            footer: "Dane pobiera polecenie gh, które jest już zalogowane na tym Macu; Fun Notch nie widzi tokenu. Kafelek odświeża się co 2 minuty, gdy jest na ekranie."
        ) {
            SettingsRow(
                title: "Repozytoria",
                subtitle: "owner/nazwa, oddzielone przecinkami. Puste: origin projektu Project.",
                symbol: "chevron.left.forwardslash.chevron.right",
                tint: SettingsStyle.gray
            ) {
                TextField("owner/repo", text: $repos)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 230)
                    .onSubmit { github.reloadConfiguration() }
            }
            SettingsToggle(
                title: "Wyspa po zakończeniu CI",
                subtitle: "Sprawdza gałąź domyślną co 2 minuty także przy zamkniętym notchu, jeśli kafelek GitHub jest w którymś układzie",
                isOn: $ciIslands
            )
            switch github.phase {
            case .unavailable(let message):
                SettingsStatus(text: message, symbol: "exclamationmark.triangle.fill", tint: SettingsStyle.orange)
            case .ready:
                SettingsStatus(
                    text: "Połączono przez gh · \(Polish.count(github.repos.count, "repozytorium", "repozytoria", "repozytoriów")).",
                    symbol: "checkmark.circle.fill",
                    tint: SettingsStyle.green
                )
            default:
                EmptyView()
            }
            SettingsRow(title: "Odśwież teraz") {
                Button("Odśwież") { github.reloadConfiguration() }
                    .controlSize(.small)
            }
        }
    }

    // MARK: AI usage

    private var usageCard: some View {
        SettingsCard(
            title: "Zużycie AI",
            footer: "Liczone z logów sesji omp (~/.omp/agent/sessions) i Claude Code (~/.claude/projects), na bieżąco i bez wysyłania czegokolwiek. Koszt Claude Code to szacunek z publicznego cennika (oznaczony „~”), koszt omp jest zapisany w logach."
        ) {
            SettingsStatus(
                text: "Dziś: \(usage.summaryLine)",
                symbol: "sparkles",
                tint: SettingsStyle.orange
            )
            SettingsSlider(
                title: "Alert dzienny",
                subtitle: "Wyspa, gdy dzisiejszy koszt przekroczy próg",
                value: $alertUSD,
                range: 0 ... 200,
                step: 5,
                format: { $0 == 0 ? "wyłączony" : AIUsageManager.money($0).replacingOccurrences(of: ",00", with: "") }
            )
            .onChange(of: alertUSD) { _, _ in
                AIUsageManager.shared.start()
                AIUsageManager.shared.stopIfIdle()
                AIUsageManager.shared.refresh()
            }
        }
    }

    // MARK: Launcher

    private var launcherCard: some View {
        SettingsCard(
            title: "Kafelek aplikacji",
            footer: "Kafelek „Launcher” w układzie ekranu głównego. Kolejność zmienisz przeciągając ikony w notchu, a usuwanie jest w menu kontekstowym ikony."
        ) {
            ForEach(launcher.paths, id: \.self) { path in
                SettingsRow(title: launcher.name(of: path), subtitle: launcher.exists(path) ? nil : "Nie znaleziono aplikacji") {
                    Button("Usuń") { launcher.remove(path) }
                        .controlSize(.small)
                }
            }
            SettingsRow(title: launcher.paths.isEmpty ? "Brak przypiętych aplikacji" : "Dodaj kolejne") {
                Button("Dodaj aplikację…") { launcher.chooseApps() }
                    .controlSize(.small)
            }
        }
    }

    private func copy(_ text: String?, as name: String) {
        guard let text else { return }
        // The token is a secret: both types are declared in one call (one change
        // count) so the clipboard history poller never sees it unmarked.
        let pasteboard = NSPasteboard.general
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        pasteboard.declareTypes([.string, concealed], owner: nil)
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: concealed)
        copied = name
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if copied == name { copied = nil }
        }
    }
}
