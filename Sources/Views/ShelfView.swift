//
//  ShelfView.swift
//  FunNotch
//
//  The file tray. Drop things here from anywhere, then drag them straight back
//  out into another app, AirDrop them, or preview them.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ShelfView: View {
    @ObservedObject private var shelf = ShelfManager.shared
    @EnvironmentObject private var viewModel: NotchViewModel
    @EnvironmentObject private var settings: Settings

    var body: some View {
        VStack(spacing: 6) {
            if shelf.items.isEmpty {
                emptyState
            } else {
                toolbar
                ShelfConversionStrip()
                itemGrid
                folderTargets
            }
        }
        .padding(.top, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            CatOrSymbol(
                systemName: "tray.and.arrow.down", symbolSize: 26, symbolWeight: .light,
                symbolColor: .white.opacity(viewModel.isDropTargeted ? 0.9 : 0.4),
                catSize: 46, catState: viewModel.isDropTargeted ? .awake : .sleeping
            )
            .scaleEffect(viewModel.isDropTargeted ? 1.12 : 1)

            Text(viewModel.isDropTargeted ? "Upuść, aby dodać" : "Upuść pliki tutaj")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))

            Text("Zostają na Półce, dopóki ich stąd nie wyciągniesz")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                )
                .foregroundStyle(.white.opacity(viewModel.isDropTargeted ? 0.5 : 0.16))
        )
        .animation(.easeOut(duration: 0.2), value: viewModel.isDropTargeted)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text(Polish.count(shelf.items.count, "element", "elementy", "elementów"))
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))

            if !shelf.missingOnRestore.isEmpty {
                Label("Brakuje: \(shelf.missingOnRestore.count)", systemImage: "questionmark.folder")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange.opacity(0.85))
                    .help("Te pliki były na Półce, ale zostały przeniesione lub usunięte:\n" +
                          shelf.missingOnRestore.joined(separator: "\n"))
            }

            Spacer()

            NotchGlassGroup {
                HStack(spacing: 8) {
                    if shelf.selection.count > 1 {
                        ShelfToolbarButton(systemName: "doc.zipper", label: "Spakuj") {
                            ShelfConverter.shared.run(.zip, on: shelf.items.filter { shelf.selection.contains($0.id) })
                        }
                    }
                    ShelfToolbarButton(systemName: "square.and.arrow.up", label: "Udostępnij") {
                        ShareAnchor.share(urls: shelf.shareURLs)
                    }
                    ShelfToolbarButton(systemName: "dot.radiowaves.right", label: "AirDrop") {
                        shelf.airDrop(shelf.shareURLs)
                    }
                    ShelfToolbarButton(systemName: "doc.on.doc", label: "Kopiuj") {
                        shelf.copyToPasteboard(shelf.shareURLs)
                    }
                    ShelfToolbarButton(systemName: "trash", label: "Wyczyść") {
                        if shelf.selection.isEmpty {
                            shelf.clear()
                        } else {
                            shelf.removeSelected()
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private var folderTargets: some View {
        let targets = settings.shelfFolderTargets
        if !targets.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.4))
                ForEach(targets, id: \.self) { path in
                    FolderTargetChip(path: path)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
        }
    }

    @ViewBuilder
    private var itemGrid: some View {
        if Motion.filmTime != nil {
            // Offscreen, a scroll view draws blank; lay the row out flat.
            HStack(spacing: 8) {
                ForEach(shelf.items) { item in
                    ShelfItemTile(item: item)
                }
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: [GridItem(.flexible())], spacing: 8) {
                    ForEach(shelf.items) { item in
                        ShelfItemTile(item: item)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 4)
            }
            .frame(maxHeight: .infinity)
        }
    }
}

private struct ShelfToolbarButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemName)
                    .font(.system(size: 10, weight: .medium))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.95))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Capsule())
        }
        .buttonStyle(NotchPressStyle())
        .notchControl(in: Capsule(), resting: true)
    }
}

private struct ShelfItemTile: View {
    let item: ShelfItem

    @ObservedObject private var shelf = ShelfManager.shared
    @EnvironmentObject private var viewModel: NotchViewModel
    @EnvironmentObject private var settings: Settings
    @State private var isHovering = false

    private var isSelected: Bool { shelf.selection.contains(item.id) }

    /// A sheet inside a borderless panel is awkward, so renaming uses a plain
    /// alert with a text field.
    private func promptRename() {
        let alert = NSAlert()
        alert.messageText = "Zmień nazwę elementu"
        alert.informativeText = "Zmiana dotyczy samego pliku, więc nowa nazwa zostanie z nim po wyciągnięciu z półki."
        alert.addButton(withTitle: "Zmień nazwę")
        alert.addButton(withTitle: "Anuluj")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = (item.name as NSString).deletingPathExtension
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        shelf.rename(id: item.id, to: field.stringValue)
    }

