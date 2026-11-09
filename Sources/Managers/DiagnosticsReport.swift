//
//  DiagnosticsReport.swift
//  FunNotch
//
//  What the app can and cannot currently see, in one place.
//
//  Almost everything here depends on a permission the user may not have given,
//  or on a switch inside another application. When one of those is missing the
//  feature does not crash, it just quietly does less — which from the outside
//  is indistinguishable from a bug. This is the screen that tells them apart.
//

import AVFoundation
import AppKit
import ApplicationServices
import CoreLocation
import EventKit
import Foundation

/// Which read path each browser ended up on. Written by the media controller,
/// which is created and destroyed as backends change, so it lives out here.
enum BrowserReadModes {
    /// Browser name → true when the page itself answered, false when only the
    /// tab title was readable.
    nonisolated(unsafe) private(set) static var modes: [String: Bool] = [:]
    private static let lock = NSLock()

    static func record(browser: String, scripted: Bool) {
        lock.lock()
        modes[browser] = scripted
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        modes.removeAll()
        lock.unlock()
    }
}

@MainActor
final class DiagnosticsReport: ObservableObject {
    static let shared = DiagnosticsReport()

    enum Verdict {
        case good(String)
        case missing(String)
        case unknown(String)

        var text: String {
            switch self {
            case let .good(text), let .missing(text), let .unknown(text): return text
            }
        }

        var symbol: String {
            switch self {
            case .good: return "checkmark.circle.fill"
            case .missing: return "exclamationmark.triangle.fill"
            case .unknown: return "questionmark.circle"
            }
        }
    }

    struct Row: Identifiable {
        let id = UUID()
        let label: String
        let verdict: Verdict
        /// What to do about it, when there is something to do.
        var remedy: String?
    }

    struct Section: Identifiable {
        let id = UUID()
        let title: String
        let rows: [Row]
    }

    @Published private(set) var sections: [Section] = []
    @Published private(set) var generated = Date()
    @Published private(set) var recentLog: [String] = []

    private init() {}

    func refresh() {
        sections = [
            buildAbout(),
            buildMedia(),
            buildScriptErrors(),
            buildPermissions(),
            buildActivity(),
        ]
        recentLog = Self.tailOfLog(lines: 40)
        generated = Date()
    }

    // MARK: - Sections

    private func buildAbout() -> Section {
        let bundle = Bundle.main
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        #if arch(arm64)
        let architecture = "Apple Silicon"
        #else
        let architecture = "Intel"
        #endif

        return Section(title: "Fun Notch", rows: [
            Row(label: "Wersja", verdict: .good("\(version) (\(build)) · \(architecture)")),
            Row(label: "macOS", verdict: .good(ProcessInfo.processInfo.operatingSystemVersionString)),
            Row(
                label: "Ekrany z notchem",
                verdict: NSScreen.screens.contains(where: \.hasPhysicalNotch)
                    ? .good("tak")
                    : .unknown("brak — panel jest rysowany w miejscu notcha")
            ),
        ])
    }

    private func buildMedia() -> Section {
        let music = MusicManager.shared
        let settings = Settings.shared
        var rows: [Row] = []

        let chosen = settings.mediaController
        let active = music.activeControllerType
        if let active, active != chosen {
            rows.append(Row(
                label: "Źródło",
                verdict: .unknown("ustawione: \(chosen.title), faktycznie odczyt z: \(active.title)"),
                remedy: "\(chosen.title) nic nie zgłosiło, więc Fun Notch przełączył się na źródło, które coś zgłosiło."
            ))
        } else {
            rows.append(Row(label: "Źródło", verdict: .good((active ?? chosen).title)))
        }

        let track = music.track
        rows.append(Row(
            label: "Teraz odtwarzane",
            verdict: track.isEmpty
                ? .unknown("nic")
                : .good("\(track.title)\(track.artist.isEmpty ? "" : " — \(track.artist)")")
        ))

        rows.append(Row(
            label: "Pozycja odtwarzania",
            verdict: track.isEmpty
                ? .unknown("nic nie jest odtwarzane")
                : (track.hasTiming ? .good("znana") : .missing("brak danych")),
            remedy: track.isEmpty || track.hasTiming
                ? nil
                : "Wymaga opcji przeglądarki „Allow JavaScript from Apple Events”; zobacz kartę Multimedia."
        ))

        for browser in BrowserMediaController.scriptableBrowsers {
            guard AppleScriptRunner.isRunning(browser.bundleIdentifier) else { continue }
            let mode = BrowserReadModes.modes[browser.name]
            rows.append(Row(
                label: browser.name,
                verdict: {
                    switch mode {
                    case .some(true): return .good("odczyt ze strony — tytuł, wykonawca, okładka, pozycja")
                    case .some(false): return .missing("odczyt tylko tytułu karty")
                    case nil: return .unknown("działa, nie wykryto jeszcze karty z multimediami")
                    }
                }(),
                remedy: mode == false
                    ? "Włącz dostęp do stron w karcie Multimedia, aby zobaczyć wykonawcę, okładkę i pasek postępu."
                    : nil
            ))
        }

        return Section(title: "Multimedia", rows: rows)
    }

