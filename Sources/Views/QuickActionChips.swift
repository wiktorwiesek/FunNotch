//
//  QuickActionChips.swift
//  FunNotch
//
//  The "Szybkie akcje" tile as a row of glass chips with a caption line.
//  Seven icons in a tile about 200 points wide leave no room for words, and
//  widening the chip under the pointer pushed its name over the neighbours,
//  so the name goes in a line under the row instead. Chips with more options
//  (durations, output devices) carry a dot, and the caption offers "Opcje"
//  for them, instead of hiding them behind a right click nobody finds.
//

import AppKit
import SwiftUI

struct QuickActionItem: Identifiable {
    let id: String
    var symbol: String
    var label: String
    /// Set while the thing the chip controls is on (focus running, mic muted).
    var activeTint: Color?
    var help: String
    var menu: [PointerMenu.Item] = []
    var perform: () -> Void

    var isActive: Bool { activeTint != nil }
}

struct QuickActionStrip: View {
    let items: [QuickActionItem]

    @State private var hovered: String?

    /// `previewHover` starts with that chip under the pointer, for the
    /// snapshot renderer.
    init(items: [QuickActionItem], previewHover: String? = nil) {
        self.items = items
        _hovered = State(initialValue: previewHover)
    }

    private static let spacing: CGFloat = 4
    private static let captionHeight: CGFloat = 13

    private var hoveredItem: QuickActionItem? { items.first { $0.id == hovered } }

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: Self.spacing) {
                ForEach(items) { item in
                    QuickActionChip(item: item, lit: hovered == item.id)
                        // Entering a chip names it; leaving it does not clear
                        // the name, so the pointer can go down to "Opcje".
                        .onHover { inside in
                            if inside { hovered = item.id }
                        }
                }
            }
            .frame(maxHeight: .infinity)
            caption
                .frame(height: Self.captionHeight)
        }
        // Only leaving the whole tile puts the hint back.
        .onHover { inside in
            if !inside { hovered = nil }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: hovered)
    }

    @ViewBuilder
    private var caption: some View {
        HStack(spacing: 6) {
            if let item = hoveredItem {
                Text(item.label)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(item.activeTint ?? .white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .id(item.label)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 4)),
                        removal: .opacity
                    ))
                if !item.menu.isEmpty {
                    Button {
                        PointerMenu.show(item.menu)
                    } label: {
                        HStack(spacing: 2) {
                            Text("Opcje")
                            Image(systemName: "chevron.down")
                                .font(.system(size: 7, weight: .bold))
                        }
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 6)
                        .frame(maxHeight: .infinity)
                        .background(Capsule().fill(.white.opacity(0.12)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(ChipPressStyle())
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            } else {
                Text("Szybkie akcje")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct QuickActionChip: View {
    let item: QuickActionItem
    let lit: Bool

    var body: some View {
        Button(action: item.perform) {
            Image(systemName: item.symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(item.activeTint ?? .white.opacity(lit ? 1 : 0.85))
                .symbolEffect(.bounce, value: item.isActive)
                .contentTransition(.symbolEffect(.replace))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(ChipPressStyle())
        .background { ChipBackground(tint: item.activeTint, lit: lit) }
        // A chip with options carries a small mark, so they are not a secret.
        .overlay(alignment: .bottomTrailing) {
            if !item.menu.isEmpty {
                Circle()
                    .fill(.white.opacity(lit ? 0.7 : 0.35))
                    .frame(width: 3, height: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .scaleEffect(lit ? 1.04 : 1)
        .contextMenu {
            ForEach(Array(item.menu.enumerated()), id: \.offset) { _, entry in
                Button(entry.title) { entry.perform() }
                    .disabled(!entry.isEnabled)
            }
        }
        .help(item.help)
    }
}

/// Drawn glass: a lit top edge, a soft sheen and a hairline rim, brighter
/// under the pointer and tinted while the action is on. System Liquid Glass
/// (`glassEffect`) was tried here, but inside the notch's non-activating
/// panel it renders in its inactive, flat state and draws nothing at all
/// offscreen, so it could neither look right nor be checked.
private struct ChipBackground: View {
    let tint: Color?
    let lit: Bool

    private let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        let base = tint ?? .white
        shape
            .fill(
                LinearGradient(
                    colors: [
                        base.opacity(tint == nil ? (lit ? 0.20 : 0.12) : 0.34),
                        base.opacity(tint == nil ? (lit ? 0.09 : 0.045) : 0.16),
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
                            colors: [.white.opacity(lit ? 0.22 : 0.12), .clear],
                            startPoint: .top, endPoint: .center
                        )
                    )
            )
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(lit ? 0.42 : 0.26), .white.opacity(0.03)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 0.7
                )
            )
            .shadow(color: (tint ?? .black).opacity(tint == nil ? 0.35 : 0.45), radius: lit ? 6 : 3, y: lit ? 2 : 1)
    }
}

/// A small, quick press: the chip sinks and dims, then springs back.
private struct ChipPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
