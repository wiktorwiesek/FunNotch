//
//  TeleprompterVoice.swift
//  FunNotch
//
//  Voice following for the teleprompter: listens to the microphone, recognises
//  speech, and tells the prompter which word of the script the speaker has
//  reached. It exists only while the prompter is playing with the option on:
//  every start builds an audio engine, a tap and a recognition task, and every
//  stop removes the tap, stops the engine and ends the task.
//
//  Nothing the speaker says is kept or logged. A partial result is reduced to
//  its last few words, compared with the script, and dropped.
//
//  Speech recognition is on-device whenever the system has a model for the
//  language; the recogniser's one-minute limit is dealt with by starting a new
//  task before it expires while the audio engine keeps running.
//

import AVFoundation
import Speech

// MARK: - Permissions

/// Speech and microphone access, asked for when the user first turns voice
/// following on and never otherwise.
@MainActor
enum TeleprompterPermissions {
    private static var inFlight: Task<Bool, Never>?

    /// True when both permissions are granted. Concurrent callers share one
    /// request, so two switches flipped together show one prompt.
    static func ensure() async -> Bool {
        if let inFlight { return await inFlight.value }
        let task = Task { await request() }
        inFlight = task
        let granted = await task.value
        inFlight = nil
        return granted
    }

    nonisolated private static func request() async -> Bool {
        var speech = SFSpeechRecognizer.authorizationStatus()
        if speech == .notDetermined {
            speech = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        guard speech == .authorized else { return false }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}

// MARK: - Matching

/// Finds where in the script the last few heard words are.
enum TeleprompterMatcher {
    /// How far ahead of the pointer a heard phrase may be found.
    static let window = 30

    /// Normalised words of recognised text.
    static func tokens(of text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace })
            .map { TeleprompterTextLayout.normalise(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// Index of the script word the last heard word matches, searching from
    /// `pointer` up to `window` words ahead; nil when nothing fits.
    ///
    /// Up to four heard words are compared with the script words that end at
    /// each candidate. The last one must match; one of the others may differ,
    /// which absorbs a skipped or misheard word. The nearest candidate wins, so
    /// a common word cannot drag the text far ahead.
    static func match(heard: [String], words: [String], pointer: Int) -> Int? {
        let tail = Array(heard.suffix(4))
        guard let last = tail.last, !words.isEmpty else { return nil }
        // A lone short word ("i", "w", "to") says nothing about the position.
        if tail.count == 1, last.count < 4 { return nil }
        let required = tail.count >= 3 ? tail.count - 1 : tail.count
        let upper = min(words.count - 1, pointer + window)
        guard pointer >= 0, pointer <= upper else { return nil }

        for candidate in pointer ... upper where words[candidate] == last {
            var hits = 1
            for back in 1 ..< max(tail.count, 1) {
                let index = candidate - back
                if index >= 0, words[index] == tail[tail.count - 1 - back] { hits += 1 }
            }
            if hits >= required { return candidate }
        }
        return nil
    }
}

// MARK: - Follower

/// Hands microphone buffers to whichever recognition request is current. The
/// audio thread calls `append`; the main actor swaps the request.
final class TeleprompterRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ newRequest: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        request = newRequest
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let current = request
        lock.unlock()
        current?.append(buffer)
    }
}

@MainActor
final class TeleprompterVoiceFollower {
    enum Failure: Error {
        case recognizerUnavailable
        case engineFailed
    }

    /// The script word the speaker has just reached; only ever moves forward.
    var onMatch: ((Int) -> Void)?
    /// Recognition cannot continue; the prompter falls back to timed scrolling.
    var onFailure: (() -> Void)?
    /// Index of the word last matched (or, before any, the word being read).
    var pointer: Int

    private let words: [String]
    private let box = TeleprompterRequestBox()
    private var recognizer: SFSpeechRecognizer?
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var taskStartedAt = Date()
    private var quickFailures = 0
    private var recycleTimer: Timer?
    private var configurationObserver: NSObjectProtocol?
    private(set) var isRunning = false