    private func buildPermissions() -> Section {
        var rows: [Row] = []

        rows.append(Row(
            label: "Kalendarze",
            verdict: Self.verdict(
                for: EKEventStore.authorizationStatus(for: .event),
                granted: "agenda i widżet następnego wydarzenia działają"
            ),
            remedy: "Prywatność i ochrona → Kalendarze"
        ))
        rows.append(Row(
            label: "Przypomnienia",
            verdict: Self.verdict(
                for: EKEventStore.authorizationStatus(for: .reminder),
                granted: "przypomnienia pojawiają się w agendzie"
            ),
            remedy: "Prywatność i ochrona → Przypomnienia"
        ))

        let camera = AVCaptureDevice.authorizationStatus(for: .video)
        rows.append(Row(
            label: "Kamera",
            verdict: {
                switch camera {
                case .authorized: return .good("lusterko działa")
                case .notDetermined: return .unknown("jeszcze nie zapytano — potrzebna tylko do lusterka")
                default: return .missing("odmowa — lusterko nie może działać")
                }
            }(),
            remedy: camera == .denied ? "Prywatność i ochrona → Kamera" : nil
        ))

        let location = WeatherManager.shared.authorization
        rows.append(Row(
            label: "Lokalizacja",
            verdict: {
                switch location {
                case .authorized, .authorizedAlways: return .good("pogoda i nazwa sieci Wi‑Fi działają")
                case .notDetermined: return .unknown("jeszcze nie zapytano")
                default: return .missing("odmowa — brak pogody i nazwy sieci Wi‑Fi")
                }
            }(),
            remedy: "macOS ukrywa nazwę sieci Wi‑Fi także za dostępem do lokalizacji."
        ))

        rows.append(Row(
            label: "Dostępność",
            verdict: AXIsProcessTrusted()
                ? .good("przycisk „Włącz dostęp do stron” może działać")
                : .unknown("brak zgody — potrzebna tylko do tego przycisku"),
            remedy: "Prywatność i ochrona → Dostępność"
        ))

        rows.append(Row(
            label: "Automatyzacja",
            verdict: BrowserReadModes.modes.isEmpty && MusicManager.shared.track.isEmpty
                ? .unknown("jeszcze nie sprawdzono — odtwórz coś, aby się przekonać")
                : .good("Fun Notch może komunikować się z odtwarzaczem, z którego czyta"),
            remedy: "Prywatność i ochrona → Automatyzacja, jeśli odtwarzacz działa, ale nigdy się tu nie pojawia."
        ))

        return Section(title: "Uprawnienia", rows: rows)
    }

    /// The failures the app used to hide. An error here names the exact reason
    /// a player is being read badly, or not at all.
    private func buildScriptErrors() -> Section {
        let failures = ScriptErrors.current
        guard !failures.isEmpty else {
            return Section(title: "Skrypty", rows: [
                Row(label: "Ostatni błąd", verdict: .good("brak od uruchomienia")),
            ])
        }

        return Section(title: "Skrypty", rows: failures.map { failure in
            Row(
                label: failure.application,
                verdict: .missing(failure.message),
                remedy: Self.remedy(for: failure.message)
            )
        })
    }

