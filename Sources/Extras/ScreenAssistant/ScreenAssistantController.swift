//
//  ScreenAssistantController.swift
//  FunNotch
//
//  The screen assistant's lifetime. `begin()` takes the screenshot; only a
//  successful one creates a session and a floating panel. Closing the panel
//  stops a running client, deletes the image and releases the panel, the
//  hosting view and the thumbnail, so between uses the feature owns nothing.
//
//  The session is the panel's model: the conversation so far, the question
//  being typed and the child process that is answering.
//

import AppKit
import CoreGraphics
import SwiftUI

// MARK: - Session

@MainActor
final class ScreenAssistantSession: ObservableObject {
    struct Turn: Identifiable {
        let id = UUID()
        let question: String
        var answer = ""
        var failure: String?
    }

    @Published private(set) var thumbnail: NSImage?
    @Published var question = ""
    @Published private(set) var turns: [Turn] = []
    @Published private(set) var isRunning = false
    @Published private(set) var copied = false
    /// True when macOS has not granted Screen Recording; the capture may then
    /// show only the desktop picture.
    let showsPermissionHint: Bool

    let imageURL: URL
    let directory: URL
    /// Called once, when the first question is asked, so the panel can grow
    /// to make room for the answer.
    var onFirstQuestion: (() -> Void)?

    private var run: ScreenAssistantRun?
    /// Bumped whenever a running request is abandoned; callbacks from an
    /// older request compare it and drop themselves.
    private var generation = 0

    init(directory: URL, imageURL: URL, thumbnail: NSImage?, showsPermissionHint: Bool) {
        self.directory = directory
        self.imageURL = imageURL
        self.thumbnail = thumbnail
        self.showsPermissionHint = showsPermissionHint
    }

    var canCopy: Bool {
        guard !isRunning, let last = turns.last else { return false }
        return last.failure == nil && !last.answer.isEmpty
    }

    func ask(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }

        let history = turns
            .filter { $0.failure == nil && !$0.answer.isEmpty }
            .map { (question: $0.question, answer: $0.answer) }
        let isFirst = turns.isEmpty
        turns.append(Turn(question: text))
        question = ""
        copied = false
        isRunning = true
        if isFirst { onFirstQuestion?() }

        generation += 1
        let current = generation
        let imagePath = imageURL.path
        let workingDirectory = directory

        Task { [weak self] in
            let resolution = await ScreenAssistantLocator.resolve()
            guard let self, current == self.generation else { return }

            let resolved: ScreenAssistantResolved
            switch resolution {
            case .found(let value):
                resolved = value
            case .customMissing(let program):
                self.fail("Nie znaleziono programu „\(program)” z własnego polecenia.", generation: current)
                return
            case .notFound:
                self.fail("Nie znaleziono klienta AI. Zainstaluj omp lub gemini albo wpisz własne polecenie w ustawieniach asystenta ekranu.", generation: current)
                return
            }

            let prompt = ScreenAssistantCommand.prompt(
                instruction: ScreenAssistantPrefs.instruction,
                history: history,
                question: text
            )
            guard let launch = ScreenAssistantCommand.launch(resolved, imagePath: imagePath, prompt: prompt) else {
                self.fail("Własne polecenie jest puste.", generation: current)
                return
            }

            let run = ScreenAssistantRun(
                onText: { [weak self] chunk in
                    MainActor.assumeIsolated { self?.receive(chunk, generation: current) }
                },
                onFinish: { [weak self] outcome in
                    MainActor.assumeIsolated { self?.finish(outcome, generation: current) }
                }
            )
            if let message = run.start(launch, directories: resolved.directories, workingDirectory: workingDirectory) {
                self.fail(message, generation: current)
                return
            }
            self.run = run
            DiagnosticLog.write("screenassistant", "started")
        }
    }

    func cancel() {
        guard isRunning else { return }
        generation += 1
        run?.cancel()
        run = nil
        isRunning = false
        if !turns.isEmpty { turns[turns.count - 1].failure = "Anulowano." }
        DiagnosticLog.write("screenassistant", "cancelled")
    }

    func copyAnswer() {
        guard canCopy, let answer = turns.last?.answer else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(answer, forType: .string)
        ClipboardManager.shared.markOwnWrite()
        copied = true
    }

    /// Stops the child and drops everything the panel showed.
    func teardown() {
        generation += 1
        run?.cancel()
        run = nil
        isRunning = false
        onFirstQuestion = nil
        thumbnail = nil
        turns = []
        question = ""
    }

    // MARK: Client callbacks

    private func receive(_ chunk: String, generation: Int) {
        guard generation == self.generation, !turns.isEmpty else { return }
        let index = turns.count - 1
        // Models often open with blank lines; they would only push the answer down.
        turns[index].answer += turns[index].answer.isEmpty ? String(chunk.drop(while: \.isNewline)) : chunk
    }

    private func finish(_ outcome: ScreenAssistantOutcome, generation: Int) {
        guard generation == self.generation, !turns.isEmpty else { return }
        let index = turns.count - 1
        run = nil
        isRunning = false
        switch outcome {
        case .success:
            let trimmed = turns[index].answer.trimmingCharacters(in: .whitespacesAndNewlines)
            turns[index].answer = trimmed
            if trimmed.isEmpty { turns[index].failure = "Klient AI nie zwrócił odpowiedzi." }
            DiagnosticLog.write("screenassistant", trimmed.isEmpty ? "finished: empty" : "finished: ok")
        case .failure(let message):
            turns[index].failure = message
            DiagnosticLog.write("screenassistant", "finished: error")
        case .cancelled:
            turns[index].failure = "Anulowano."
            DiagnosticLog.write("screenassistant", "cancelled")
        }
    }

    private func fail(_ message: String, generation: Int) {
        guard generation == self.generation, !turns.isEmpty else { return }
        turns[turns.count - 1].failure = message
        isRunning = false
        DiagnosticLog.write("screenassistant", "finished: error")
    }
}

