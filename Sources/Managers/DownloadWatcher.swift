//
//  DownloadWatcher.swift
//  FunNotch
//
//  Announces finished downloads in the notch. Browsers write to a temporary
//  name while a download is in flight (`.download`, `.crdownload`, `.part`),
//  so "finished" means the real file has appeared and stopped growing.
//

import AppKit
import SwiftUI
import Combine
import Foundation

@MainActor
final class DownloadWatcher: ObservableObject {
    static let shared = DownloadWatcher()

    @Published private(set) var lastDownload: URL?

    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var seen: Set<String> = []
    private var startedAt = Date()
    private var cancellables = Set<AnyCancellable>()
    private var rescanWork: DispatchWorkItem?
    /// Files that arrived by AirDrop within the last moment, announced together.
    private var airDropBatch: [URL] = []
    private var airDropWork: DispatchWorkItem?
    /// Bumped on every restart, so a slow start that finishes after a newer
    /// one is thrown away rather than attached.
    private var generation = 0

    /// Extensions that mean "still downloading".
    private static let inProgressExtensions: Set<String> = [
        "download", "crdownload", "part", "partial", "opdownload", "tmp",
    ]

    private init() {}

    func start() {
        NotificationCenter.default.publisher(for: .settingsChanged)
            .compactMap { $0.object as? String }
            .filter { $0 == "catchDownloads" }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.restart() }
            .store(in: &cancellables)

        restart()
    }

    func restart() {
        stop()
        generation += 1
        guard Settings.shared.catchDownloads else { return }

        let directory = FileManager.default.standardDirectory(.downloadsDirectory, fallback: "Downloads")
        startedAt = Date()
        let generation = self.generation

        // Off the main thread, for the same reason as the screenshot watcher:
        // Downloads is protected, and the first read can wait indefinitely on
        // a permission prompt.
        DispatchQueue.global(qos: .utility).async {
            let names = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            let descriptor = open(directory.path, O_EVTONLY)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard generation == self.generation else {
                        if descriptor >= 0 { close(descriptor) }
                        return
                    }
                    self.attach(descriptor: descriptor, to: directory, seen: names)
                }
            }
        }
    }

    private func attach(descriptor: CInt, to directory: URL, seen names: Set<String>) {
        seen = names
        guard descriptor >= 0 else {
            DiagnosticLog.write("downloads", "could not watch \(directory.path)")
            return
        }
        self.descriptor = descriptor

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleScan(in: directory) }
        }
        // Closes the descriptor this source was made with. Reading
        // `self.descriptor` here instead would close whichever one is current
        // by the time the handler runs — after a restart, the new one.
        source.setCancelHandler { [weak self] in
            close(descriptor)
            MainActor.assumeIsolated {
                if self?.descriptor == descriptor { self?.descriptor = -1 }
            }
        }
        source.resume()
        self.source = source

        DiagnosticLog.write("downloads", "watching \(directory.path)")
    }

    func stop() {
        rescanWork?.cancel()
        rescanWork = nil
        source?.cancel()
        source = nil
    }

    private func scheduleScan(in directory: URL) {
        rescanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan(in: directory) }
        rescanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func scan(in directory: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let fresh = names.filter { !seen.contains($0) }
        // Replaced, not merged: a file that was deleted and downloaded again
        // under the same name is a new download and has to be announced.
        seen = Set(names)

        for name in fresh {
            guard !name.hasPrefix(".") else { continue }
            let url = directory.appendingPathComponent(name)

            // Skip the placeholder files browsers use while downloading; the
            // finished file lands under its real name a moment later.
            guard !Self.inProgressExtensions.contains(url.pathExtension.lowercased()) else { continue }

            // Creation date is judged later, in `finish`: an AirDropped file
            // may carry the sender's date, so it cannot be checked before the
            // quarantine record says where the file came from.
            waitUntilStable(url)
        }
    }

    private func waitUntilStable(_ url: URL, attempt: Int = 0) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let now = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if now == size {
                self.finish(url)
            } else if attempt < 600 {
                self.waitUntilStable(url, attempt: attempt + 1)
            }
        }
    }

    /// Decides what a finished file is: AirDrop gets its own island (and the
    /// generic download activity stays quiet), everything else is a download.
    private func finish(_ url: URL, rechecksDone: Int = 0) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        let route = DownloadRoute.decide(
            origin: AirDropDetector.origin(of: url),
            createdAt: created,
            watchStartedAt: startedAt,
            rechecksDone: rechecksDone
        )
        switch route {
        case .download:
            announce(url)
        case .airDrop:
            receiveAirDrop(url)
        case .ignore:
            break
        case .recheck:
            DispatchQueue.main.asyncAfter(deadline: .now() + DownloadRoute.recheckDelay) { [weak self] in
                self?.finish(url, rechecksDone: rechecksDone + 1)
            }
        }
    }

    private func announce(_ url: URL) {
        lastDownload = url
        DiagnosticLog.write("downloads", "finished \(url.lastPathComponent)")

        if Settings.shared.downloadsToShelf {
            ShelfManager.shared.add(url: url)
        }

        NotchWindowManager.shared.broadcast { viewModel in
            viewModel.showExpandingView(
                type: .download,
                value: 1,
                icon: "arrow.down.circle.fill",
                duration: 3.0
            )
        }
    }

    // MARK: - AirDrop

    private func receiveAirDrop(_ url: URL) {
        DiagnosticLog.write("downloads", "airdrop \(url.lastPathComponent)")

        // Has its own switch: AirDrop is not the same decision as "put every
        // download on the shelf".
        if ShelfClipPrefs.airDropToShelf {
            ShelfManager.shared.add(url: url)
        }

        // Several photos arrive as separate files a moment apart; one island
        // for the batch instead of a flicker per file.
        airDropBatch.append(url)
        airDropWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.announceAirDrop() }
        airDropWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func announceAirDrop() {
        let urls = airDropBatch
        airDropBatch = []
        airDropWork = nil
        guard let island = Self.airDropIsland(for: urls) else { return }
        IslandCenter.shared.post(island)
    }

    /// SF Symbol for AirDrop. "airdrop" is not in the symbol set of every macOS
    /// release (it is missing on this one), so fall back to the glyph the shelf's
    /// own AirDrop button uses rather than show an empty wing.
    static let airDropSymbol: String = {
        ["airdrop", "dot.radiowaves.right"].first {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil
        } ?? "dot.radiowaves.right"
    }()

    static func airDropIsland(for urls: [URL]) -> Island? {
        guard let first = urls.first else { return nil }

        let name = urls.count == 1 ? first.lastPathComponent : Polish.count(urls.count, "plik", "pliki", "plików")

        return Island(
            symbol: airDropSymbol,
            tint: Color(red: 0.35, green: 0.68, blue: 1),
            title: "AirDrop",
            detail: name,
            action: IslandAction(title: "Pokaż") {
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            },
            // Long enough to reach the button.
            duration: 5,
            cat: .peek
        )
    }
}
