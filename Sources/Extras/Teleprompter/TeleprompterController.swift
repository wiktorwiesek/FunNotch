//
//  TeleprompterController.swift
//  FunNotch
//
//  Owns the teleprompter panel: a borderless, non-activating panel hanging
//  directly under the notch of the screen the pointer is on. It is created when
//  shown and released when hidden, together with everything it started (the
//  scroll animation, the audio engine, the recogniser, the subscriptions), so
//  while it is closed the feature occupies nothing.
//
//  The panel has `sharingType = .none`: it does not appear in screen sharing,
//  screenshots or recordings, which is the point of a prompter used on a call.
//
//  It does not take keyboard focus when it opens, because the reader is usually
//  working in another app. A click on it makes it key, and then space, the
//  arrows and Esc work.
//

import AppKit
import Combine
import SwiftUI

/// Borderless panels refuse key status by default; this one accepts it so
/// that the keyboard shortcuts work after a click, and takes it on the click
/// itself because a non-activating panel is not made key by one.
final class TeleprompterPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !isKeyWindow { makeKey() }
        super.sendEvent(event)
    }
}

/// The panel's content: black with rounded bottom corners, the scrolling text,
/// a one-line status label and the controls strip. Also reports the pointer
/// entering and leaving, and the keys pressed while it is key.
@MainActor
final class TeleprompterRootView: NSView {
    static let cornerRadius: CGFloat = 18
    private static let controlsHeight: CGFloat = 46

    let textView: TeleprompterTextView
    private let statusLabel = NSTextField(labelWithString: "")
    private let controls: NSHostingView<TeleprompterControlsView>

    var onHover: ((Bool) -> Void)?
    /// Returns true when it used the key.
    var onKey: ((NSEvent) -> Bool)?

