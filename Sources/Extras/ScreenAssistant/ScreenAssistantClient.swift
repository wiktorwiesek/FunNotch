//
//  ScreenAssistantClient.swift
//  FunNotch
//
//  Everything the screen assistant needs to talk to an AI without owning an
//  API key: finding a command-line client the user already has (omp, then
//  gemini, or a command template of their own), building its argument list,
//  and running it headless as a child process whose answer is read as it is
//  produced.
//
//  No shell ever launches the client: the executable and its arguments are
//  handed to `Process` as an array, so a question containing quotes, `$(…)`
//  or backticks stays plain text. The one place a shell appears is a
//  five-second `zsh -l` that only prints PATH, because a GUI app does not
//  inherit the directories the user's terminal has (Homebrew, bun, mise…).
//

import Foundation

// MARK: - Preferences

enum ScreenAssistantPrefs {
    static let modelKey = "extras.screenassistant.model"
    static let instructionKey = "extras.screenassistant.instruction"
    static let commandKey = "extras.screenassistant.command"

    static let defaultInstruction = "Odpowiadaj po polsku, zwięźle. Odpowiedz na pytanie dotyczące załączonego obrazu."

    private static func text(_ key: String) -> String {
        (UserDefaults.standard.string(forKey: key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var model: String { text(modelKey) }
    static var customCommand: String { text(commandKey) }

    /// Empty in settings means "use the default".
    static var instruction: String {
        let value = text(instructionKey)
        return value.isEmpty ? defaultInstruction : value
    }
}

// MARK: - Locating a client

struct ScreenAssistantResolved {
    enum Kind {
        case omp
        case gemini
        case custom(template: String)
    }

    let kind: Kind
    let executable: String
    /// Directories prepended to the child's PATH, so a client that starts
    /// through `#!/usr/bin/env node` (or bun) finds its interpreter.
    let directories: [String]

    var displayName: String {
        switch kind {
        case .omp: return "omp"
        case .gemini: return "gemini"
        case .custom: return "własne polecenie (\((executable as NSString).lastPathComponent))"
        }
    }
}

enum ScreenAssistantResolution {
    case found(ScreenAssistantResolved)
    /// A custom command is set but its program cannot be found.
    case customMissing(String)
    case notFound
}

enum ScreenAssistantLocator {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedShellDirectories: [String]?

    static func resolve() async -> ScreenAssistantResolution {
        let directories = await searchDirectories()

        let custom = ScreenAssistantPrefs.customCommand
        if !custom.isEmpty, let program = ScreenAssistantCommand.split(custom).first {
            if let path = locate(program, in: directories) {
                return .found(ScreenAssistantResolved(kind: .custom(template: custom), executable: path, directories: directories))
            }
            return .customMissing(program)
        }

        if let path = locate("omp", in: directories) {
            return .found(ScreenAssistantResolved(kind: .omp, executable: path, directories: directories))
        }
        if let path = locate("gemini", in: directories) {
            return .found(ScreenAssistantResolved(kind: .gemini, executable: path, directories: directories))
        }
        return .notFound
    }

    /// A bare name is looked up in `directories`; anything with a slash is
    /// taken as a path (with `~` expanded).
    private static func locate(_ program: String, in directories: [String]) -> String? {
        let manager = FileManager.default
        if program.contains("/") {
            let path = (program as NSString).expandingTildeInPath
            return manager.isExecutableFile(atPath: path) ? path : nil
        }
        for directory in directories {
            let path = directory + "/" + program
            var isDirectory: ObjCBool = false
            if manager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
               manager.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Fixed install locations first, then the app's own PATH, then the login
    /// shell's. Only directories that exist are kept.
    private static func searchDirectories() async -> [String] {
        var candidates = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"]
        candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        candidates += await loginShellDirectories()

        var seen = Set<String>()
        var result: [String] = []
        for directory in candidates where !directory.isEmpty && seen.insert(directory).inserted {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue {
                result.append(directory)
            }
        }
        return result
    }

    private static func loginShellDirectories() async -> [String] {
        if let cached = cachedDirectories() { return cached }

        let directories: [String]? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: readLoginShellPath())
            }
        }
        // A failed attempt is not remembered: the next question tries again.
        guard let directories else { return [] }
        remember(directories)
        return directories
    }

    private static func cachedDirectories() -> [String]? {
        lock.lock()
        defer { lock.unlock() }
        return cachedShellDirectories
    }

    private static func remember(_ directories: [String]) {
        lock.lock()
        defer { lock.unlock() }
        cachedShellDirectories = directories
    }

    /// Runs `zsh -l -c` printing only PATH. The marker lets the answer be
    /// picked out of whatever the user's profile prints on startup.
    private static func readLoginShellPath() -> [String]? {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap {
            FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil
        } ?? "/bin/zsh"
        let marker = "__FUNNOTCH_PATH__"

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "printf '%s%s' '\(marker)' \"$PATH\""]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8),
              let range = text.range(of: marker, options: .backwards) else { return nil }
        let path = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return path.split(separator: ":").map(String.init)
    }
}

