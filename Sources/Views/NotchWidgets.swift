//
//  NotchWidgets.swift
//  FunNotch
//
//  The small readouts that can sit either side of the camera cutout while the
//  notch is collapsed — and, optionally, in the black banner an app leaves
//  behind when it goes fullscreen.
//
//  Each side reports the width it actually needs rather than declaring one up
//  front: "11:56 AM", "23:56" and "Wed 13 Sept 23:56" are all very different
//  sizes, and a hard-coded guess would clip in some locales.
//

import AppKit
import SwiftUI

/// Measured widths of the widget stacks currently on screen, keyed by side.
struct WidgetWidthKey: PreferenceKey {
    static let defaultValue: [NotchSide: CGFloat] = [:]

    static func reduce(value: inout [NotchSide: CGFloat], nextValue: () -> [NotchSide: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: max)
    }
}

enum NotchSide: Hashable {
    case leading
    case trailing
}

/// A whole side's worth of widgets, measured as one unit.
struct NotchWidgetStack: View {
    let widgets: [NotchWidget]
    let side: NotchSide

    /// Breathing room between the stack and the cutout, plus enough margin for
    /// the notch's rounded outer corner.
    private let inset: CGFloat = 12
    private let outerMargin: CGFloat = 14

    var body: some View {
        HStack(spacing: 12) {
            ForEach(widgets) { widget in
                NotchWidgetButton(widget: widget)
            }
        }
        // Laid out at its ideal width, whatever the slot offers. Otherwise the
        // first (estimated) slot squeezes the wide widgets, the squeezed width
        // is what gets measured, and the notch creeps outwards one layout pass
        // at a time with the text flush against its rounded corners meanwhile.
        .fixedSize(horizontal: true, vertical: false)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: WidgetWidthKey.self,
                    value: [side: proxy.size.width + inset + outerMargin]
                )
            }
        )
        .padding(side == .leading ? .trailing : .leading, inset)
        .frame(maxWidth: .infinity, alignment: side == .leading ? .trailing : .leading)
    }
}

/// Wraps a widget so clicking it goes somewhere useful instead of just opening
/// the notch.
private struct NotchWidgetButton: View {
    let widget: NotchWidget

    @EnvironmentObject private var viewModel: NotchViewModel
    @State private var isHovering = false

    var body: some View {
        Group {
            if widget.clickTarget != nil {
                Button(action: activate) { content }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
                    }
                    .scaleEffect(isHovering ? 1.06 : 1)
            } else {
                content
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch widget {
        case .battery: BatteryWidget()
        case .clock: ClockWidget(showsDate: false)
        case .date: ClockWidget(showsDate: true)
        case .focusTimer: FocusTimerWidget()
        case .nextEvent: NextEventWidget()
        case .nowPlaying: NowPlayingWidget()
        case .cpu: StatWidget(kind: .cpu)
        case .memory: StatWidget(kind: .memory)
        case .disk: StatWidget(kind: .disk)
        case .weather: WeatherWidget()
        case .wifi: WiFiWidget()
        case .moonPhase: MoonWidget()
        case .shelfCount: ShelfCountWidget()
        case .unread: UnreadWidget()
        case .keepAwake: KeepAwakeWidget()
        case .micMute: MicMuteWidget()
        case .privacy: PrivacyWidget()
        case .audioOutput: AudioOutputWidget()
        case .network: NetworkWidget()
        case .gpu: StatWidget(kind: .gpu)
        case .cpuTemperature: StatWidget(kind: .temperature)
        }
    }

    private func activate() {
        guard let target = widget.clickTarget else { return }
        switch target {
        case let .settingsPane(identifier):
            if let url = URL(string: "x-apple.systempreferences:\(identifier)") {
                NSWorkspace.shared.open(url)
            }
        case let .app(bundleIdentifier):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            else { return }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        case .nextMeeting:
            guard let item = CalendarManager.shared.nextItem else { return }
            if item.meetingURL != nil {
                CalendarManager.shared.joinMeeting(item)
            } else {
                CalendarManager.shared.open(item: item)
            }
        case .playingApp:
            MusicManager.shared.openPlayingApp()
        case .focusTab:
            viewModel.currentTab = .focus
            viewModel.open()
        case .shelfTab:
            viewModel.currentTab = .shelf
            viewModel.open()
        case .unreadApp:
            UnreadBadgesManager.shared.openFirst()
        case .locationAccess:
            if WeatherManager.shared.isLocationAuthorized {
                if let url = URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension") {
                    NSWorkspace.shared.open(url)
                }
            } else {
                WeatherManager.shared.requestAccess()
            }
        case .toggleKeepAwake:
            KeepAwakeManager.shared.toggle()
        case .toggleMicMute:
            MicMuteManager.shared.toggle()
        case .audioOutputMenu:
            AudioOutputManager.shared.showMenu()
        }
    }
}

// MARK: - Individual widgets

