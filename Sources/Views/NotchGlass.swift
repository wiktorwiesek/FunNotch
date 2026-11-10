//
//  NotchGlass.swift
//  FunNotch
//
//  One glass look for every button, tab, card and row inside the open notch.
//
//  Two materials share one API:
//   - `.system`: Apple's Liquid Glass (`glassEffect`, macOS 26+), used while
//     the "Systemowe szkło" setting is on.
//   - `.drawn`: gradient fill, a sheen along the top edge and a hairline rim,
//     for older systems and for anyone who switches the setting off.
//  Both are a pure *background*: they never take part in layout, so a view
//  looks the same size and in the same place whichever material it gets. That
//  also lets the offscreen snapshot renderer (which cannot draw system glass)
//  check the layout of the drawn variant and stand in for both.
//
//  Motion rules: hover and press are the only things that animate here, each
//  driven by an explicit value (`hovering`, `isPressed`, `selected`). Nothing
//  runs per frame, so an idle notch costs no more with glass than without.
//

import SwiftUI

// MARK: - Material

enum NotchGlassMaterial {
    case system
    case drawn

    /// System glass needs macOS 26 *and* the setting; anything else is drawn.
    static func resolve(setting: Bool) -> NotchGlassMaterial {
        if #available(macOS 26.0, *), setting { return .system }
        return .drawn
    }

    @MainActor
    static var current: NotchGlassMaterial {
        resolve(setting: DecorStore.shared.systemGlass)
    }
}

/// Springs shared by every glass control, so hover and press feel alike
/// everywhere in the notch.
enum NotchGlassMotion {
    static let hover = Animation.spring(response: 0.3, dampingFraction: 0.85)
    static let press = Animation.spring(response: 0.22, dampingFraction: 0.7)
    /// Selection moving between tabs or days.
    static let select = Animation.spring(response: 0.35, dampingFraction: 0.82)
}

// MARK: - Surface

/// The glass itself, to be used as a `.background`.
///
/// - tint: colours the glass (an action that is on, a selected day).
/// - lit: brighter, as under the pointer or for the selected item.
/// - interactive: lets system glass react to the pointer.
/// - subtle: a quiet container (a card), rather than a control: fainter fill
///   and no drop shadow.
struct NotchGlassSurface<S: InsettableShape>: View {
    let shape: S
    var tint: Color?
    var lit = false
    var interactive = false
    var subtle = false

    @ObservedObject private var store = DecorStore.shared

    var body: some View {
        switch NotchGlassMaterial.resolve(setting: store.systemGlass) {
        case .system:
            if #available(macOS 26.0, *) {
                SystemGlassFill(shape: shape, tint: tint, lit: lit, interactive: interactive, subtle: subtle)
            } else {
                DrawnGlassFill(shape: shape, tint: tint, lit: lit, subtle: subtle)
            }
        case .drawn:
            DrawnGlassFill(shape: shape, tint: tint, lit: lit, subtle: subtle)
        }
    }
}

@available(macOS 26.0, *)
private struct SystemGlassFill<S: InsettableShape>: View {
    let shape: S
    let tint: Color?
    let lit: Bool
    let interactive: Bool
    let subtle: Bool

    var body: some View {
        // `Color.clear` keeps the glass out of layout: it fills whatever the
        // content's frame is and nothing more.
        //
        // The open notch is pure black, and Liquid Glass only refracts what is
        // behind it, so untinted glass there is black on black and vanishes.
        // A drawn body underneath (which shows even if the panel renders the
        // glass flat), a white tint, and the rim and sheen on top give it an
        // edge; the system glass adds the refraction and pointer response.
        let k = subtle ? 0.5 : 1.0
        Color.clear
            .background(DrawnGlassFill(shape: shape, tint: tint, lit: lit, subtle: subtle))
            .glassEffect(glass, in: shape)
            .overlay(
                shape
                    .inset(by: 1)
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity((lit ? 0.20 : 0.11) * k), .clear],
                            startPoint: .top, endPoint: .center
                        )
                    )
                    .allowsHitTesting(false)
            )
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity((lit ? 0.48 : 0.30) * k), .white.opacity(0.06 * k)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 0.8
                )
                .allowsHitTesting(false)
            )
    }

    private var glass: Glass {
        let colour: Color
        if let tint {
            colour = tint.opacity(subtle ? 0.22 : 0.42)
        } else if lit {
            colour = .white.opacity(subtle ? 0.12 : 0.22)
        } else {
            colour = .white.opacity(subtle ? 0.06 : 0.13)
        }
        return Glass.regular.tint(colour).interactive(interactive)
    }
}

/// Drawn glass: a lit top edge, a soft sheen and a hairline rim, brighter
/// under the pointer and tinted while the thing is on.
private struct DrawnGlassFill<S: InsettableShape>: View {
    let shape: S
    let tint: Color?
    let lit: Bool
    let subtle: Bool

