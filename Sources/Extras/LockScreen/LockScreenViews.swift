//
//  LockScreenViews.swift
//  FunNotch
//
//  The cards drawn above the lock screen: now playing, focus/timer, charging
//  and weather. They only read what the existing managers already know, and
//  none of them starts anything — in particular the weather card never asks for
//  a fetch, so a locked Mac does not wake up the location service.
//
//  Cards that have nothing to say are left out, so the stack is only as tall
//  as it needs to be; the panel follows the measured size.
//

import AppKit
import SwiftUI

/// The size the stack of cards actually takes, reported to the panel.
private struct LockScreenSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct LockScreenWidgetsView: View {
    var onSize: @MainActor (CGSize) -> Void

    // Observed only while this view exists, i.e. while the screen is locked.
    @ObservedObject private var music = MusicManager.shared
    @ObservedObject private var focus = FocusManager.shared
    @ObservedObject private var timer = TimerManager.shared
    @ObservedObject private var battery = BatteryManager.shared
    @ObservedObject private var weather = WeatherManager.shared

    var body: some View {
        VStack(spacing: 10) {
            if LockScreenPrefs.nowPlaying, !music.track.isEmpty {
                NowPlayingCard(music: music)
            }
            if LockScreenPrefs.focus {
                if focus.isActive {
                    TimerCard(
                        title: focus.isOnBreak ? "Przerwa" : "Skupienie",
                        symbol: focus.isOnBreak ? "cup.and.saucer.fill" : "scope",
                        tint: focus.isOnBreak ? .green : .orange,
                        end: focus.endDate,
                        fallback: focus.remaining
                    )
                } else if timer.isCountdownRunning {
                    TimerCard(
                        title: "Minutnik",
                        symbol: "timer",
                        tint: .yellow,
                        end: timer.endDate,
                        fallback: timer.remaining
                    )
                }
            }
            if LockScreenPrefs.charging, battery.isPluggedIn {
                ChargingCard(battery: battery)
            }
            if LockScreenPrefs.weather, let conditions = weather.conditions {
                WeatherCard(
                    symbol: weather.symbolName,
                    temperature: weather.temperatureText ?? "—",
                    place: conditions.placeName
                )
            }
        }
        .frame(width: LockScreenWindow.width)
        .environment(\.colorScheme, .dark)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: LockScreenSizeKey.self, value: proxy.size)
            }
        )
        .onPreferenceChange(LockScreenSizeKey.self) { size in
            MainActor.assumeIsolated { onSize(size) }
        }
    }
}

// MARK: - Card chrome

private extension View {
    /// Dark translucent rounded card with white text.
    func lockScreenCard() -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return self
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(Color.black.opacity(0.45)))
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
    }
}

// MARK: - Now playing

private struct NowPlayingCard: View {
    @ObservedObject var music: MusicManager

    var body: some View {
        HStack(spacing: 12) {
            artwork
            VStack(alignment: .leading, spacing: 2) {
                Text(music.track.title.isEmpty ? "Nieznany utwór" : music.track.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                if !music.track.artist.isEmpty {
                    Text(music.track.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                control("backward.fill", size: 14) { music.previousTrack() }
                control(music.track.isPlaying ? "pause.fill" : "play.fill", size: 18) { music.togglePlayPause() }
                control("forward.fill", size: 14) { music.nextTrack() }
            }
        }
        .lockScreenCard()
    }

    @ViewBuilder
    private var artwork: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        if let image = music.artwork {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 48, height: 48)
                .clipShape(shape)
        } else {
            Image(systemName: "music.note")
                .font(.system(size: 20))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 48, height: 48)
                .background(shape.fill(Color.white.opacity(0.1)))
        }
    }

    private func control(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Focus / timer

private struct TimerCard: View {
    let title: String
    let symbol: String
    let tint: Color
    /// When the countdown ends. Nil only for a paused one, which shows
    /// `fallback` instead.
    let end: Date?
    let fallback: TimeInterval

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 32)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Spacer(minLength: 4)
            if let end {
                // Ticks only while this card is on screen.
                TimelineView(.periodic(from: Date(), by: 1)) { context in
                    clock(end.timeIntervalSince(context.date))
                }
            } else {
                clock(fallback)
            }
        }
        .lockScreenCard()
    }

    private func clock(_ seconds: TimeInterval) -> some View {
        Text(Self.format(seconds))
            .font(.system(size: 22, weight: .medium, design: .rounded))
            .monospacedDigit()
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let total = Int(max(seconds, 0).rounded(.up))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - Charging

private struct ChargingCard: View {
    @ObservedObject var battery: BatteryManager

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: battery.isCharging ? "bolt.fill" : "powerplug.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.green)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(battery.percentageText)
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                Text(status)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: battery.symbolName)
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(0.8))
        }
        .lockScreenCard()
    }

    private var status: String {
        if battery.isCharging { return battery.timeRemainingText ?? "Ładowanie" }
        return battery.isCharged ? "Naładowana" : "Podłączona do zasilania"
    }
}

// MARK: - Weather

private struct WeatherCard: View {
    let symbol: String
    let temperature: String
    let place: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 22))
                .frame(width: 32)
            Text(place ?? "Pogoda")
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(temperature)
                .font(.system(size: 22, weight: .medium, design: .rounded))
                .monospacedDigit()
        }
        .lockScreenCard()
    }
}
