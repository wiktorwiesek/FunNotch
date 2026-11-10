//
//  TeleprompterControlsView.swift
//  FunNotch
//
//  The small control strip at the bottom of the prompter. It is drawn at zero
//  opacity and does not take clicks until the pointer is over the panel, so a
//  reader who is not touching the mouse sees only the text.
//

import SwiftUI

/// What the prompter shares with its controls: whether it is playing, whether
/// the pointer is over it, and the one closure that carries every button press.
@MainActor
final class TeleprompterModel: ObservableObject {
    enum Command {
        case togglePlay, slower, faster, smaller, larger, toggleVoice, restart, edit, close
    }

    @Published var isPlaying = false
    @Published var isHovering = false
    var perform: (Command) -> Void = { _ in }
}

struct TeleprompterControlsView: View {
    @ObservedObject var model: TeleprompterModel
    @ObservedObject var store: TeleprompterStore

    var body: some View {
        HStack(spacing: 4) {
            control(model.isPlaying ? "pause.fill" : "play.fill",
                    model.isPlaying ? "Wstrzymaj (spacja)" : "Czytaj (spacja)",
                    active: model.isPlaying, .togglePlay)

            divider

            control("tortoise.fill", "Wolniej (↓)", .slower)
            Text("\(Int(store.wordsPerMinute))")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
                .frame(minWidth: 26)
                .help("Słów na minutę")
            control("hare.fill", "Szybciej (↑)", .faster)

            divider

            control("textformat.size.smaller", "Mniejszy tekst", .smaller)
            control("textformat.size.larger", "Większy tekst", .larger)

            divider

            control(store.voiceFollow ? "mic.fill" : "mic.slash",
                    store.voiceFollow ? "Podążanie za głosem: włączone" : "Podążanie za głosem: wyłączone",
                    active: store.voiceFollow, .toggleVoice)
            control("arrow.counterclockwise", "Od początku", .restart)

            Spacer(minLength: 8)

            control("pencil", "Edytuj tekst", .edit)
            control("xmark", "Zamknij (Esc)", .close)
        }
        .padding(.horizontal, 12)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.9)], startPoint: .top, endPoint: .bottom)
        )
        .opacity(model.isHovering ? 1 : 0)
        .allowsHitTesting(model.isHovering)
        .animation(.easeOut(duration: 0.15), value: model.isHovering)
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.15))
            .frame(width: 1, height: 14)
            .padding(.horizontal, 3)
    }

    private func control(
        _ symbol: String, _ label: String, active: Bool = false, _ command: TeleprompterModel.Command
    ) -> some View {
        Button { model.perform(command) } label: {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
                .notchControl(in: RoundedRectangle(cornerRadius: 8, style: .continuous), tint: .blue, active: active)
        }
        .buttonStyle(NotchPressStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}
