//
//  TeleprompterEditor.swift
//  FunNotch
//
//  A small ordinary window for writing or pasting the script. It exists only
//  while it is open: the text, the window and the save task are all released
//  when it closes. Typing is saved a moment after the last keystroke, and
//  immediately on „Gotowe” or on closing, so nothing is lost.
//

import AppKit
import SwiftUI

/// The app has no main menu, so ⌘X/⌘C/⌘V/⌘A/⌘Z would do nothing in the text
/// view; route them to the first responder by hand.
final class TeleprompterEditorWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command || flags == [.command, .shift],
           let key = event.charactersIgnoringModifiers?.lowercased() {
            let action: Selector?
            switch (key, flags.contains(.shift)) {
            case ("x", false): action = #selector(NSText.cut(_:))
            case ("c", false): action = #selector(NSText.copy(_:))
            case ("v", false): action = #selector(NSText.paste(_:))
            case ("a", false): action = #selector(NSText.selectAll(_:))
            case ("z", false): action = Selector(("undo:"))
            case ("z", true): action = Selector(("redo:"))
            default: action = nil
            }
            if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class TeleprompterEditorModel: ObservableObject {
    @Published var text: String {
        didSet {
            guard text != oldValue else { return }
            dirty = true
            scheduleSave()
        }
    }

    /// Set by the controller: closes the window.
    var onDone: () -> Void = {}

    private var dirty = false
    private var saveTask: Task<Void, Never>?

    init(text: String) {
        self.text = text
    }

    /// Debounced: one write after the typing stops, not one per keystroke.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Writes the script now if it changed, and tells an open prompter.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard dirty else { return }
        dirty = false
        TeleprompterStore.shared.writeScript(text)
        TeleprompterController.shared.scriptDidChange()
    }

    /// Adds the clipboard text to the script. Read only on this press, and
    /// appended after a blank line rather than replacing what is written.
    func pasteFromClipboard() {
        guard let clip = NSPasteboard.general.string(forType: .string), !clip.isEmpty else { return }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = clip
        } else {
            text += (text.hasSuffix("\n") ? "\n" : "\n\n") + clip
        }
    }

    func finish() {
        flush()
        onDone()
    }
}

struct TeleprompterEditorView: View {
    @ObservedObject var model: TeleprompterEditorModel
    @ObservedObject private var store = TeleprompterStore.shared

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $model.text)
                .font(.system(size: 15))
                .padding(8)

            Divider()

            HStack(spacing: 10) {
                Text(statistics)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Wklej ze schowka") { model.pasteFromClipboard() }
                Button("Gotowe") { model.finish() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
    }

    private var statistics: String {
        let count = model.text.split(whereSeparator: { $0.isWhitespace }).count
        guard count > 0 else { return "0 słów" }
        let seconds = Int((Double(count) / store.wordsPerMinute * 60).rounded())
        let reading = seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min \(String(format: "%02d", seconds % 60)) s"
        return "\(count) \(Self.plural(count)) · czytanie ok. \(reading) przy \(Int(store.wordsPerMinute)) słów/min"
    }

    private static func plural(_ count: Int) -> String {
        if count == 1 { return "słowo" }
        let lastTwo = count % 100
        let last = count % 10
        if (2 ... 4).contains(last), !(12 ... 14).contains(lastTwo) { return "słowa" }
        return "słów"
    }
}

@MainActor
final class TeleprompterEditorController: NSObject, NSWindowDelegate {
    static let shared = TeleprompterEditorController()

    private var window: TeleprompterEditorWindow?
    private var model: TeleprompterEditorModel?

    private override init() { super.init() }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let model = TeleprompterEditorModel(text: TeleprompterStore.shared.readScript())
        model.onDone = { [weak self] in self?.window?.close() }

        let window = TeleprompterEditorWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Teleprompter — tekst"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 380, height: 260)
        window.delegate = self
        let hosting = NSHostingView(rootView: TeleprompterEditorView(model: model))
        hosting.sizingOptions = []
        window.contentView = hosting
        window.center()

        self.model = model
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Saves what is typed and lets everything go.
    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            model?.flush()
            window?.contentView = nil
            window = nil
            model = nil
        }
    }
}