    init(size: NSSize, model: TeleprompterModel, store: TeleprompterStore) {
        let bounds = NSRect(origin: .zero, size: size)
        textView = TeleprompterTextView(frame: bounds)
        controls = NSHostingView(rootView: TeleprompterControlsView(model: model, store: store))
        super.init(frame: bounds)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = Self.cornerRadius
        layer?.cornerCurve = .continuous
        // Layers are y-up here, so "min Y" is the bottom edge.
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        layer?.masksToBounds = true

        textView.autoresizingMask = [.width, .height]
        addSubview(textView)

        statusLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.frame = NSRect(x: 14, y: size.height - 22, width: size.width - 28, height: 14)
        statusLabel.autoresizingMask = [.width, .minYMargin]
        statusLabel.isHidden = true
        addSubview(statusLabel)

        // The hosting view decides nothing about the panel's size.
        controls.sizingOptions = []
        controls.frame = NSRect(x: 0, y: 0, width: size.width, height: Self.controlsHeight)
        controls.autoresizingMask = [.width]
        addSubview(controls)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A short line at the top of the panel, where the text is faded out; nil
    /// clears it.
    func setStatus(_ text: String?) {
        statusLabel.stringValue = text ?? ""
        statusLabel.isHidden = (text ?? "").isEmpty
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        // `activeAlways`: the app is rarely the active one while the prompter
        // is on screen, and the controls still have to appear.
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

@MainActor
final class TeleprompterController {
    static let shared = TeleprompterController()

    private static let panelSize = NSSize(width: 560, height: 170)
    private static let placeholder = "Brak tekstu. Najedź kursorem na panel i wybierz ołówek, aby wpisać lub wkleić skrypt."
    private static let deniedHint = "Brak zgody na mikrofon lub rozpoznawanie mowy — przewijam według tempa."
    private static let unavailableHint = "Rozpoznawanie mowy jest niedostępne — przewijam według tempa."

    private var panel: TeleprompterPanel?
    private var root: TeleprompterRootView?
    private var model: TeleprompterModel?
    private var follower: TeleprompterVoiceFollower?
    private var cancellables = Set<AnyCancellable>()
    /// The script as read when the panel opened (or the editor last saved).
    private var script = ""
    /// Bumped whenever motion starts or stops, so an answer to a permission
    /// request that arrives after the user has paused is ignored.
    private var motionToken = 0
    /// Voice following is what moves the text in the current play session.
    private var voiceDriven = false
    /// Set when voice following failed in this session: what to tell the
    /// reader while timed scrolling takes over.
    private var voiceFallbackHint: String?

    var isVisible: Bool { panel != nil }

    private init() {}

    // MARK: - Showing

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        if let panel {
            panel.orderFrontRegardless()
            return
        }
        let store = TeleprompterStore.shared
        let model = TeleprompterModel()
        let root = TeleprompterRootView(size: Self.panelSize, model: model, store: store)

        let panel = TeleprompterPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
        // Invisible to screen sharing, screenshots and recordings.
        panel.sharingType = .none
        panel.contentView = root
        panel.makeFirstResponder(root)

        model.perform = { [weak self] command in self?.perform(command) }
        root.onHover = { [weak model] hovering in model?.isHovering = hovering }
        root.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        root.textView.onFinished = { [weak self] in self?.playbackFinished() }

        self.panel = panel
        self.root = root
        self.model = model
        script = store.readScript()
        voiceFallbackHint = nil
        voiceDriven = false

        place(panel)
        root.layoutSubtreeIfNeeded()
        root.textView.setMirrored(store.mirrored)
        buildLayout(startingAtWord: nil)
        subscribe(to: store)
        panel.orderFrontRegardless()
    }

    /// Closes the panel and releases everything it started.
    func hide() {
        guard panel != nil else { return }
        motionToken += 1
        stopVoice()
        cancellables.removeAll()
        root?.textView.teardown()
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        root = nil
        model = nil
        script = ""
        voiceDriven = false
    }

    /// Top-centre of the screen the pointer is on, with the top edge flush
    /// under the notch (or the menu bar on a screen without one).
    private func place(_ panel: TeleprompterPanel) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        let inset = max(screen.safeAreaInsets.top, menuBar)
        let size = Self.panelSize
        panel.setFrame(
            NSRect(
                x: screen.frame.midX - size.width / 2,
                y: screen.frame.maxY - inset - size.height,
                width: size.width, height: size.height
            ),
            display: true
        )
    }

    // MARK: - Script and layout

    /// Called by the editor after it saves.
    func scriptDidChange() {
        guard panel != nil else { return }
        script = TeleprompterStore.shared.readScript()
        relayout()
    }

    private func buildLayout(startingAtWord word: Int?) {
        guard let root else { return }
        let store = TeleprompterStore.shared
        let layout = TeleprompterTextLayout(
            script: script, placeholder: Self.placeholder,
            fontSize: CGFloat(store.fontSize), width: root.textView.textWidth
        )
        root.textView.setLayout(layout, startingAt: word.map { layout.offset(forWord: $0) })
    }

    /// Lays the script out again (new font size or new text) and carries on from
    /// the same word, playing or not.
    private func relayout() {
        guard let root, let model else { return }
        let textView = root.textView
        let wasPlaying = model.isPlaying
        let word = textView.textLayout.map { $0.wordIndex(atOffset: textView.currentOffset()) } ?? 0
        stopMotion()
        buildLayout(startingAtWord: word)
        if wasPlaying { startMotion() }
    }

    // MARK: - Preferences

    private func subscribe(to store: TeleprompterStore) {
        // `@Published` announces before it changes, so hop to the next turn of
        // the run loop to see the new value.
        store.$wordsPerMinute.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.speedChanged() }
            .store(in: &cancellables)
        store.$fontSize.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.relayout() }
            .store(in: &cancellables)
        store.$mirrored.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] mirrored in self?.root?.textView.setMirrored(mirrored) }
            .store(in: &cancellables)
        store.$voiceFollow.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.voiceSettingChanged() }
            .store(in: &cancellables)
    }

    private func speedChanged() {
        guard model?.isPlaying == true, !voiceDriven else { return }
        root?.textView.play(wordsPerMinute: TeleprompterStore.shared.wordsPerMinute)
    }

    private func voiceSettingChanged() {
        voiceFallbackHint = nil
        guard model?.isPlaying == true else { return }
        stopMotion()
        startMotion()
    }

    // MARK: - Commands

    private func perform(_ command: TeleprompterModel.Command) {
        let store = TeleprompterStore.shared
        switch command {
        case .togglePlay: togglePlay()
        case .slower: store.wordsPerMinute -= 10
        case .faster: store.wordsPerMinute += 10
        case .smaller: store.fontSize -= 2
        case .larger: store.fontSize += 2
        case .toggleVoice: store.voiceFollow.toggle()
        case .restart: restart()
        case .edit: TeleprompterEditorController.shared.show()
        case .close: hide()
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.keyCode {
        case 49: // space
            if !event.isARepeat { togglePlay() }
        case 126: // up
            perform(.faster)
        case 125: // down
            perform(.slower)
        case 123: // left
            skipBack()
        case 53: // escape
            if !event.isARepeat { hide() }
        default:
            return false
        }
        return true
    }

    // MARK: - Playback

    private func togglePlay() {
        if model?.isPlaying == true { pausePlayback() } else { play() }
    }

    private func play() {
        guard let root, let model, let layout = root.textView.textLayout else { return }
        if layout.words.isEmpty {
            root.setStatus("Brak tekstu do czytania — otwórz edytor.")
            return
        }
        // Pressing play at the end starts over.
        if root.textView.isAtEnd { root.textView.setOffset(layout.startOffset) }
        model.isPlaying = true
        startMotion()
    }

    private func pausePlayback() {
        model?.isPlaying = false
        stopMotion()
        root?.setStatus(nil)
    }

    private func playbackFinished() {
        model?.isPlaying = false
        motionToken += 1
        stopVoice()
        root?.setStatus(nil)
    }

    /// Starts whatever moves the text: the speaker's voice when following is on
    /// and working, otherwise one timed scroll.
    private func startMotion() {
        guard let root else { return }
        motionToken += 1
        let token = motionToken
        let store = TeleprompterStore.shared

        guard store.voiceFollow, voiceFallbackHint == nil else {
            voiceDriven = false
            root.setStatus(store.voiceFollow ? voiceFallbackHint : nil)
            root.textView.play(wordsPerMinute: store.wordsPerMinute)
            return
        }

        voiceDriven = true
        root.setStatus("Słucham…")
        Task { [weak self] in
            let granted = await TeleprompterPermissions.ensure()
            guard let self, token == self.motionToken else { return }
            guard granted else {
                self.fallBackToTimed(hint: Self.deniedHint)
                return
            }
            if !self.beginVoice() { self.fallBackToTimed(hint: Self.unavailableHint) }
        }
    }

    /// Halts the scroll and the listening; the position stays where it is.
    private func stopMotion() {
        motionToken += 1
        stopVoice()
        root?.textView.pause()
    }

    private func beginVoice() -> Bool {
        guard let textView = root?.textView, let layout = textView.textLayout else { return false }
        let follower = TeleprompterVoiceFollower(
            words: layout.words, pointer: layout.wordIndex(atOffset: textView.currentOffset())
        )
        follower.onMatch = { [weak self] index in self?.voiceMatched(index) }
        follower.onFailure = { [weak self] in
            self?.fallBackToTimed(hint: Self.unavailableHint)
        }
        do {
            try follower.start()
        } catch {
            return false
        }
        self.follower = follower
        return true
    }

    private func stopVoice() {
        follower?.stop()
        follower = nil
    }

    /// Voice following does not work here: remember that for this session, say
    /// so in the panel, and scroll at the set pace instead.
    private func fallBackToTimed(hint: String) {
        stopVoice()
        voiceFallbackHint = hint
        voiceDriven = false
        guard model?.isPlaying == true, let root else { return }
        motionToken += 1
        root.setStatus(hint)
        root.textView.play(wordsPerMinute: TeleprompterStore.shared.wordsPerMinute)
    }

    private func voiceMatched(_ index: Int) {
        guard let textView = root?.textView, let layout = textView.textLayout else { return }
        textView.jump(toOffset: layout.offset(forWord: index), duration: 0.4)
        // The last word has been spoken: nothing is left to wait for.
        if index >= layout.words.count - 1 {
            model?.isPlaying = false
            motionToken += 1
            stopVoice()
            root?.setStatus(nil)
        }
    }

    // MARK: - Moving around

    private func skipBack() {
        guard let textView = root?.textView, let layout = textView.textLayout else { return }
        let line = max(0, layout.lineIndex(atOffset: textView.currentOffset()) - 3)
        moveTo(layout.mid(ofLine: line))
    }

    private func restart() {
        guard let textView = root?.textView, let layout = textView.textLayout else { return }
        moveTo(layout.startOffset)
    }

    /// Eases to `offset`. A timed scroll that was running picks up again from
    /// there; voice following simply continues from the new place.
    private func moveTo(_ offset: CGFloat) {
        guard let textView = root?.textView, let layout = textView.textLayout else { return }
        follower?.pointer = layout.wordIndex(atOffset: offset)
        textView.jump(toOffset: offset, duration: 0.35) { [weak self] in
            guard let self, self.model?.isPlaying == true, !self.voiceDriven else { return }
            self.root?.textView.play(wordsPerMinute: TeleprompterStore.shared.wordsPerMinute)
        }
    }
}
