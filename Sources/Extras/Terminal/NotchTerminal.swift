//
//  NotchTerminal.swift
//  FunNotch
//
//  A terminal that drops from the notch: a panel under the camera running the
//  user's login shell, shown and hidden from the tools menu in the notch.
//
//  The emulator is SwiftTerm (see Tools/fetch-swiftterm.sh). Nothing of it is
//  touched until the terminal is first shown. Hiding the panel keeps the shell
//  and what is on its screen, the way a drop-down terminal should (a shell
//  that is waiting costs no processor time); when the shell exits, the panel
//  and the emulator are released, and the next show starts a fresh one.
//

import AppKit
import SwiftTerm
import SwiftUI

/// Borderless panels refuse key status by default, and a terminal that cannot
/// be typed into is a picture of one.
private final class TerminalPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NotchTerminalController: NSObject, LocalProcessTerminalViewDelegate {
    static let shared = NotchTerminalController()

    static let fontSizeKey = "extras.terminal.fontSize"
    static let defaultFontSize = 12.0

    private static let size = CGSize(width: 760, height: 380)
    private static let cornerRadius: CGFloat = 16
    private static let padding: CGFloat = 10

    private var panel: TerminalPanel?
    private var terminal: LocalProcessTerminalView?
    private var previousApp: NSRunningApplication?

    var isVisible: Bool { panel?.isVisible ?? false }
    /// A shell is running, shown or not.
    var hasSession: Bool { terminal != nil }

    private override init() { super.init() }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        let panel = ensurePanel()
        if terminal == nil { startSession(in: panel) }
        place(panel)
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if let terminal { panel.makeFirstResponder(terminal) }
    }

    /// Takes the panel off the screen; the shell stays.
    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        previousApp?.activate()
        previousApp = nil
    }

    /// Ends the shell and releases the panel and the emulator.
    func endSession() {
        terminal?.terminate()
        tearDown()
    }

    private func tearDown() {
        let wasVisible = isVisible
        terminal?.processDelegate = nil
        terminal?.removeFromSuperview()
        terminal = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        if wasVisible { previousApp?.activate() }
        previousApp = nil
    }

    // MARK: Window

    private func ensurePanel() -> TerminalPanel {
        if let panel { return panel }
        let panel = TerminalPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
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
        panel.animationBehavior = .utilityWindow

        // Notch black, square against the menu bar and rounded below, so it
        // reads as the notch grown downward.
        let backdrop = NSView(frame: NSRect(origin: .zero, size: Self.size))
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor.black.cgColor
        backdrop.layer?.cornerRadius = Self.cornerRadius
        backdrop.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        backdrop.layer?.masksToBounds = true
        panel.contentView = backdrop
        self.panel = panel
        return panel
    }

    /// Top-centre of the display the pointer is on, right under the menu bar.
    private func place(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let top = screen.frame.maxY - max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY)
        let width = min(Self.size.width, screen.frame.width - 40)
        panel.setFrame(
            NSRect(x: screen.frame.midX - width / 2, y: top - Self.size.height, width: width, height: Self.size.height),
            display: true
        )
    }

    // MARK: Session

    private func startSession(in panel: NSPanel) {
        guard let backdrop = panel.contentView else { return }
        let view = LocalProcessTerminalView(frame: backdrop.bounds.insetBy(dx: Self.padding, dy: Self.padding))
        view.autoresizingMask = [.width, .height]
        view.processDelegate = self

        let stored = UserDefaults.standard.double(forKey: Self.fontSizeKey)
        let size = stored >= 9 && stored <= 24 ? stored : Self.defaultFontSize
        view.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = NSColor(white: 0.92, alpha: 1)
        view.caretColor = NSColor(white: 0.92, alpha: 1)
        backdrop.addSubview(view)

        // A login shell, so the PATH and aliases are the ones of every other
        // terminal: argv[0] with a leading dash is how a shell is told so.
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { path in
            FileManager.default.isExecutableFile(atPath: path) ? path : nil
        } ?? "/bin/zsh"
        let name = "-" + (shell as NSString).lastPathComponent
        view.startProcess(
            executable: shell, args: [], environment: nil, execName: name,
            currentDirectory: NSHomeDirectory()
        )
        terminal = view
        DiagnosticLog.write("terminal", "session started")
    }

    // MARK: LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    /// `exit`, or the shell dying: nothing is left to show.
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                DiagnosticLog.write("terminal", "session ended")
                NotchTerminalController.shared.tearDown()
            }
        }
    }
}

/// The terminal's section of the settings.
struct TerminalSettings: View {
    @AppStorage(NotchTerminalController.fontSizeKey) private var fontSize = NotchTerminalController.defaultFontSize

    var body: some View {
        SettingsCard(
            title: "Terminal",
            footer: "Otwierasz go przyciskiem narzędzi w otwartym notchu. Ukrycie nie kończy powłoki; kończy ją polecenie exit albo „Zakończ sesję terminala” w tym samym menu. Dopóki go nie otworzysz, nic nie działa w tle."
        ) {
            SettingsRow(
                title: "Rozmiar czcionki",
                subtitle: "Zmiana obowiązuje od następnej sesji.",
                symbol: "textformat.size",
                tint: SettingsStyle.gray
            ) {
                Stepper(value: $fontSize, in: 9 ... 24, step: 1) {
                    Text("\(Int(fontSize)) pt").monospacedDigit()
                }
            }
            SettingsRow(title: "Terminal", symbol: "terminal", tint: SettingsStyle.green) {
                Button("Pokaż") { NotchTerminalController.shared.show() }
            }
        }
    }
}