private struct BatteryWidget: View {
    @ObservedObject private var battery = BatteryManager.shared

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: battery.symbolName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(battery.indicatorColor)
            Text(battery.percentageText)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
        }
        .fixedSize()
    }
}

private struct ClockWidget: View {
    let showsDate: Bool

    var body: some View {
        // A minute-granularity timeline keeps this honest without a timer.
        TimelineView(.everyMinute) { context in
            Text(Self.formatter(showsDate: showsDate).string(from: Motion.filmDate ?? context.date))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize()
        }
    }

    private static func formatter(showsDate: Bool) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Polish.locale
        if showsDate {
            formatter.dateFormat = Locale.current.hasTwelveHourClock ? "E d MMM  h:mm a" : "E d MMM  HH:mm"
        } else {
            formatter.dateFormat = Locale.current.hasTwelveHourClock ? "h:mm a" : "HH:mm"
        }
        return formatter
    }
}

/// The focus countdown, or a running timer when there is no session — they
/// share a tab now, so they share the widget too.
private struct FocusTimerWidget: View {
    @ObservedObject private var focus = FocusManager.shared
    @ObservedObject private var timer = TimerManager.shared
    @EnvironmentObject private var settings: Settings
    @ObservedObject private var decor = DecorStore.shared

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .medium))
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
            // A mascot rides a track beside the numbers while a countdown
            // is counting; a stopwatch has no end to ride towards.
            if decor.mascot != .none, focus.isActive || showsTimer {
                DecorMascotTrack(
                    mascot: decor.mascot,
                    progress: focus.isActive ? focus.progress : timer.progress,
                    tint: colour,
                    isMoving: focus.isActive || timer.isCountdownRunning
                )
                .padding(.leading, 4)
            }
        }
        .foregroundStyle(colour)
        .fixedSize()
    }

    private var showsTimer: Bool { !focus.isActive && timer.countdownIsSet }

    private var symbol: String {
        if showsTimer { return timer.finished ? "bell.fill" : "timer" }
        return focus.isOnBreak ? "cup.and.saucer" : "cup.and.saucer.fill"
    }

    private var text: String {
        if focus.isActive { return focus.compactRemainingText }
        if showsTimer { return timer.finished ? "0:00" : TimerManager.clock(timer.remaining) }
        return "—"
    }

    private var colour: Color {
        if focus.isActive { return focus.isOnBreak ? ClockPalette.rest : settings.accentColor }
        if showsTimer { return timer.finished ? ClockPalette.alarm : ClockPalette.timer }
        return .white.opacity(0.4)
    }
}

private struct NextEventWidget: View {
    @ObservedObject private var calendar = CalendarManager.shared

