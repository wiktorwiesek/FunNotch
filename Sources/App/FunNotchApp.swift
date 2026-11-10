//
//  FunNotchApp.swift
//  FunNotch
//
//  Entry point. The app is an accessory (no Dock icon); everything lives in the
//  notch panel and the menu bar item.
//

import AppKit
import SwiftUI

@main
enum FunNotchApp {
    static var delegate: AppDelegate?

    static func main() {
        // Started by the app itself to read the text out of an image
        // (see TextRecognition): no window, no managers, in and out.
        if TextRecognition.isWorker { TextRecognition.runWorker() }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = Settings.shared

        // Snapshot mode renders each notch state to disk and exits.
        if let directory = PreviewRenderer.requestedDirectory() {
            PreviewRenderer.run(into: directory)
            return
        }

        // Film mode renders the notch frame by frame for a video and exits.
        if let directory = FilmRenderer.requestedDirectory() {
            FilmRenderer.run(into: directory)
            return
        }

        // Hang harness hosts the open notch offscreen and measures the main
        // thread (see HangHarness.swift). Refuses to run on the real app.
        if HangHarness.isRequested {
            HangHarness.run()
            return
        }

        if let path = SelfTest.fileToCheck {
            SelfTest.checkFile(path)
            return
        }

        if SelfTest.isRequested {
            SelfTest.run()
            return
        }

        if SelfTest.diagnosticsRequested {
            SelfTest.printDiagnostics()
            return
        }

        // Managers that observe the system start before the windows so the very
        // first render already has real data in it.
        // Before the pollers, so they can back off from their first tick.
        SystemActivityMonitor.shared.start()
        MusicManager.shared.start()
        BatteryManager.shared.start()
        CalendarManager.shared.start()
        FullscreenMediaDetector.shared.start()
        ScreenshotWatcher.shared.start()
        DownloadWatcher.shared.start()
        ClipboardManager.shared.start()
        UpdateManager.shared.start()
        LoginItemManager.repairRegistration()
        BluetoothMonitor.shared.start()
        AgentSessionsManager.shared.start()

        NotchWindowManager.shared.start()
        // After the windows: the HUD broadcasts to them.
        HUDManager.shared.start()
        // Features added in this build. After the windows, since several of
        // them announce through the notch as soon as they start.
        SystemExtras.start()
        MediaExtras.start()
        ShelfClipExtras.start()
        DevExtras.start()
        NotifyExtras.start()
        WindowSnap.start()
        DecorExtras.start()
        LockScreenExtras.start()

        statusBar = StatusBarController()
        statusBar?.refreshVisibility()

        LoginItemManager.syncWithSettings()

        if !settings.hasCompletedOnboarding {
            settings.hasCompletedOnboarding = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                NotchWindowManager.shared.activeViewModel?.open()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A banner's window moved away must not stay there without the app.
        NotificationBannerWatcher.shared.releaseBanners()
        MouseTracker.shared.stop()
        WebcamManager.shared.stop()
        // A note typed in the last second is still waiting on its debounce.
        NotesManager.current?.flushPendingSave()
    }

    /// Reopening from Finder or a second launch just shows the settings window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return true
    }

    /// `open -a FunNotch plik…` from a terminal or a script puts the files on
    /// the shelf. (No document types are declared, so Finder does not offer
    /// Fun Notch under "Open With"; an explicit `-a` needs none.)
    func application(_ application: NSApplication, open urls: [URL]) {
        let added = urls.filter { $0.isFileURL && ShelfManager.shared.add(url: $0) }
        guard let first = added.first else { return }
        DiagnosticLog.write("shelf", "added \(added.count) file(s) handed over by open")
        let name = added.count == 1
            ? first.lastPathComponent
            : Polish.count(added.count, "plik", "pliki", "plików")
        IslandCenter.shared.post(Island(
            symbol: "tray.and.arrow.down.fill", tint: Color(red: 0.35, green: 0.68, blue: 1),
            title: "Półka", detail: name, duration: 3, cat: .peek
        ))
    }
}
