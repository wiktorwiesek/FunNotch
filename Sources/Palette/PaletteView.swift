//
//  PaletteView.swift
//  FunNotch
//
//  What the command palette looks like: a search field over a list of
//  results. Keys are handled by the field (see PaletteSearchField), so the
//  view only draws and reacts to clicks.
//

import AppKit
import SwiftUI

enum PaletteMetrics {
    static let width: CGFloat = 680
    static let headerHeight: CGFloat = 58
    static let rowHeight: CGFloat = 46
    static let footerHeight: CGFloat = 30
    static let visibleRows = 8

    static func height(forItems count: Int) -> CGFloat {
        let rows = min(count, visibleRows)
        let list = rows > 0 ? CGFloat(rows) * rowHeight + 10 : 0
        return headerHeight + list + footerHeight + 1
    }
}

struct PaletteView: View {
    @ObservedObject var model: PaletteModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                PaletteSearchField(model: model)
            }
            .padding(.horizontal, 20)
            .frame(height: PaletteMetrics.headerHeight)

            Divider().opacity(0.5)

            if model.items.isEmpty {
                Text("Brak wyników")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                                PaletteRow(item: item, isSelected: index == model.selection)
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        model.selection = index
                                        model.activateSelection()
                                    }
                            }
                        }
                        .padding(5)
                    }
                    .onChange(of: model.selection) {
                        guard model.items.indices.contains(model.selection) else { return }
                        proxy.scrollTo(model.items[model.selection].id)
                    }
                }
            }

            Divider().opacity(0.5)
            HStack(spacing: 14) {
                hint("↑↓", "wybór")
                hint("↩", "uruchom")
                hint("⌘1–9", "karty notcha")
                Spacer()
                hint("esc", "zamknij")
            }
            .padding(.horizontal, 18)
            .frame(height: PaletteMetrics.footerHeight - 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VisualEffectBackground(material: .hudWindow, blending: .behindWindow))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .environment(\.colorScheme, .dark)
        .paletteTranslation(model)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.1)))
            Text(label)
                .font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let trailing = item.trailing {
                Text(trailing)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: PaletteMetrics.rowHeight)
        .background {
            if isSelected {
                NotchGlassSurface(shape: RoundedRectangle(cornerRadius: 10, style: .continuous), lit: true)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch item.icon {
        case let .symbol(name, tint):
            Image(systemName: name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.gradient))
        case let .file(path):
            Image(nsImage: PaletteIconCache.icon(forFile: path))
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        }
    }
}

@MainActor
private enum PaletteIconCache {
    private static var icons: [String: NSImage] = [:]

    static func icon(forFile path: String) -> NSImage {
        if let cached = icons[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 32, height: 32)
        icons[path] = icon
        return icon
    }
}

// MARK: - Search field

/// A plain text field that turns ↑ ↓ Enter and Esc into palette actions. Done
/// in AppKit because a focused SwiftUI TextField swallows the arrow keys.
struct PaletteSearchField: NSViewRepresentable {
    let model: PaletteModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20, weight: .regular)
        field.textColor = .white
        field.placeholderAttributedString = NSAttributedString(
            string: "Szukaj, licz (=), tłumacz (t), szablony (s)…",
            attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.35),
                .font: NSFont.systemFont(ofSize: 20),
            ]
        )
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        field.stringValue = model.query
        model.searchField = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        // Only when it differs: rewriting the text while typing moves the cursor.
        if field.stringValue != model.query {
            field.stringValue = model.query
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let model: PaletteModel

        init(model: PaletteModel) {
            self.model = model
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            model.query = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                model.moveSelection(-1)
            case #selector(NSResponder.moveDown(_:)):
                model.moveSelection(1)
            case #selector(NSResponder.insertNewline(_:)):
                model.activateSelection()
            case #selector(NSResponder.cancelOperation(_:)):
                PaletteController.shared.hide()
            default:
                return false
            }
            return true
        }
    }
}