    var body: some View {
        Group {
            if let event = calendar.nextItem {
                HStack(spacing: 4) {
                    if event.meetingURL != nil {
                        Image(systemName: "video.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(event.calendarColor)
                    } else {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(event.calendarColor)
                            .frame(width: 2.5, height: 14)
                    }
                    VStack(alignment: .leading, spacing: -1) {
                        Text(event.title)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.95))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(event.countdownText ?? event.timeText)
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    // Long titles would otherwise push the notch across the
                    // whole screen, so the text gets a ceiling.
                    .frame(maxWidth: 118, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(calendar.hasEventAccess ? "Brak wydarzeń" : "Kalendarz wyłączony")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize()
            }
        }
    }
}

private struct NowPlayingWidget: View {
    @ObservedObject private var music = MusicManager.shared

    var body: some View {
        Group {
            if music.track.isEmpty {
                Text("Nic nie gra")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize()
            } else {
                HStack(spacing: 4) {
                    if let artwork = music.artwork {
                        Image(nsImage: artwork)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 15, height: 15)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    VStack(alignment: .leading, spacing: -1) {
                        Text(music.track.title)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.95))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(music.track.artist)
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: 122, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct StatWidget: View {
    enum Kind { case cpu, memory, disk, gpu, temperature }
    let kind: Kind

    @ObservedObject private var stats = SystemStatsManager.shared

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
        }
        .fixedSize()
        // Each widget asks the manager for its own metric only.
        .onAppear { stats.addSubscriber(metric) }
        .onDisappear { stats.removeSubscriber(metric) }
    }

    private var metric: SystemStatsManager.Metrics {
        switch kind {
        case .cpu: return .cpu
        case .memory: return .memory
        case .disk: return .disk
        case .gpu: return .gpu
        case .temperature: return .temperature
        }
    }

    private var symbol: String {
        switch kind {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        case .gpu: return "display"
        case .temperature: return "thermometer.medium"
        }
    }

    private var value: String {
        switch kind {
        case .cpu: return stats.cpuText
        case .memory: return stats.memoryText
        case .disk: return stats.diskFreeText
        case .gpu: return stats.gpuText
        case .temperature: return stats.temperatureText
        }
    }

    private var tint: Color {
        let usage: Double
        switch kind {
        case .cpu: usage = stats.cpuUsage
        case .memory: usage = stats.memoryUsage
        case .disk: usage = stats.diskUsage
        case .gpu: usage = stats.gpuUsage ?? 0
        case .temperature:
            // Degrees rather than a fraction: amber from 85 °C, red from 95 °C.
            guard let degrees = stats.cpuTemperature else { return .white.opacity(0.7) }
            if degrees >= 95 { return .red }
            if degrees >= 85 { return .orange }
            return .white.opacity(0.7)
        }
        if usage > 0.9 { return .red }
        if usage > 0.75 { return .orange }
        return .white.opacity(0.7)
    }
}

/// Download over upload, two short lines. The lines have a fixed width and
/// monospaced digits so the notch does not change width on every tick.
private struct NetworkWidget: View {
    @ObservedObject private var stats = SystemStatsManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: -1) {
            line("↓", stats.downloadText)
            line("↑", stats.uploadText)
        }
        .fixedSize()
        .onAppear { stats.addSubscriber(.network) }
        .onDisappear { stats.removeSubscriber(.network) }
    }

    private func line(_ arrow: String, _ value: String) -> some View {
        HStack(spacing: 2) {
            Text(arrow)
                .foregroundStyle(.white.opacity(0.5))
            Spacer(minLength: 0)
            Text(value)
                .foregroundStyle(.white.opacity(0.85))
        }
        .font(.system(size: 9, weight: .medium, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
        .frame(width: 52)
    }
}

private struct WeatherWidget: View {
    @ObservedObject private var weather = WeatherManager.shared

    var body: some View {
        HStack(spacing: 4) {
            if let conditions = weather.conditions {
                PixelWeatherIcon(scene: WeatherScene.from(code: conditions.weatherCode, isDay: conditions.isDay))
            } else {
                Image(systemName: weather.symbolName)
                    .font(.system(size: 10, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white.opacity(0.85))
            }
            Text(weather.temperatureText ?? "—")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
        }
        .fixedSize()
        .help(weather.lastError ?? weather.conditions?.placeName ?? "Pogoda")
        .onAppear { weather.addSubscriber() }
        .onDisappear { weather.removeSubscriber() }
    }
}

private struct WiFiWidget: View {
    @ObservedObject private var wifi = WiFiMonitor.shared

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(wifi.isConnected ? 0.85 : 0.45))
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(wifi.isConnected ? 0.85 : 0.55))
                .lineLimit(1)
        }
        .fixedSize()
        .help(helpText)
        .onAppear { wifi.addSubscriber() }
        .onDisappear { wifi.removeSubscriber() }
    }

    private var symbol: String {
        wifi.isConnected ? "wifi" : "wifi.slash"
    }

    // Without location access macOS withholds the network name; the widget
    // then says only whether there is a connection.
    private var label: String {
        if let network = wifi.network, !network.isEmpty { return network }
        return wifi.isConnected ? "Połączono" : "Brak sieci"
    }

    private var helpText: String {
        wifi.isLocationAuthorized || !wifi.isConnected
            ? "Sieć Wi-Fi"
            : "macOS podaje nazwę sieci tylko aplikacjom z dostępem do lokalizacji. Kliknij, aby przyznać dostęp."
    }
}

private struct MoonWidget: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            HStack(spacing: 4) {
                Image(systemName: MoonPhase.symbol(on: context.date))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                Text("\(Int(round(MoonPhase.fraction(on: context.date) * 100)))%")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))
            }
            .fixedSize()
            .help(MoonPhase.name(on: context.date))
        }
    }
}

/// How many files are waiting on the shelf.
///
/// `ShelfView` already says "3 items", but only once you have opened the notch
/// and are looking straight at the shelf — the one moment you do not need
/// telling. On the closed notch it is what stops the shelf becoming a place
/// people put things and then forget about.
private struct ShelfCountWidget: View {
    @ObservedObject private var shelf = ShelfManager.shared

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: shelf.items.isEmpty ? "tray" : "tray.full")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(shelf.items.isEmpty ? 0.45 : 0.85))
            Text("\(shelf.items.count)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.7))
        }
        .fixedSize()
        .help(shelf.items.isEmpty
              ? "Półka jest pusta"
              : "\(Polish.count(shelf.items.count, "element", "elementy", "elementów")) na Półce")
    }
}

/// Unread messages in Slack, Vesktop or Discord, as their Dock badges say:
/// each app's icon with its count, or a quiet bubble when all is read.
private struct UnreadWidget: View {
    @ObservedObject private var unread = UnreadBadgesManager.shared

    var body: some View {
        HStack(spacing: 6) {
            if unread.badges.isEmpty {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            } else {
                ForEach(unread.badges) { badge in
                    HStack(spacing: 2) {
                        if let icon = UnreadBadgesManager.icon(for: badge.bundleIdentifier) {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 14, height: 14)
                        }
                        Text(badge.label)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.4))
                    }
                }
            }
        }
        .fixedSize()
        .onAppear { unread.start() }
        .help(unread.badges.isEmpty ? "Brak nieprzeczytanych wiadomości" : "Nieprzeczytane wiadomości. Kliknij, aby otworzyć.")
    }
}