    var body: some View {
        let base = tint ?? .white
        // A card is a quieter version of a control, not a different drawing.
        let k = subtle ? 0.42 : 1.0
        let shadowOpacity = subtle ? 0 : (tint == nil ? 0.35 : 0.45)
        shape
            .fill(
                LinearGradient(
                    colors: [
                        base.opacity((tint == nil ? (lit ? 0.20 : 0.12) : 0.34) * k),
                        base.opacity((tint == nil ? (lit ? 0.09 : 0.045) : 0.16) * k),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .overlay(
                // The sheen: light gathered along the top, as on a glass bead.
                shape
                    .inset(by: 1)
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity((lit ? 0.22 : 0.12) * k), .clear],
                            startPoint: .top, endPoint: .center
                        )
                    )
            )
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity((lit ? 0.42 : 0.26) * k), .white.opacity(0.03)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 0.7
                )
            )
            .shadow(
                color: (tint ?? .black).opacity(shadowOpacity),
                radius: lit ? 6 : 3, y: lit ? 2 : 1
            )
    }
}

// MARK: - Modifiers

extension View {
    /// Glass behind this view, in `shape`. See `NotchGlassSurface`.
    func notchGlass<S: InsettableShape>(
        in shape: S,
        tint: Color? = nil,
        lit: Bool = false,
        interactive: Bool = false,
        subtle: Bool = false
    ) -> some View {
        background {
            NotchGlassSurface(shape: shape, tint: tint, lit: lit, interactive: interactive, subtle: subtle)
        }
    }

    /// The small lift under the pointer. Driven by `hovering`, so the caller
    /// decides what animates it (usually `NotchGlassMotion.hover`).
    func notchHoverLift(_ hovering: Bool, scale: CGFloat = 1.04) -> some View {
        scaleEffect(hovering ? scale : 1)
    }

    /// A control: glass that appears (or brightens) under the pointer, lifts a
    /// little, and tints while `active`. `resting` keeps the glass drawn when
    /// nothing is hovered, for chips that should always look like buttons.
    /// `bleed` lets the glass reach that far beyond tight content (a line of
    /// text, an icon) without changing the layout around it.
    func notchControl<S: InsettableShape>(
        in shape: S,
        tint: Color? = nil,
        active: Bool = false,
        resting: Bool = false,
        lift: CGFloat = 1.04,
        bleed: CGFloat = 0
    ) -> some View {
        padding(bleed)
            .modifier(NotchControlModifier(shape: shape, tint: tint, active: active, resting: resting, lift: lift))
            .padding(-bleed)
    }

    /// A quiet card behind a container.
    func notchCard<S: InsettableShape>(in shape: S, tint: Color? = nil) -> some View {
        notchGlass(in: shape, tint: tint, subtle: true)
    }

    /// The selection marker for a row of tabs or days. One marker is shared
    /// between the items, so selecting another slides it across instead of
    /// fading one out and another in.
    func notchSelection<S: InsettableShape>(
        _ selected: Bool,
        id: String,
        in namespace: Namespace.ID,
        shape: S,
        tint: Color? = nil
    ) -> some View {
        background {
            if selected {
                NotchGlassSurface(shape: shape, tint: tint, lit: true)
                    .matchedGeometryEffect(id: id, in: namespace)
            }
        }
    }
}

private struct NotchControlModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color?
    let active: Bool
    let resting: Bool
    let lift: CGFloat

    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            // Before the lift: hover is judged on the resting frame, so the
            // growing control cannot push the pointer out of itself at the edge.
            .onHover { hovering = $0 }
            .background {
                if resting || hovering || active {
                    NotchGlassSurface(shape: shape, tint: active ? tint : nil, lit: hovering || active)
                        .transition(.opacity.combined(with: .scale(scale: 0.88)))
                }
            }
            .notchHoverLift(hovering, scale: lift)
            .animation(NotchGlassMotion.hover, value: hovering)
            .animation(NotchGlassMotion.hover, value: active)
    }
}

// MARK: - Grouping

/// Neighbouring glass shapes inside one container blend and morph into each
/// other (a selection moving along a row, a chip springing out of its
/// neighbour) instead of overlapping. A plain pass-through where only drawn
/// glass is available.
struct NotchGlassGroup<Content: View>: View {
    var spacing: CGFloat = 2
    @ViewBuilder let content: Content

    @ObservedObject private var store = DecorStore.shared

    var body: some View {
        if #available(macOS 26.0, *), NotchGlassMaterial.resolve(setting: store.systemGlass) == .system {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// MARK: - Press

/// A small, quick press: the control sinks and dims, then springs back.
struct NotchPressStyle: ButtonStyle {
    var scale: CGFloat = 0.92

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(NotchGlassMotion.press, value: configuration.isPressed)
    }
}
