//
//  AudioMixerViews.swift
//  FunNotch
//
//  The mixer panel: one row per app that is playing, with a level up to 150%,
//  a mute button and a three-band EQ behind a disclosure.
//

import AppKit
import SwiftUI

struct AudioMixerPanel: View {
    @ObservedObject private var mixer = AudioMixerManager.shared
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            content
            footer
        }
        .onAppear { mixer.setPanelVisible(true) }
        .onDisappear { mixer.setPanelVisible(false) }
    }

    @ViewBuilder
    private var content: some View {
        switch mixer.availability {
        case .unsupportedOS:
            notice(
                symbol: "exclamationmark.triangle",
                text: "Mikser wymaga macOS 14.2 lub nowszego",
                detail: "Starsze systemy nie pozwalają przechwycić dźwięku pojedynczej aplikacji."
            )
        case .permissionDenied:
            notice(
                symbol: "lock.slash",
                text: "Brak zgody na nagrywanie dźwięku systemu",
                detail: "Bez niej Fun Notch nie może zmieniać głośności aplikacji.",
                button: ("Otwórz ustawienia", { mixer.requestPermission() })
            )
        case .available:
            if mixer.apps.isEmpty {
                notice(
                    symbol: "speaker.slash",
                    text: "Żadna aplikacja nie odtwarza dźwięku",
                    detail: "Gdy coś zacznie grać, pojawi się tutaj."
                )
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(mixer.apps) { app in
                            row(app)
                        }
                    }
                }
            }
        }
    }

    // MARK: Rows

    private func row(_ app: MixerApp) -> some View {
        let levels = mixer.levels(for: app.id)
        return VStack(spacing: 2) {
            HStack(spacing: 8) {
                appIcon(app)

                VStack(alignment: .leading, spacing: 0) {
                    Text(app.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(app.isPlaying ? 0.95 : 0.5))
                        .lineLimit(1)
                    if let problem = app.problem {
                        Text(problem)
                            .font(.system(size: 8))
                            .foregroundStyle(Color.orange.opacity(0.9))
                            .lineLimit(1)
                            .help(problem)
                    }
                }
                .frame(width: 118, alignment: .leading)

                HoverButton(
                    systemName: levels.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    size: 11, padding: 4,
                    isActive: levels.muted, tint: .orange
                ) {
                    mixer.update(app.id) { $0.muted.toggle() }
                }
                .help(levels.muted ? "Włącz dźwięk" : "Wycisz")

                NotchSlider(
                    value: Binding(
                        get: { levels.muted ? 0 : levels.volume },
                        set: { value in
                            mixer.update(app.id) {
                                $0.volume = value
                                if value > 0 { $0.muted = false }
                            }
                        }
                    ),
                    range: 0 ... 1.5,
                    color: levels.volume > 1 ? .orange : .white,
                    height: 4
                )
                .frame(height: 14)

                Text(levels.muted ? "0%" : "\(Int((levels.volume * 100).rounded()))%")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 34, alignment: .trailing)

                HoverButton(
                    systemName: "slider.horizontal.3", size: 11, padding: 4,
                    isActive: expanded.contains(app.id) || levels.hasEQ, tint: .accentColor
                ) {
                    withAnimation(.easeOut(duration: 0.18)) {
                        if expanded.contains(app.id) { expanded.remove(app.id) } else { expanded.insert(app.id) }
                    }
                }
                .help("Korektor")

                HoverButton(systemName: "arrow.counterclockwise", size: 10, padding: 4) {
                    mixer.reset(app.id)
                }
                .help("Przywróć domyślne")
                .opacity(levels.isDefault ? 0.25 : 1)
                .disabled(levels.isDefault)
            }

            if expanded.contains(app.id) {
                equaliser(app.id, levels)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .notchCard(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func appIcon(_ app: MixerApp) -> some View {
        Group {
            if let icon = app.icon {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: "app.dashed").resizable().scaledToFit().foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(width: 20, height: 20)
        .opacity(app.isPlaying ? 1 : 0.5)
    }

    private func equaliser(_ id: String, _ levels: MixerAppSettings) -> some View {
        HStack(spacing: 14) {
            band("Basy", value: levels.bass) { value in mixer.update(id) { $0.bass = value } }
            band("Środek", value: levels.mid) { value in mixer.update(id) { $0.mid = value } }
            band("Wysokie", value: levels.treble) { value in mixer.update(id) { $0.treble = value } }
        }
        .padding(.leading, 28)
        .padding(.trailing, 4)
        .padding(.bottom, 2)
    }

    private func band(_ title: String, value: Double, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 40, alignment: .leading)
            NotchSlider(
                value: Binding(
                    get: { value },
                    // Whole decibels, snapping to flat in the middle.
                    set: { set(abs($0) < 0.8 ? 0 : $0.rounded()) }
                ),
                range: -12 ... 12,
                color: value == 0 ? .white.opacity(0.7) : .accentColor,
                height: 3
            )
            .frame(height: 12)
            Text(String(format: "%+d dB", Int(value)))
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 38, alignment: .trailing)
        }
    }

    // MARK: Messages

    @ViewBuilder
    private var footer: some View {
        if mixer.availability == .available, mixer.permission == .notDetermined || mixer.permission == .unknown {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                Text("Przy pierwszej zmianie macOS zapyta o zgodę na nagrywanie dźwięku systemu.")
                Spacer(minLength: 0)
                Button("Zezwól teraz") { mixer.requestPermission() }
                    .buttonStyle(NotchPressStyle())
                    .foregroundStyle(.white.opacity(0.95))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .notchControl(in: Capsule(), resting: true)
            }
            .font(.system(size: 9))
            .foregroundStyle(.white.opacity(0.4))
        }
    }

    private func notice(
        symbol: String, text: String, detail: String,
        button: (title: String, action: () -> Void)? = nil
    ) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(.white.opacity(0.5))
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
            if let button {
                Button(button.title, action: button.action)
                    .buttonStyle(NotchPressStyle())
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .notchControl(in: Capsule(), resting: true)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
