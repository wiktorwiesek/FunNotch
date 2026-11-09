//
//  FullscreenMediaDetector.swift
//  FunNotch
//
//  Gets the notch out of the way when an app takes over a display. Detected by
//  watching whether the menu bar still reserves space on that screen, which
//  needs no extra permissions.
//

import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class FullscreenMediaDetector: ObservableObject {
    static let shared = FullscreenMediaDetector()

    /// Screen identifiers currently running a fullscreen app.
    @Published private(set) var fullscreenScreens: Set<String> = []

    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    /// Entering or leaving fullscreen always switches Space and activates an
    /// app, so those events drive the check instead of a once-a-second poll.
    /// The slow timer covers what they miss: a menu bar set to hide on its
    /// own, or a display reconfigured without a notification.
    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        Publishers.MergeMany(
            workspace.publisher(for: NSWorkspace.activeSpaceDidChangeNotification),
            workspace.publisher(for: NSWorkspace.didActivateApplicationNotification),
            NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
        )
        // The menu bar finishes hiding a moment after the Space switches.
        .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
        .sink { [weak self] _ in self?.evaluate() }
        .store(in: &cancellables)

        // "Only while music plays" changes with the music, not the screen.
        MusicManager.shared.$track
            .map(\.isPlaying)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.evaluate() }
            .store(in: &cancellables)

        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            guard !SystemActivityMonitor.isScreenIdle else { return }
            MainActor.assumeIsolated { self?.evaluate() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        evaluate()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        cancellables.removeAll()
    }

    private func evaluate() {
        var fullscreen: Set<String> = []
        for screen in NSScreen.screens {
            // In fullscreen the menu bar auto-hides, so the visible frame
            // reaches all the way to the top of the display.
            let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
            if menuBarHeight < 1 {
                fullscreen.insert(screen.displayIdentifier)
            }
        }

        if fullscreen != fullscreenScreens {
            fullscreenScreens = fullscreen
        }

        let option = Settings.shared.hideNotchOption
        let musicPlaying = MusicManager.shared.isPlaying
        for viewModel in NotchWindowManager.shared.viewModels {
            let isFullscreen = fullscreen.contains(viewModel.screenIdentifier)

            let shouldHide: Bool
            switch option {
            case .never:
                shouldHide = false
            case .always:
                shouldHide = isFullscreen
            case .nowPlayingOnly:
                shouldHide = isFullscreen && musicPlaying
            }

            if viewModel.hiddenForFullscreen != shouldHide {
                if shouldHide { viewModel.close() }
                viewModel.hiddenForFullscreen = shouldHide
            }
        }
    }
}
