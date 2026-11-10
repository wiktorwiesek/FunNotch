//
//  NotesView.swift
//  FunNotch
//
//  The scratchpad. One text field per day, no formatting and no files.
//

import AppKit
import SwiftUI

struct NotesView: View {
    @ObservedObject private var notes = NotesManager.shared
    @State private var keyMonitor: Any?
    @State private var prompt = NotePrompts.random()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            ZStack(alignment: .topLeading) {
                // The panel never becomes the active app, so the placeholder is
                // drawn rather than relying on a real prompt.
                if notes.isEmpty {
                    Text(notes.isToday ? prompt : "Brak notatki z tego dnia.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.24))
                        .padding(.top, 2)
                        .padding(.leading, 4)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $notes.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.95))
                    .scrollContentBackground(.hidden)
                    .background(.clear)
                    .tint(.accentColor)
            }
            .padding(.horizontal, 2)
            .notchCard(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
        .onAppear {
            installEditingShortcuts()
            // A different one each time the tab is opened, so the empty state
            // is worth reading twice.
            prompt = NotePrompts.random()
        }
        .onDisappear {
            removeEditingShortcuts()
            notes.saveNow()
        }
    }

    /// The save status is the first thing to go when the tile is narrow; left
    /// to wrap it ran down three lines and pushed the header apart.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            headerRow(showsStatus: true)
            headerRow(showsStatus: false)
        }
    }

    private func headerRow(showsStatus: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "note.text")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))

            // Days are a menu rather than arrows: most of the time you want
            // today or yesterday, and a list gets you to either in one click.
            Menu {
                ForEach(notes.days, id: \.self) { day in
                    Button {
                        notes.openDay(day)
                    } label: {
                        if day == notes.day {
                            Label(notes.displayName(for: day), systemImage: "checkmark")
                        } else {
                            Text(notes.displayName(for: day))
                        }
                    }
                }
            } label: {
                HStack(spacing: 2) {
                    Text(notes.displayName(for: notes.day))
                        .font(.system(size: 11, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .notchControl(in: Capsule(), resting: true)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            if !notes.isToday {
                Button("Dziś") { notes.openToday() }
                    .buttonStyle(NotchPressStyle())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .notchControl(in: Capsule(), tint: .blue, active: true)
            }

            Spacer()

            status(showsText: showsStatus)

            Button {
                notes.revealInFinder()
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(NotchPressStyle())
            .notchControl(in: Circle())
            .help("Pokaż tę notatkę w Finderze")
        }
    }

    @ViewBuilder
    private func status(showsText: Bool) -> some View {
        if let error = notes.saveError {
            // An error is never dropped, only shortened to its icon.
            Group {
                if showsText {
                    Label("Nie udało się zapisać kopii na pulpicie", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .lineLimit(1)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                }
            }
            .foregroundStyle(.orange)
            .help("\(error)\n\nKopia zapasowa została mimo to zapisana w aplikacji.")
        } else if showsText, let at = notes.savedAt {
            Text("Zapisano \(at.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Polish.locale)))")
                .font(.system(size: 9))
                .lineLimit(1)
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    // MARK: - Editing shortcuts
    //
    // FunNotch has no menu bar, and macOS routes ⌘C, ⌘V and friends through the
    // main menu — so in the notch they did nothing at all. This catches them
    // while the notes tab is open and hands them to whatever is editing.

    private func installEditingShortcuts() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.contains(.command) else { return event }

            let selector: Selector?
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": selector = #selector(NSText.copy(_:))
            case "v": selector = #selector(NSText.paste(_:))
            case "x": selector = #selector(NSText.cut(_:))
            case "a": selector = #selector(NSText.selectAll(_:))
            case "z": selector = event.modifierFlags.contains(.shift)
                ? Selector(("redo:"))
                : Selector(("undo:"))
            default:  selector = nil
            }

            guard let selector else { return event }
            // Consume the event only if something in the responder chain took
            // it, so an unhandled shortcut still behaves normally.
            return NSApp.sendAction(selector, to: nil, from: nil) ? nil : event
        }
    }

    private func removeEditingShortcuts() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

/// Placeholder lines for an empty note. An empty box is a small dead end, and
/// this is the one place in the app where nothing useful can be shown instead.
enum NotePrompts {
    static let all = [
        "Zapisz to. Pamięć kłamie, choć w dobrej wierze.",
        "Najbledszy atrament bije najlepszą pamięć. Podobno.",
        "Zapisz, a przekonasz się, że nic nie było aż tak pilne.",
        "Notatka teraz to kłótnia uniknięta później.",
        "Za tydzień nie będziesz tego pamiętać. Zrób sobie przysługę.",
        "Połowa myślenia to zapisanie myśli i przyjrzenie się jej.",
        "Jeśli to ważne, warto poświęcić osiem sekund na zapisanie.",
        "Dobre pomysły przychodzą w złych momentach. Złap je mimo to.",
        "Tu myśli spod prysznica mają szansę przeżyć.",
        "Wszystko, co dziś jest oczywiste, w czwartek będzie zagadką.",
        "Najlepsza notatka to ta, która naprawdę powstała.",
        "Powiedz to najpierw tutaj, a dopiero potem na spotkaniu.",
        "Ten pomysł już kiedyś przyszedł Ci do głowy. Tym razem go zapisz.",
        "Kartka nigdy nie przerywa.",
        "Gdzieś między planem a bałaganem. Może być.",
        "Nikt tego nie ocenia.",
        "Pisz niechlujnie. Popraw później. Albo wcale.",
        "Robocza notatka bije dopracowane zamiary."
    ]

    static func random() -> String {
        all.randomElement() ?? all[0]
    }
}