    /// Convert, remove background, zip and unzip. With several items selected
    /// these apply to all of them that support the action.
    @ViewBuilder
    private var conversionMenu: some View {
        let converter = ShelfConverter.shared
        let targets = converter.targets(for: item)
        let options = converter.options(for: item)
        Divider()
        if !options.isEmpty {
            Menu(targets.count > 1 ? "Konwertuj zaznaczone" : "Konwertuj") {
                ForEach(options, id: \.self) { option in
                    Button(option.menuTitle) { converter.run(option, on: targets) }
                }
            }
        }
        Button(targets.count > 1 ? "Spakuj zaznaczone do ZIP" : "Spakuj do ZIP") {
            converter.run(.zip, on: targets)
        }
        if converter.canUnzip(item) {
            Button("Rozpakuj") { converter.run(.unzip, on: targets) }
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if let thumbnail = item.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(4)
                } else {
                    Image(systemName: "doc")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: 62, height: 62)
            .notchGlass(
                in: RoundedRectangle(cornerRadius: 12, style: .continuous),
                tint: isSelected ? settings.accentColor : nil,
                lit: isHovering || isSelected,
                subtle: !isHovering && !isSelected
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? settings.accentColor : .clear, lineWidth: 1.5)
            )
            .overlay(alignment: .topTrailing) {
                if isHovering {
                    Button {
                        shelf.remove(id: item.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 17, height: 17)
                            .notchGlass(in: Circle(), lit: true)
                            .contentShape(Circle())
                    }
                    .buttonStyle(NotchPressStyle())
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
                    .offset(x: 5, y: -5)
                }
            }

            Text(item.name)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 66)
        }
        .contentShape(Rectangle())
        .notchHoverLift(isHovering)
        .onHover { hovering in
            withAnimation(NotchGlassMotion.hover) { isHovering = hovering }
            // Keep the notch open while the pointer is over an item being dragged.
            viewModel.pinnedOpen = hovering
        }
        .onTapGesture(count: 2) { shelf.open(item) }
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) {
                if isSelected { shelf.selection.remove(item.id) } else { shelf.selection.insert(item.id) }
            } else {
                shelf.selection = isSelected ? [] : [item.id]
            }
        }
        .onDrag {
            viewModel.pinnedOpen = true
            defer {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    viewModel.pinnedOpen = false
                    shelf.handleDragCompleted(id: item.id)
                }
            }
            return NSItemProvider(contentsOf: item.url) ?? NSItemProvider()
        } preview: {
            if let thumbnail = item.thumbnail {
                Image(nsImage: thumbnail).resizable().frame(width: 64, height: 64)
            } else {
                Image(systemName: "doc").font(.system(size: 32))
            }
        }
        .contextMenu {
            Button("Otwórz") { shelf.open(item) }
            Button("Zmień nazwę…") { promptRename() }
            Button("Szybki podgląd") { shelf.quickLook(item) }
            Button("Pokaż w Finderze") { shelf.reveal(item) }
            Divider()
            Button("Udostępnij…") { ShareAnchor.share(urls: [item.url]) }
            Button("AirDrop") { shelf.airDrop([item.url]) }
            Button("Kopiuj") { shelf.copyToPasteboard([item.url]) }
            Button("Kopiuj ścieżkę") { shelf.copyPath(item) }
            Button("Kopiuj nazwę pliku") { shelf.copyFilename(item) }
            if shelf.canRecogniseText(item) {
                Button("Kopiuj tekst z obrazu") {
                    shelf.copyTextFromImage(item) { _ in }
                }
            }
            conversionMenu
            Divider()
            Button("Usuń z półki") { shelf.remove(id: item.id) }
        }
        .help("\(item.name)\n\(formattedFileSize(item.size)), \(item.typeDescription)")
    }
}

/// The share picker needs a real NSView to anchor to; the notch panel's content
/// view is the natural choice.
@MainActor
enum ShareAnchor {
    static func share(urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard let view = NotchWindowManager.shared.controllers.first?.panel.contentView else {
            ShelfManager.shared.airDrop(urls)
            return
        }
        let picker = NSSharingServicePicker(items: urls)
        picker.show(relativeTo: CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1),
                    of: view,
                    preferredEdge: .minY)
    }
}


/// One-click destination for whatever is selected on the shelf.
private struct FolderTargetChip: View {
    let path: String

    @ObservedObject private var shelf = ShelfManager.shared
    @EnvironmentObject private var settings: Settings

    var body: some View {
        Button(action: send) {
            Text((path as NSString).lastPathComponent)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Capsule())
        }
        .buttonStyle(NotchPressStyle())
        .notchControl(in: Capsule(), resting: true)
        .help("Wyślij zaznaczone do \(path)")
    }

    private func send() {
        let folder = URL(fileURLWithPath: path)
        // With nothing selected, filing everything is the useful reading.
        let ids = shelf.selection.isEmpty
            ? shelf.items.map(\.id)
            : Array(shelf.selection)
        for id in ids {
            shelf.send(id: id, toFolder: folder, keepingOriginal: !settings.autoRemoveShelfItems)
        }
    }
}