// MARK: - Building the command

enum ScreenAssistantCommand {
    struct Launch {
        let executable: String
        let arguments: [String]
    }

    /// Earlier turns are sent as plain text because each client call is
    /// stateless. Capped so a long conversation cannot overflow the argument
    /// limit of the system.
    private static let maxHistoryTurns = 6
    private static let maxHistoryAnswer = 4000

    static func prompt(instruction: String, history: [(question: String, answer: String)], question: String) -> String {
        var parts = [instruction]
        let recent = history.suffix(maxHistoryTurns)
        if !recent.isEmpty {
            let earlier = recent.map { turn in
                "Pytanie: \(turn.question)\nOdpowiedź: \(String(turn.answer.prefix(maxHistoryAnswer)))"
            }
            parts.append(earlier.joined(separator: "\n\n"))
        }
        parts.append("Pytanie: \(question)")
        return parts.joined(separator: "\n\n")
    }

    static func launch(_ resolved: ScreenAssistantResolved, imagePath: String, prompt: String) -> Launch? {
        let model = ScreenAssistantPrefs.model
        switch resolved.kind {
        case .omp:
            var arguments = ["-p", "--no-session", "--no-extensions", "--no-skills", "--no-rules",
                             "--no-context-files", "--no-tools", "--no-title", "--thinking=off"]
            if !model.isEmpty { arguments.append("--model=\(model)") }
            arguments.append("@\(imagePath)")
            arguments.append(prompt)
            return Launch(executable: resolved.executable, arguments: arguments)

        case .gemini:
            var arguments = ["-p", "\(prompt)\n\nObraz: @\(imagePath)"]
            if !model.isEmpty { arguments += ["-m", model] }
            return Launch(executable: resolved.executable, arguments: arguments)

        case .custom(let template):
            let tokens = split(template)
            guard tokens.count >= 1 else { return nil }
            let arguments = tokens.dropFirst().map { expand($0, image: imagePath, prompt: prompt) }
            return Launch(executable: resolved.executable, arguments: arguments)
        }
    }

    /// Splits on whitespace, keeping double-quoted stretches together (a
    /// backslash before a quote makes it literal). Never evaluates anything.
    static func split(_ template: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var hasToken = false
        var inQuotes = false
        var iterator = template.makeIterator()
        while let character = iterator.next() {
            if character == "\\", inQuotes {
                if let next = iterator.next() {
                    if next != "\"" && next != "\\" { current.append(character) }
                    current.append(next)
                } else {
                    current.append(character)
                }
                hasToken = true
            } else if character == "\"" {
                inQuotes.toggle()
                hasToken = true
            } else if character.isWhitespace, !inQuotes {
                if hasToken { tokens.append(current) }
                current = ""
                hasToken = false
            } else {
                current.append(character)
                hasToken = true
            }
        }
        if hasToken { tokens.append(current) }
        return tokens
    }

    /// Replaces `{image}` and `{prompt}` in one pass, so a placeholder that
    /// appears inside the question is not substituted a second time.
    private static func expand(_ token: String, image: String, prompt: String) -> String {
        var result = ""
        var rest = Substring(token)
        while !rest.isEmpty {
            let imageRange = rest.range(of: "{image}")
            let promptRange = rest.range(of: "{prompt}")
            var match: Range<Substring.Index>?
            var value = ""
            if let imageRange, promptRange == nil || imageRange.lowerBound <= promptRange!.lowerBound {
                match = imageRange
                value = image
            } else if let promptRange {
                match = promptRange
                value = prompt
            }
            guard let match else {
                result += String(rest)
                break
            }
            result += String(rest[rest.startIndex ..< match.lowerBound])
            result += value
            rest = rest[match.upperBound...]
        }
        return result
    }
}

// MARK: - Running it

enum ScreenAssistantOutcome: Sendable {
    case success
    case failure(String)
    case cancelled
}

/// One child process. Text and the final outcome are delivered on the main
/// queue, in order, so a caller can append chunks and then close the turn
/// without any locking of its own. The object lives only while the process
/// runs: every handler that points back at it is cleared on completion.
final class ScreenAssistantRun: @unchecked Sendable {
    static let timeout: TimeInterval = 120

    private let process = Process()
    private let outPipe = Pipe()
    private let errPipe = Pipe()
    private let lock = NSLock()
    private let onText: @Sendable (String) -> Void
    private let onFinish: @Sendable (ScreenAssistantOutcome) -> Void

    private var launched = false
    private var cancelled = false
    private var timedOut = false
    private var exited = false
    private var outEOF = false
    private var errEOF = false
    private var completed = false
    private var status: Int32 = 0
    private var pendingBytes = Data()
    private var errorTail = Data()
    private var watchdog: DispatchWorkItem?