    private static func remedy(for message: String) -> String? {
        let lowered = message.lowercased()
        if lowered.contains("not allowed") || lowered.contains("-1743") {
            return "Dostęp do automatyzacji. Prywatność i ochrona → Automatyzacja."
        }
        if lowered.contains("-1728") || lowered.contains("can’t get") || lowered.contains("can't get") {
            return "Aplikacja odpowiedziała, ale nie tym, o co pytano — zwykle chodzi o okno lub kartę, która została już zamknięta."
        }
        return nil
    }

    private func buildActivity() -> Section {
        Section(title: "Aktywność", rows: [
            Row(
                label: "Ekran",
                verdict: SystemActivityMonitor.shared.isIdle
                    ? .unknown("zablokowany lub uśpiony — odpytywanie zwolniło do co 30 s")
                    : .good("aktywny")
            ),
            Row(
                label: "Sesja Skupienia",
                verdict: FocusManager.shared.isActive
                    ? .good("trwa — zostało \(FocusManager.shared.compactRemainingText), gra jest ukryta")
                    : .unknown("nie trwa")
            ),
            Row(
                label: "HUD",
                verdict: {
                    guard Settings.shared.hudEnabled else { return .unknown("wyłączony") }
                    return HUDManager.shared.isIntercepting
                        ? .good("przechwytuje klawisze multimedialne")
                        : .missing(HUDManager.shared.lastError ?? "nie przechwytuje")
                }(),
                remedy: Settings.shared.hudEnabled && !HUDManager.shared.isIntercepting
                    ? "Prywatność i ochrona → Dostępność, a potem włącz go ponownie w Ustawienia → Aktywności na żywo."
                    : nil
            ),
            Row(
                label: "Sterowanie jasnością",
                verdict: DisplayBrightness.isAvailable
                    ? .good("dostępne")
                    : .missing("ten Mac go nie udostępnia")
            ),
            Row(
                label: "Podświetlenie klawiatury",
                verdict: KeyboardBacklight.isAvailable
                    ? .good("dostępne")
                    : .unknown("brak lub niedostępne")
            ),
            Row(
                label: "AirDrop",
                verdict: ShelfManager.canAirDrop
                    ? .good("dostępny z Półki")
                    : .missing("macOS nie udostępnia usługi AirDrop")
            ),
            Row(label: "Plik dziennika", verdict: .good(DiagnosticLog.fileURL.path)),
        ])
    }

    // MARK: - Helpers

    private static func verdict(for status: EKAuthorizationStatus, granted: String) -> Verdict {
        switch status {
        case .fullAccess, .authorized: return .good(granted)
        case .writeOnly: return .missing("tylko zapis — Fun Notch nie może czytać Twoich wydarzeń")
        case .notDetermined: return .unknown("jeszcze nie zapytano")
        default: return .missing("odmowa")
        }
    }

    private static func tailOfLog(lines: Int) -> [String] {
        // Only the end of the file is read. This is called while building the
        // Diagnostics screen on the main thread, and the log is allowed to grow
        // to a few hundred kilobytes — pulling all of it in to show the last
        // handful of lines was work nobody asked for.
        let text = DiagnosticLog.tail(bytes: 64 * 1024)
        guard !text.isEmpty else { return [] }
        return Array(text.components(separatedBy: "\n").filter { !$0.isEmpty }.suffix(lines))
    }

    /// The whole report as plain text, for pasting into a bug report.
    var plainText: String {
        var out = "Fun Notch diagnostics — \(generated.formatted(.dateTime.locale(Polish.locale)))\n"
        for section in sections {
            out += "\n## \(section.title)\n"
            for row in section.rows {
                out += "  \(row.label): \(row.verdict.text)\n"
                if let remedy = row.remedy {
                    out += "      → \(remedy)\n"
                }
            }
        }
        if !recentLog.isEmpty {
            out += "\n## Recent log\n"
            out += recentLog.map { "  \($0)" }.joined(separator: "\n")
            out += "\n"
        }
        return out
    }
}
