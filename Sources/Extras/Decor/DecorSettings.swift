//
//  DecorSettings.swift
//  FunNotch
//
//  The "Wygląd" section of the extras page: HUD style, timer mascots, the idle
//  animation and Liquid Glass.
//

import AppKit
import SwiftUI

struct DecorSettings: View {
    @ObservedObject private var store = DecorStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            hudCard
            catCard
            mascotCard
            idleCard
            glassCard
        }
    }

    // MARK: - HUD

    private var hudCard: some View {
        SettingsCard(
            title: "Wskaźnik głośności i jasności",
            footer: "Pasek i wskaźnik pojawiają się na ekranie, na którym jest wskaźnik myszy. Działają tak samo jak baner w notchu: po naciśnięciu klawiszy głośności, jasności i podświetlenia klawiatury."
        ) {
            SettingsPicker(
                title: "Styl",
                symbol: "slider.horizontal.below.rectangle",
                tint: SettingsStyle.blue,
                selection: $store.hudStyle
            ) {
                ForEach(DecorHUDStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }

            if store.hudStyle != .notch {
                SettingsSlider(
                    title: "Rozmiar",
                    value: $store.hudScale,
                    range: 0.6 ... 2,
                    step: 0.05,
                    format: { "\(Int(($0 * 100).rounded()))%" }
                )
            }

            SettingsRow(title: "Podgląd", subtitle: "Pokazuje wskaźnik z poziomem 60%.") {
                Button("Pokaż") { previewHUD() }
                    .controlSize(.small)
            }
        }
    }

    private func previewHUD() {
        if store.hudStyle == .notch {
            HUDManager.shared.injectPreview(.volume, value: 0.6)
        } else {
            DecorHUDOverlay.shared.present(kind: .volume, value: 0.6, muted: false, duration: 2)
        }
    }

    // MARK: - Cat

    private var catCard: some View {
        SettingsCard(
            title: "Kot",
            footer: "Kot to mały maskot rysowany raz i odtwarzany przez system, więc prawie nie obciąża procesora. Zatrzymuje się, gdy notch jest ukryty, ekran zgaszony, włączone jest oszczędzanie energii albo ograniczenie ruchu."
        ) {
            SettingsToggle(
                title: "Kot zamiast ikon",
                subtitle: "Pracujący, czekający i skończony agent, muzyka, zrzuty i pliki oraz puste listy. Po wyłączeniu wracają dawne ikony.",
                symbol: "cat.fill",
                tint: SettingsStyle.orange,
                isOn: $store.catEnabled
            )

            SettingsToggle(
                title: "Kot zawsze w notchu",
                subtitle: "Mieszka po lewej stronie wycięcia: czuwa, gdy jesteś przy Macu, zasypia po kilku minutach bez ruchu, a obok widżetów zastępuje lampkę agenta. Zajmuje własne miejsce przy kamerze.",
                symbol: "pawprint.fill",
                tint: SettingsStyle.pink,
                isOn: $store.catResident
            )
            .disabled(!store.catEnabled)

            CatStatesPreview()
                .opacity(store.catEnabled ? 1 : 0.45)
        }
    }

    // MARK: - Mascots

    private var mascotCard: some View {
        SettingsCard(
            title: "Maskotka minutnika",
            footer: "Maskotka biegnie po cienkiej ścieżce obok odliczania w zamkniętym notchu podczas sesji skupienia. Podczas minutnika pokazuje ją widżet „Minutnik skupienia”, który dodasz w oknie „Dostosuj notch”."
        ) {
            SettingsPicker(
                title: "Maskotka",
                symbol: "pawprint.fill",
                tint: SettingsStyle.orange,
                selection: $store.mascot
            ) {
                ForEach(DecorMascot.allCases) { mascot in
                    Text(mascot.title).tag(mascot)
                }
            }

            HStack(spacing: 0) {
                ForEach(DecorMascot.allCases.filter { $0 != .none }) { mascot in
                    Button {
                        store.mascot = mascot
                    } label: {
                        VStack(spacing: 6) {
                            DecorMascotFigure(mascot: mascot, scale: 1.7)
                            Text(mascot.title)
                                .font(.system(size: 11))
                                .foregroundStyle(store.mascot == mascot ? Color.primary : Color.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(store.mascot == mascot ? Color.accentColor.opacity(0.18) : .clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            if store.mascot != .none {
                SettingsRow(title: "Podgląd na ścieżce") {
                    DecorMascotLoopPreview(mascot: store.mascot)
                }
            }
        }
    }

    // MARK: - Idle animation

    private var idleCard: some View {
        SettingsCard(
            title: "Własna animacja bezczynności",
            footer: "Obsługiwane są animowane pliki GIF i APNG. Pliki Lottie (JSON) wymagałyby dodatkowej biblioteki, więc nie są wspierane. Animacja pojawia się obok kamery tylko wtedy, gdy nic innego nie zajmuje notcha."
        ) {
            SettingsToggle(
                title: "Pokazuj animację w zamkniętym notchu",
                symbol: "sparkles",
                tint: SettingsStyle.pink,
                isOn: Binding(
                    get: { store.idleEnabled },
                    set: { store.idleEnabled = $0 }
                )
            )

            SettingsRow(
                title: "Plik",
                subtitle: store.idleName ?? "Nie wybrano pliku"
            ) {
                HStack(spacing: 8) {
                    if store.idleIsLoading {
                        ProgressView().controlSize(.small)
                    }
                    if store.hasIdleFile || store.idleAnimation != nil {
                        Button("Usuń") { store.removeIdleFile() }
                            .controlSize(.small)
                    }
                    Button(store.hasIdleFile ? "Zmień…" : "Wybierz…") { chooseFile() }
                        .controlSize(.small)
                }
            }

            if let error = store.idleError {
                SettingsStatus(text: error, symbol: "exclamationmark.triangle.fill", tint: .orange)
            } else if let animation = store.idleAnimation {
                SettingsStatus(
                    text: animation.isStatic
                        ? "To obraz bez animacji, więc będzie nieruchomy."
                        : "\(Polish.count(animation.frames.count, "klatka", "klatki", "klatek")), pętla trwa \(String(format: "%.1f", animation.duration).replacingOccurrences(of: ".", with: ",")) s.",
                    symbol: "checkmark.circle.fill",
                    tint: .green
                )
            }

            if store.idleAnimation != nil {
                SettingsPicker(title: "Strona", selection: $store.idleSide) {
                    ForEach(DecorIdleSide.allCases) { side in
                        Text(side.title).tag(side)
                    }
                }

                SettingsSlider(
                    title: "Szybkość",
                    value: $store.idleSpeed,
                    range: 0.25 ... 3,
                    step: 0.05,
                    format: { String(format: "%.2f×", $0).replacingOccurrences(of: ".", with: ",") }
                )

                SettingsSlider(
                    title: "Rozmiar",
                    value: $store.idleScale,
                    range: 0.5 ... 1.6,
                    step: 0.05,
                    format: { "\(Int(($0 * 100).rounded()))%" }
                )

                SettingsSlider(
                    title: "Przesunięcie w pionie",
                    value: $store.idleOffsetY,
                    range: -8 ... 8,
                    step: 0.5,
                    format: { String(format: "%+.1f", $0).replacingOccurrences(of: ".", with: ",") }
                )

                SettingsRow(title: "Podgląd na żywo") {
                    DecorIdlePreview()
                }
            }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Wybierz animację"
        panel.message = "Animowany plik GIF albo APNG"
        panel.prompt = "Wybierz"
        panel.allowedContentTypes = DecorAnimation.supportedTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.chooseIdleFile(url)
    }

    // MARK: - Liquid Glass

    private var glassCard: some View {
        SettingsCard(
            title: "Liquid Glass",
            footer: "Szklane tło panelu i banerów wymaga macOS 26 lub nowszego; na starszych systemach zostaje czarne. Przyciski i kafelki dostają wtedy szkło rysowane."
        ) {
            if !DecorStore.glassIsAvailable {
                SettingsStatus(
                    text: "Ten Mac ma starszy system niż macOS 26, więc przełączniki tła są wyłączone.",
                    symbol: "info.circle.fill",
                    tint: .secondary
                )
            }

            SettingsToggle(
                title: "Otwarty panel notcha",
                subtitle: "Szklane tło zamiast czarnego po otwarciu notcha.",
                symbol: "rectangle.on.rectangle",
                tint: SettingsStyle.teal,
                isOn: $store.glassPanel
            )
            .disabled(!DecorStore.glassIsAvailable)

            SettingsToggle(
                title: "Banery wyspy",
                subtitle: "Szklane tło komunikatów, takich jak „Wysuń” albo kopiowanie, na ekranie bez notcha.",
                symbol: "capsule.portrait",
                tint: SettingsStyle.teal,
                isOn: $store.glassBanners,
                preview: DecorStore.glassIsAvailable ? { previewBanner() } : nil
            )
            .disabled(!DecorStore.glassIsAvailable)

            SettingsToggle(
                title: "Systemowe szkło (Liquid Glass)",
                subtitle: "Przyciski i kafelki w otwartym notchu. Na macOS starszym niż 26 używane jest szkło rysowane.",
                symbol: "square.stack.3d.up.fill",
                tint: SettingsStyle.teal,
                isOn: $store.systemGlass
            )
        }
    }

    private func previewBanner() {
        IslandCenter.shared.post(
            Island(
                symbol: "sparkles",
                tint: .white,
                title: "Podgląd",
                detail: "tak wygląda baner",
                trailing: "OK",
                duration: 3
            )
        )
    }
}

// MARK: - Previews

/// The mascot running a loop of its track, for settings.
private struct DecorMascotLoopPreview: View {
    let mascot: DecorMascot

    var body: some View {
        TimelineView(DecorClock.schedule) { context in
            let loop = 5.0
            let progress = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: loop) / loop
            DecorMascotTrack(mascot: mascot, progress: progress, tint: .accentColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(.black))
        }
    }
}

/// A mock closed notch with the idle animation in it, driven by the sliders.
private struct DecorIdlePreview: View {
    @ObservedObject private var store = DecorStore.shared

    var body: some View {
        let inset = store.idleInset
        let cutout: CGFloat = 96
        let rowHeight: CGFloat = 32
        let wings = store.idleSide
        let leadingWidth = wings == .trailing ? 0 : inset
        let trailingWidth = wings == .leading ? 0 : inset
        let wing = max(leadingWidth, trailingWidth)

        HStack(spacing: 0) {
            slot(visible: leadingWidth > 0)
                .frame(width: wing, height: rowHeight)
            Color.clear.frame(width: cutout, height: rowHeight)
                .overlay(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.06)).padding(.horizontal, 6).padding(.vertical, 5))
            slot(visible: trailingWidth > 0)
                .frame(width: wing, height: rowHeight)
        }
        .background(
            UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12)
                .fill(.black)
        )
        .animation(.easeOut(duration: 0.15), value: inset)
    }

    @ViewBuilder
    private func slot(visible: Bool) -> some View {
        if visible, let animation = store.idleAnimation {
            DecorAnimationView(animation: animation, speed: store.idleSpeed, size: store.idleSize)
                .offset(y: CGFloat(store.idleOffsetY))
        } else {
            Color.clear
        }
    }
}