    init(onText: @escaping @Sendable (String) -> Void, onFinish: @escaping @Sendable (ScreenAssistantOutcome) -> Void) {
        self.onText = onText
        self.onFinish = onFinish
    }

    /// Returns a Polish error message when the process cannot be started.
    func start(_ launch: ScreenAssistantCommand.Launch, directories: [String], workingDirectory: URL) -> String? {
        // Writing to a child that has already exited must not kill the app.
        signal(SIGPIPE, SIG_IGN)

        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        process.currentDirectoryURL = workingDirectory
        var environment = ProcessInfo.processInfo.environment
        let inherited = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        environment["PATH"] = (directories + inherited).filter { seen.insert($0).inserted }.joined(separator: ":")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outPipe
        process.standardError = errPipe

        process.terminationHandler = { [self] finished in
            processExited(status: finished.terminationStatus)
        }
        outPipe.fileHandleForReading.readabilityHandler = { [self] handle in readOutput(handle) }
        errPipe.fileHandleForReading.readabilityHandler = { [self] handle in readError(handle) }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            return "Nie udało się uruchomić klienta AI."
        }

        lock.lock()
        launched = true
        let item = DispatchWorkItem { [weak self] in self?.timeoutFired() }
        watchdog = item
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout, execute: item)
        return nil
    }

    func cancel() {
        lock.lock()
        if completed {
            lock.unlock()
            return
        }
        cancelled = true
        let running = launched && !exited
        lock.unlock()
        if running { terminateChild() }
    }

    // MARK: Child I/O

    private func readOutput(_ handle: FileHandle) {
        let data = handle.availableData
        if data.isEmpty {
            handle.readabilityHandler = nil
            lock.lock()
            outEOF = true
            lock.unlock()
            finishIfDone(force: false)
            return
        }
        lock.lock()
        defer { lock.unlock() }
        if completed { return }
        pendingBytes.append(data)
        let text = Self.takeDecodable(&pendingBytes)
        // Dispatched while the lock is held: the finish message is queued
        // under the same lock, so a chunk can never overtake it.
        if !text.isEmpty {
            let deliver = onText
            DispatchQueue.main.async { deliver(text) }
        }
    }

    private func readError(_ handle: FileHandle) {
        let data = handle.availableData
        if data.isEmpty {
            handle.readabilityHandler = nil
            lock.lock()
            errEOF = true
            lock.unlock()
            finishIfDone(force: false)
            return
        }
        lock.lock()
        errorTail.append(data)
        if errorTail.count > 4096 { errorTail = Data(errorTail.suffix(4096)) }
        lock.unlock()
    }

    private func processExited(status: Int32) {
        lock.lock()
        self.status = status
        exited = true
        lock.unlock()
        finishIfDone(force: false)
        // A grandchild holding the pipe open must not keep the panel waiting.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.finishIfDone(force: true)
        }
    }

    private func finishIfDone(force: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !completed, exited, force || (outEOF && errEOF) else { return }
        completed = true
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        watchdog?.cancel()
        watchdog = nil

        if !pendingBytes.isEmpty {
            let rest = String(decoding: pendingBytes, as: UTF8.self)
            pendingBytes.removeAll()
            let deliver = onText
            DispatchQueue.main.async { deliver(rest) }
        }

        let outcome: ScreenAssistantOutcome
        if cancelled {
            outcome = .cancelled
        } else if timedOut {
            outcome = .failure("Klient AI nie odpowiedział w ciągu \(Int(Self.timeout)) s.")
        } else if status != 0 {
            outcome = .failure(Self.lastLine(of: errorTail) ?? "Klient AI zakończył działanie z kodem \(status).")
        } else {
            outcome = .success
        }
        let finish = onFinish
        DispatchQueue.main.async { finish(outcome) }
    }

    // MARK: Stopping

    private func timeoutFired() {
        lock.lock()
        if completed || exited {
            lock.unlock()
            return
        }
        timedOut = true
        lock.unlock()
        terminateChild()
    }

    private func terminateChild() {
        guard process.isRunning else { return }
        process.terminate()
        // A client that ignores SIGTERM is killed two seconds later.
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.process.isRunning, self.process.processIdentifier == pid else { return }
            kill(pid, SIGKILL)
        }
    }

    // MARK: Helpers

    /// Takes the longest prefix that is valid UTF-8, leaving an incomplete
    /// multi-byte character at the end for the next read to finish.
    private static func takeDecodable(_ data: inout Data) -> String {
        var cut = data.count
        while cut > 0, cut >= data.count - 3 {
            if let text = String(data: data.prefix(cut), encoding: .utf8) {
                data = Data(data.dropFirst(cut))
                return text
            }
            cut -= 1
        }
        let text = String(decoding: data, as: UTF8.self)
        data.removeAll()
        return text
    }

    private static func lastLine(of data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        guard let line = text.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .last(where: { !$0.isEmpty }) else { return nil }
        return String(line.prefix(240))
    }
}
