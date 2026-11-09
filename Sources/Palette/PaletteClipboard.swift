//
//  PaletteClipboard.swift
//  FunNotch
//
//  Copying and pasting on behalf of the palette: snippets, calculator results,
//  clipboard history entries and colour codes all end up here.
//

import AppKit
import ApplicationServices
import SwiftUI

@MainActor
enum PaletteClipboard {
    /// Puts `text` on the pasteboard through the clipboard manager, so the
    /// history does not record our own write as something the user copied.
    static func copy(_ text: String) {
        let entry = ClipboardEntry(id: UUID(), payload: .text(text), copiedAt: Date(), sourceApp: nil)
        ClipboardManager.shared.copyBack(entry)
    }

    /// Copies `text` and, when Accessibility is granted, types ⌘V into the app
    /// that was in front before the palette opened. Without the permission the
    /// notch says so and the user pastes themselves.
    static func paste(_ text: String) {
        copy(text)
        guard AXIsProcessTrusted() else {
            IslandCenter.shared.post(Island(
                symbol: "doc.on.clipboard.fill",
                tint: SettingsStyle.blue,
                title: "Skopiowano",
                detail: " · wklej ⌘V"
            ))
            return
        }
        // The previous app has just been reactivated; give it a moment to take
        // key focus or the keystroke lands in nothing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let source = CGEventSource(stateID: .combinedSessionState)
            let keyV: CGKeyCode = 9
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: keyDown)
                event?.flags = .maskCommand
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    /// Shows the system Accessibility prompt when the permission is missing.
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
