//
//  CatGlyphs.swift
//  FunNotch
//
//  The pieces that put the cat where a generic glyph used to be, so the
//  call sites stay one line and "Kot zamiast ikon" has a single switch
//  (`DecorStore.catEnabled`): off, every glyph is the one it always was.
//

import AppKit
import SwiftUI

enum CatPalette {
    /// The accent of a cat that follows music when the spectrum is not
    /// coloured: the bars were white, and a white collar on a white cat is
    /// invisible.
    static let musicDefault = Color(red: 0.62, green: 0.56, blue: 1.0)

    static func musicTint(_ color: Color) -> Color {
        let srgb = NSColor(color).usingColorSpace(.sRGB)
        guard let srgb, srgb.redComponent > 0.93, srgb.greenComponent > 0.93, srgb.blueComponent > 0.93 else { return color }
        return musicDefault
    }
}

/// A session that has just finished: the cat hops once. One from earlier is
/// simply sitting there, in the colour of "done". With the cat off, the check
/// that draws itself.
struct AgentDoneGlyph: View {
    /// Seconds since the glyph appeared; only the drawn check reads it.
    let time: Double
    var size: CGFloat = 17
    var tint: Color = AgentPalette.done
    /// False for a finish from earlier.
    var fresh = true

    @ObservedObject private var decor = DecorStore.shared

    var body: some View {
        if decor.catEnabled {
            CatView(state: fresh ? .done : .awake, size: size * 1.45, tint: tint)
                .frame(width: size, height: size)
        } else {
            CheckmarkBurst(time: time, size: size, tint: tint)
        }
    }
}

/// The cat that follows music; asleep while nothing plays.
struct MusicCat: View {
    let isPlaying: Bool
    let color: Color
    var size: CGFloat = 20

    var body: some View {
        CatView(state: isPlaying ? .music : .sleeping, size: size, tint: CatPalette.musicTint(color))
    }
}

/// The cat in place of the symbol an empty state used to carry (no agents, an
/// empty shelf): asleep, because nothing is going on. With the cat off, the
/// symbol.
struct CatOrSymbol: View {
    let systemName: String
    var symbolSize: CGFloat = 15
    var symbolWeight: Font.Weight = .regular
    var symbolColor: Color = .white.opacity(0.5)
    var catSize: CGFloat = 30
    var catState: CatState = .sleeping
    var tint: Color = .white.opacity(0.85)

    @ObservedObject private var decor = DecorStore.shared

    var body: some View {
        if decor.catEnabled {
            CatView(state: catState, size: catSize, tint: tint)
        } else {
            Image(systemName: systemName)
                .font(.system(size: symbolSize, weight: symbolWeight))
                .foregroundStyle(symbolColor)
        }
    }
}

/// Every state side by side on a strip of notch black, for the settings page.
struct CatStatesPreview: View {
    private static let perRow = 6

    var body: some View {
        let states = CatState.allCases
        VStack(spacing: 8) {
            ForEach(Array(stride(from: 0, to: states.count, by: Self.perRow)), id: \.self) { start in
                HStack(spacing: 0) {
                    ForEach(states[start ..< min(start + Self.perRow, states.count)]) { state in
                        VStack(spacing: 4) {
                            CatView(state: state, size: 34, tint: Self.tint(for: state))
                                .frame(width: 44, height: 40)
                            Text(state.title)
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    static func tint(for state: CatState) -> Color {
        switch state {
        case .working: return AgentPalette.claude
        case .waiting: return AgentPalette.waiting
        case .done: return AgentPalette.done
        case .music: return CatPalette.musicDefault
        case .texting: return .green
        case .chatting: return .purple
        case .mail: return .cyan
        default: return .white.opacity(0.85)
        }
    }
}

/// The cat in a wing of an island, in the clip the news calls for: peeking up
/// when a thing lands (a screenshot, a download, a copy, an AirDrop), busy
/// with a notification. With the cat off, `fallback` is the symbol the banner
/// always had.
struct CatOr<Fallback: View>: View {
    var state: CatState = .peek
    var tint: Color = .white
    var size: CGFloat = 26
    @ViewBuilder let fallback: Fallback

    @ObservedObject private var decor = DecorStore.shared

    var body: some View {
        if decor.catEnabled {
            CatView(state: state, size: size, tint: tint)
                .frame(width: 24, height: 24)
        } else {
            fallback
        }
    }
}