    /// Where the recogniser's own limit is about to cut a task off; a new task
    /// takes over a little before that.
    private static let taskLifetime: TimeInterval = 50

    init(words: [String], pointer: Int) {
        self.words = words
        self.pointer = pointer
    }

    // MARK: Lifecycle

    func start() throws {
        guard !isRunning else { return }
        guard let recognizer = Self.makeRecognizer() else { throw Failure.recognizerUnavailable }
        // Results arrive on the main queue, where the pointer lives.
        recognizer.queue = .main
        self.recognizer = recognizer
        do {
            try startEngine()
        } catch {
            self.recognizer = nil
            throw error
        }
        isRunning = true
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.engineConfigurationChanged() }
        }
        beginTask()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        generation += 1
        recycleTimer?.invalidate()
        recycleTimer = nil
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        box.set(nil)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        stopEngine()
        recognizer = nil
    }

    // MARK: Audio

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.engineFailed }
        input.installTap(onBus: 0, bufferSize: 2048, format: format, block: Self.makeTapBlock(box))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw Failure.engineFailed
        }
        self.engine = engine
    }

    private func stopEngine() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    /// Built outside the main actor on purpose: the audio thread calls it, and
    /// a closure formed inside a main-actor method would be main-actor bound.
    nonisolated private static func makeTapBlock(_ box: TeleprompterRequestBox) -> AVAudioNodeTapBlock {
        { buffer, _ in box.append(buffer) }
    }

    /// An input device change (headset plugged in, say) stops the engine; build
    /// a new one around the new device, and give up only if that fails.
    private func engineConfigurationChanged() {
        guard isRunning else { return }
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        stopEngine()
        do {
            try startEngine()
        } catch {
            DiagnosticLog.write("teleprompter", "microphone could not be restarted")
            onFailure?()
            return
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.engineConfigurationChanged() }
        }
    }

    // MARK: Recognition

    /// The script's language first (Polish), then the system language, then
    /// English.
    private static func makeRecognizer() -> SFSpeechRecognizer? {
        let candidates = [Locale(identifier: "pl-PL"), Locale.current, Locale(identifier: "en-US")]
        for locale in candidates {
            if let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable { return recognizer }
        }
        return nil
    }

    /// Starts a recognition task and retires the previous one. The new request
    /// is installed first, so the audio tap never has a gap to fall into.
    private func beginTask() {
        guard isRunning, let recognizer else { return }
        let previousRequest = request
        let previousTask = task
        generation += 1
        let current = generation

        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        newRequest.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition { newRequest.requiresOnDeviceRecognition = true }
        box.set(newRequest)
        request = newRequest
        taskStartedAt = Date()
        task = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            // Only the text and two flags leave the callback; nothing is stored.
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            MainActor.assumeIsolated {
                self?.handle(text: text, isFinal: isFinal, failed: failed, generation: current)
            }
        }

        previousRequest?.endAudio()
        previousTask?.cancel()

        recycleTimer?.invalidate()
        recycleTimer = Timer.scheduledTimer(withTimeInterval: Self.taskLifetime, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.beginTask() }
        }
    }

    private func handle(text: String?, isFinal: Bool, failed: Bool, generation callbackGeneration: Int) {
        guard isRunning, callbackGeneration == generation else { return }

        if let text, !text.isEmpty {
            quickFailures = 0
            let heard = TeleprompterMatcher.tokens(of: text)
            if let index = TeleprompterMatcher.match(heard: heard, words: words, pointer: pointer),
               index > pointer {
                pointer = index
                onMatch?(index)
            }
        }

        // A task that ends on its own (silence timeout, the recogniser's limit)
        // is replaced. Three that die almost at once mean something is wrong.
        guard failed || isFinal else { return }
        if Date().timeIntervalSince(taskStartedAt) < 2 { quickFailures += 1 } else { quickFailures = 0 }
        if quickFailures >= 3 {
            DiagnosticLog.write("teleprompter", "speech recognition keeps failing")
            onFailure?()
            return
        }
        beginTask()
    }
}
