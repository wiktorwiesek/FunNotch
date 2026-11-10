//
//  QuickActionChips.swift
//  FunNotch
//
//  The quick actions tile as a row of glass chips. Seven icons in a tile
//  about 200 points wide leave no room for words, and widening the chip under
//  the pointer pushed its name over the neighbours, so the name goes in a
//  line under the row instead, and only while the pointer is on a chip: at
//  rest the row sits in the middle of the tile with nothing under it (a
//  caption naming the tile said what the icons already show). Chips with
//  more options
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
        VStack(spacing: 2) {
            // One glass group: neighbouring chips blend as the pointer moves.
            NotchGlassGroup {
                HStack(spacing: Self.spacing) {
                    ForEach(items) { item in
                        QuickActionChip(item: item, lit: hovered == item.id)
                            // Entering a chip names it; leaving it does not clear
                            // the name, so the pointer can go down to "Opcje".
                            .onHover { inside in
                                if inside { setHovered(item.id) }
                            }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            // At rest the row takes the middle of the tile; the pointer
            // slides it up to make room for the name.
            .offset(y: hovered == nil ? (Self.captionHeight + 2) / 2 : 0)
            caption
                .frame(height: Self.captionHeight)
        }
        // Only leaving the whole tile puts the hint back.
        .onHover { inside in
            if !inside { setHovered(nil) }
        }
    }

    /// Hover is the only thing that animates here, and it does so through one
    /// explicit transaction rather than an implicit animation on the tile.
    private func setHovered(_ id: String?) {
        withAnimation(NotchGlassMotion.hover) { hovered = id }
    }

    @ViewBuilder
    private var caption: some View {
        HStack(spacing: 6) {
            if let item = hoveredItem {
                Text(item.label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
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
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 6)
                        .frame(maxHeight: .infinity)
                        .notchGlass(in: Capsule(), lit: true, subtle: true)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(NotchPressStyle())
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
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
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(item.activeTint ?? .white.opacity(lit ? 1 : 0.85))
                .contentTransition(.symbolEffect(.replace))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(NotchPressStyle())
        .notchGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous), lit: lit || item.isActive)
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
        .notchHoverLift(lit)
        .contextMenu {
            ForEach(Array(item.menu.enumerated()), id: \.offset) { _, entry in
                Button(entry.title) { entry.perform() }
                    .disabled(!entry.isEnabled)
            }
        }
        .help(item.help)
    }
}
