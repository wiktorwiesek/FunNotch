//
//  TeleprompterStore.swift
//  FunNotch
//
//  The teleprompter's preferences and its script. Preferences are four small
//  values in UserDefaults; the script is a plain text file in the app's own
//  Application Support folder, because a script can be pages long and the user
//  should get it back after a restart without it sitting on the Desktop.
//
//  Nothing here is read until the prompter, the editor or the settings card is
//  opened, and the script text is never kept by the store: whoever needs it
//  reads it, and lets go of it when it is closed.
//

import Foundation

@MainActor
final class TeleprompterStore: ObservableObject {
    static let shared = TeleprompterStore()

    static let speedRange: ClosedRange<Double> = 60 ... 260
    static let fontSizeRange: ClosedRange<Double> = 16 ... 48

    private enum Key {
        static let speed = "extras.teleprompter.speed"
        static let fontSize = "extras.teleprompter.fontSize"
        static let voiceFollow = "extras.teleprompter.voiceFollow"
        static let mirrored = "extras.teleprompter.mirrored"
    }

    /// Reading speed in words per minute; drives timed scrolling and the
    /// reading-time estimate in the editor.
    @Published var wordsPerMinute: Double {
        didSet {
            let clamped = Self.clamp(wordsPerMinute, to: Self.speedRange)
            if clamped != wordsPerMinute { wordsPerMinute = clamped; return }
            UserDefaults.standard.set(wordsPerMinute, forKey: Key.speed)
        }
    }

    @Published var fontSize: Double {
        didSet {
            let clamped = Self.clamp(fontSize, to: Self.fontSizeRange)
            if clamped != fontSize { fontSize = clamped; return }
            UserDefaults.standard.set(fontSize, forKey: Key.fontSize)
        }
    }

    /// Scroll with the speaker's voice instead of at a fixed pace. Turning it
    /// on is the one moment the app asks for speech and microphone access.
    @Published var voiceFollow: Bool {
        didSet {
            UserDefaults.standard.set(voiceFollow, forKey: Key.voiceFollow)
            if voiceFollow && !oldValue {
                Task { _ = await TeleprompterPermissions.ensure() }
            }
        }
    }

    /// Mirrored text, for a prompter read through a beam splitter glass.
    @Published var mirrored: Bool {
        didSet { UserDefaults.standard.set(mirrored, forKey: Key.mirrored) }
    }

    private init() {
        let defaults = UserDefaults.standard
        wordsPerMinute = Self.clamp(defaults.object(forKey: Key.speed) as? Double ?? 140, to: Self.speedRange)
        fontSize = Self.clamp(defaults.object(forKey: Key.fontSize) as? Double ?? 26, to: Self.fontSizeRange)
        voiceFollow = defaults.object(forKey: Key.voiceFollow) as? Bool ?? false
        mirrored = defaults.object(forKey: Key.mirrored) as? Bool ?? false
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    // MARK: - Script

    /// `Application Support/FunNotch/Teleprompter/script.txt`. The folder is
    /// created when the script is first written, not before.
    private var folderURL: URL {
        FileManager.default
            .standardDirectory(.applicationSupportDirectory, fallback: "Library/Application Support")
            .appendingPathComponent("FunNotch", isDirectory: true)
            .appendingPathComponent("Teleprompter", isDirectory: true)
    }

    private var scriptURL: URL { folderURL.appendingPathComponent("script.txt") }

    /// The saved script, or an empty string when there is none yet.
    func readScript() -> String {
        (try? String(contentsOf: scriptURL, encoding: .utf8)) ?? ""
    }

    /// Writes the script atomically so a crash mid-save cannot leave half of it.
    /// The log gets the outcome only, never the text.
    func writeScript(_ text: String) {
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            try text.write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            DiagnosticLog.write("teleprompter", "could not save the script")
        }
    }
}
