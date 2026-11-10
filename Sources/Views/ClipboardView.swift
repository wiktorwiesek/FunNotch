//
//  ClipboardView.swift
//  FunNotch
//
//  Recent clipboard entries. Click one to put it back on the pasteboard.
//

import AppKit
import SwiftUI

struct ClipboardView: View {
    @ObservedObject private var clipboard = ClipboardManager.shared
    /// Observed so the search results grow as image text is recognised.
    @ObservedObject private var ocr = ClipboardOCRIndex.shared
    @EnvironmentObject private var settings: Settings

    @State private var justCopied: UUID?
    @State private var query = ""

    var body: some View {
        VStack(spacing: 6) {
            if !settings.clipboardHistoryEnabled {
                disabledState
            } else if clipboard.entries.isEmpty {
                emptyState
            } else {
                toolbar
                entryList
            }
        }
        .padding(.top, 8)
    }

    private var disabledState: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.white.opacity(0.4))
            Text("Historia schowka jest wyłączona")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
            Text("Włącz ją w Ustawieniach → Półka i schowek")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.35))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            CatOrSymbol(systemName: "doc.on.clipboard", symbolSize: 24, symbolWeight: .light, symbolColor: .white.opacity(0.4), catSize: 42)
            Text("Nic jeszcze nie skopiowano")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
            Text("Tutaj pojawi się to, co skopiujesz")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.35))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var visibleEntries: [ClipboardEntry] {
        clipboard.filtered(by: query)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.4))
                TextField("Szukaj", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.white)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .buttonStyle(NotchPressStyle())
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .notchGlass(in: Capsule(), subtle: true)
            .frame(width: 150)

            Text(Polish.count(visibleEntries.count, "element", "elementy", "elementów"))
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
            Button("Wyczyść") { clipboard.clear() }
                .buttonStyle(NotchPressStyle())
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .contentShape(Capsule())
                .notchControl(in: Capsule(), resting: true)
        }
        .padding(.horizontal, 2)
    }

    private var entryList: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHGrid(rows: [GridItem(.flexible())], spacing: 8) {
                ForEach(visibleEntries) { entry in
                    ClipboardTile(entry: entry, justCopied: justCopied == entry.id) {
                        clipboard.copyBack(entry)
                        withAnimation(.easeOut(duration: 0.15)) { justCopied = entry.id }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            if justCopied == entry.id {
                                withAnimation(.easeOut(duration: 0.2)) { justCopied = nil }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 4)
        }
        .frame(maxHeight: .infinity)
    }
}

private struct ClipboardTile: View {
    let entry: ClipboardEntry
    let justCopied: Bool
    let action: () -> Void

    @ObservedObject private var clipboard = ClipboardManager.shared
    @ObservedObject private var ocr = ClipboardOCRIndex.shared
    @ObservedObject private var linkTitles = LinkTitleStore.shared
    @EnvironmentObject private var settings: Settings
    @State private var isHovering = false
    /// Confirms a smart action that copied something (the tile click has its own).
    @State private var flashed = false

    private var smartKind: ClipboardSmartKind {
        if case let .text(value) = entry.payload { return ClipboardSmart.kind(for: value) }
        return .plain
    }

    private var smartActions: [ClipboardSmartAction] {
        var title: String?
        if case let .url(url) = smartKind { title = linkTitles.title(for: url) }
        return ClipboardSmart.actions(for: smartKind, linkTitle: title)
    }

    private func run(_ smart: ClipboardSmartAction) {
        smart.perform()
        if smart.copies { flash() }
    }

    private func flash() {
        withAnimation(.easeOut(duration: 0.15)) { flashed = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeOut(duration: 0.2)) { flashed = false }
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: justCopied || flashed ? "checkmark" : (entry.isPinned ? "pin.fill" : entry.symbol))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(
                            justCopied || flashed || entry.isPinned
                                ? settings.accentColor
                                : .white.opacity(0.5)
                        )
                    if let source = entry.sourceApp {
                        Text(source)
                            .font(.system(size: 8))
                            .foregroundStyle(.white.opacity(0.35))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }

                content
            }
            .padding(7)
            .frame(width: 132, height: 96, alignment: .topLeading)
            .notchGlass(
                in: RoundedRectangle(cornerRadius: 10, style: .continuous),
                tint: justCopied || flashed ? settings.accentColor : nil,
                lit: isHovering || justCopied || flashed,
                subtle: !isHovering && !justCopied && !flashed
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        entry.isPinned ? settings.accentColor.opacity(0.55) : .clear,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(NotchPressStyle(scale: 0.97))
        .overlay(alignment: .bottom) {
            // Outside the tile's own button, so these are real buttons of
            // their own rather than part of "copy this entry".
            if isHovering, !smartActions.isEmpty {
                HStack(spacing: 4) {
                    ForEach(smartActions.prefix(3)) { action in
                        Button { run(action) } label: {
                            Image(systemName: action.symbol)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 18)
                                .notchGlass(in: Capsule(), lit: true)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(NotchPressStyle())
                        .help(action.title)
                    }
                }
                .padding(.bottom, 5)
                .transition(.opacity)
            }
        }
        .notchHoverLift(isHovering, scale: 1.03)
        .onHover { hovering in
            withAnimation(NotchGlassMotion.hover) { isHovering = hovering }
        }
        .contextMenu {
            ForEach(smartActions) { action in
                Button(action.title) { run(action) }
            }
            if !smartActions.isEmpty { Divider() }
            Button("Kopiuj") { clipboard.copyBack(entry) }
            if let recognised = ocr.text(for: entry.id) {
                Button("Kopiuj rozpoznany tekst") {
                    clipboard.copyText(recognised)
                    flash()
                }
            }
            Button(entry.isPinned ? "Odepnij" : "Przypnij") { clipboard.togglePin(entry) }
            Button("Wyślij na półkę") { clipboard.sendToShelf(entry) }
            Divider()
            Button("Usuń") { clipboard.remove(entry) }
        }
        .help(justCopied ? "Skopiowano" : entry.preview)
    }

    @ViewBuilder
    private var content: some View {
        switch entry.payload {
        case let .image(image):
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(height: 58)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(alignment: .bottomTrailing) {
                    if ocr.text(for: entry.id) != nil {
                        Image(systemName: "text.viewfinder")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                            .padding(3)
                            .help("W obrazie rozpoznano tekst")
                    }
                }
        case .text:
            ClipboardSmartContent(kind: smartKind, text: entry.preview)
        default:
            Text(entry.preview)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(4)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