// MARK: - Panel

/// Borderless panels refuse key status by default, and without it the
/// question field could not be typed into. Esc and ⌘W close it.
private final class ScreenAssistantPanel: NSPanel {
    var onClose: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command || flags == [.command, .shift],
           let key = event.charactersIgnoringModifiers?.lowercased() {
            if key == "w", flags == .command {
                onClose?()
                return true
            }
            // The app has no main menu, so the standard editing shortcuts
            // would do nothing in the field; route them to the first responder.
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

// MARK: - Controller

@MainActor
final class ScreenAssistantController {
    static let shared = ScreenAssistantController()

    private static let width: CGFloat = 460
    private static let collapsedHeight: CGFloat = 300
    private static let expandedHeight: CGFloat = 580

    private var panel: ScreenAssistantPanel?
    private var session: ScreenAssistantSession?
    private var directory: URL?
    private var terminateObserver: NSObjectProtocol?
    private var previousApp: NSRunningApplication?
    private var capturing = false
    /// Screen y of the panel's top edge; the panel grows downward.
    private var topEdge: CGFloat = 0

    private init() {}

    /// Starts the system's crosshair selection and, if a region was chosen,
    /// opens the assistant on it.
    func begin() {
        guard !capturing else { return }
        close(restoreFocus: false)

        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front

        let folder: URL
        do {
            folder = try ScreenAssistantStorage.makePrivateDirectory()
        } catch {
            DiagnosticLog.write("screenassistant", "capture failed: no temporary folder")
            return
        }
        directory = folder
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            try? FileManager.default.removeItem(at: folder)
        }
        Task.detached(priority: .utility) { ScreenAssistantStorage.removeStaleDirectories() }

        capturing = true
        DiagnosticLog.write("screenassistant", "capture started")
        let imageURL = folder.appendingPathComponent("capture.png")
        Task { [weak self] in
            let captured = await ScreenAssistantCapture.capture(to: imageURL)
            var decoded: CGImage?
            if captured { decoded = await ScreenAssistantCapture.thumbnail(at: imageURL) }
            guard let self else { return }
            self.capturing = false
            guard self.directory == folder else { return }
            guard let thumbnail = decoded else {
                DiagnosticLog.write("screenassistant", captured ? "capture failed: unreadable image" : "capture cancelled")
                self.releaseStorage()
                self.previousApp = nil
                return
            }
            self.present(
                directory: folder,
                imageURL: imageURL,
                image: NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
            )
        }
    }

    /// Stops a running client, deletes the image and releases the panel.
    func close(restoreFocus: Bool = true) {
        guard session != nil || panel != nil else { return }
        session?.teardown()
        session = nil
        if let panel {
            panel.onClose = nil
            panel.orderOut(nil)
            panel.contentView = nil
        }
        panel = nil
        releaseStorage()
        if restoreFocus { previousApp?.activate() }
        previousApp = nil
    }

    // MARK: Window

    private func present(directory: URL, imageURL: URL, image: NSImage) {
        let session = ScreenAssistantSession(
            directory: directory,
            imageURL: imageURL,
            thumbnail: image,
            showsPermissionHint: !CGPreflightScreenCaptureAccess()
        )
        session.onFirstQuestion = { [weak self] in self?.expand() }
        self.session = session

        let panel = ScreenAssistantPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.collapsedHeight),
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
        panel.onClose = { [weak self] in self?.close() }

        let hosting = NSHostingView(rootView: ScreenAssistantView(session: session, onClose: { [weak self] in self?.close() }))
        // The panel decides its own size; the hosting view must not push back.
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel

        place(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Centres the panel under the notch (or the menu bar on screens without
    /// one) of the screen the pointer is on.
    private func place(_ panel: NSPanel) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        let inset = max(screen.safeAreaInsets.top, menuBar)
        topEdge = screen.frame.maxY - inset - 14
        panel.setFrame(
            NSRect(x: screen.frame.midX - Self.width / 2, y: topEdge - Self.collapsedHeight,
                   width: Self.width, height: Self.collapsedHeight),
            display: true
        )
    }

    private func expand() {
        guard let panel else { return }
        var frame = panel.frame
        guard abs(frame.height - Self.expandedHeight) > 0.5 else { return }
        frame.size.height = Self.expandedHeight
        frame.origin.y = topEdge - Self.expandedHeight
        panel.setFrame(frame, display: true, animate: true)
    }

    // MARK: Storage

    private func releaseStorage() {
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
        terminateObserver = nil
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
    }
}
