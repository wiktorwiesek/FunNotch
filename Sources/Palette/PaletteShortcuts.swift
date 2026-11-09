//
//  PaletteShortcuts.swift
//  FunNotch
//
//  Apple Shortcuts through the `shortcuts` command-line tool: the list for the
//  palette to search, and running one with feedback in the notch.
//

import AppKit
import Foundation
import SwiftUI

@MainActor
final class PaletteShortcuts: ObservableObject {
    static let shared = PaletteShortcuts()

    private nonisolated static let tool = "/usr/bin/shortcuts"

    @Published private(set) var names: [String] = []
    @Published private(set) var isLoading = false
    /// Why the list is empty when it is not simply because there are none.
    @Published private(set) var problem: String?

    private init() {}

    var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: Self.tool) }

    /// Re-reads the list in the background; called when the palette opens, so
    /// a shortcut created a minute ago is already there.
    func refresh() {
        guard !isLoading else { return }
        guard isAvailable else {
            problem = "Brak narzędzia shortcuts w systemie"
            return
        }
        isLoading = true
        Task.detached(priority: .utility) {
            let result = await Self.run(["list"], timeout: 15)
            await MainActor.run {
                let shortcuts = PaletteShortcuts.shared
                shortcuts.isLoading = false
                if result.status == 0 {
                    shortcuts.problem = nil
                    shortcuts.names = result.output
                        .split(whereSeparator: \.isNewline)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                } else {
                    shortcuts.problem = "Nie udało się odczytać skrótów"
                    DiagnosticLog.write("palette", "shortcuts list failed: \(result.error)")
                }
            }
        }
    }

    /// Runs a shortcut and reports the outcome in the notch.
    func run(_ name: String) {
        IslandCenter.shared.post(Island(
            symbol: "bolt.fill",
            tint: SettingsStyle.orange,
            title: name,
            detail: " · uruchomiono",
            duration: 1.8
        ))
        Task.detached(priority: .userInitiated) {
            // A shortcut that asks for input would wait forever, so cap it.
            let result = await Self.run(["run", name], timeout: 300)
            await MainActor.run {
                if result.status == 0 {
                    IslandCenter.shared.post(Island(
                        symbol: "checkmark.circle.fill",
                        tint: SettingsStyle.green,
                        title: name,
                        detail: " · gotowe"
                    ))
                } else {
                    DiagnosticLog.write("palette", "shortcut '\(name)' failed (\(result.status)): \(result.error)")
                    IslandCenter.shared.post(Island(
                        symbol: "xmark.circle.fill",
                        tint: SettingsStyle.red,
                        title: name,
                        detail: " · nie udało się",
                        duration: 4
                    ))
                }
            }
        }
    }

    private struct Output {
        var status: Int32
        var output: String
        var error: String
    }

    private nonisolated static func run(_ arguments: [String], timeout: TimeInterval) async -> Output {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            do {
                try process.run()
            } catch {
                continuation.resume(returning: Output(status: -1, output: "", error: error.localizedDescription))
                return
            }
            // Harmless if the tool has finished by then: isRunning is false.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
            }
            // Read before waiting: a full pipe would block the tool forever.
            DispatchQueue.global().async {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errorData = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: Output(
                    status: process.terminationStatus,
                    output: String(decoding: data, as: UTF8.self),
                    error: String(decoding: errorData, as: UTF8.self)
                ))
            }
        }
    }
}
