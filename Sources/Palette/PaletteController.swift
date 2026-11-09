//
//  PaletteController.swift
//  FunNotch
//
//  Owns the palette's floating panel: shows it centred under the notch of the
//  screen the pointer is on, takes keyboard focus, and hands focus back to the
//  app the user came from when it closes.
//

import AppKit
import Combine
import SwiftUI

/// Borderless panels refuse key status by default, and without it the search
/// field could not be typed into.
final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// ⌘1–⌘9 open notch tabs from anywhere in the panel.
    var onCommandDigit: ((Int) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, let key = event.charactersIgnoringModifiers,
           key.count == 1, let digit = Int(key), (1 ... 9).contains(digit) {
            onCommandDigit?(digit)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class PaletteController: NSObject, NSWindowDelegate {
    static let shared = PaletteController()

    let model = PaletteModel()

    private var panel: PalettePanel?
    private var previousApp: NSRunningApplication?
    /// Screen y of the panel's top edge; the panel grows and shrinks downward.
    private var topEdge: CGFloat = 0
    private var cancellables = Set<AnyCancellable>()

    var isVisible: Bool { panel?.isVisible ?? false }

    private override init() {
        super.init()
        model.onActivate = { [weak self] item in self?.activate(item) }
        model.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] items in self?.resize(forItems: items.count) }
            .store(in: &cancellables)
    }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show(query: String = "") {
        let panel = ensurePanel()
        if !isVisible {
            let front = NSWorkspace.shared.frontmostApplication
            previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
            model.reset(query: query)
            place(panel)
        } else if !query.isEmpty {
            model.query = query
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        focusField()
    }

    /// Closes the panel. `restoreFocus` gives the previous app its focus back;
    /// it is off when the user clicked into another app themselves.
    func hide(restoreFocus: Bool = true) {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        model.suspend()
        if restoreFocus { previousApp?.activate() }
        previousApp = nil
    }

    private func activate(_ item: PaletteItem) {
        if item.keepsOpen { return }
        hide(restoreFocus: item.restoresFocus)
        item.run()
    }

    // MARK: Window

    private func ensurePanel() -> PalettePanel {
        if let panel { return panel }
        let panel = PalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: PaletteMetrics.width, height: PaletteMetrics.height(forItems: 0)),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.delegate = self
        panel.onCommandDigit = { [weak self] digit in self?.model.jumpToTab(number: digit) }

        let hosting = NSHostingView(rootView: PaletteView(model: model))
        // The panel decides its own size; the hosting view must not push back.
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    /// Centres the panel under the notch (or the menu bar on screens without
    /// one) of the screen the pointer is on.
    private func place(_ panel: PalettePanel) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        let inset = max(screen.safeAreaInsets.top, menuBar)
        topEdge = screen.frame.maxY - inset - 14
        let height = PaletteMetrics.height(forItems: model.items.count)
        panel.setFrame(
            NSRect(x: screen.frame.midX - PaletteMetrics.width / 2, y: topEdge - height,
                   width: PaletteMetrics.width, height: height),
            display: true
        )
    }

    private func resize(forItems count: Int) {
        guard let panel, panel.isVisible else { return }
        let height = PaletteMetrics.height(forItems: count)
        var frame = panel.frame
        guard abs(frame.height - height) > 0.5 else { return }
        frame.size.height = height
        frame.origin.y = topEdge - height
        panel.setFrame(frame, display: true)
    }

    private func focusField() {
        guard let panel, let field = model.searchField else { return }
        panel.makeFirstResponder(field)
        // Leave the cursor at the end of any text the palette opened with.
        field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.count, length: 0)
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated {
            // The translation download prompt is a sheet on this panel; the
            // panel loses key status to it but is not being dismissed.
            guard let panel, panel.isVisible, panel.attachedSheet == nil else { return }
            hide(restoreFocus: false)
        }
    }
}
