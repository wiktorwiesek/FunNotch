//
//  SystemExtras.swift
//  FunNotch
//
//  One entry point that starts every system extra and registers their
//  command-palette entries. Every manager's `start()` is idempotent, so this
//  is too — views call it again from `onAppear`.
//

import Foundation

@MainActor
enum SystemExtras {
    private static var paletteRegistered = false

    static func start() {
        KeepAwakeManager.shared.start()
        MicMuteManager.shared.start()
        PrivacyIndicatorManager.shared.start()
        AudioOutputManager.shared.start()
        CapsLockWatcher.shared.start()
        BatteryAlertWatcher.shared.start()
        VolumeMountWatcher.shared.start()
        registerPaletteCommands()
    }

    private static func registerPaletteCommands() {
        guard !paletteRegistered else { return }
        paletteRegistered = true
        let registry = PaletteCommandRegistry.shared

        registry.register(PaletteCommand(
            id: "system.keepAwake.toggle",
            title: "Nie usypiaj Maca",
            subtitle: "Włącz lub wyłącz",
            symbol: "cup.and.saucer.fill",
            keywords: ["caffeine", "kofeina", "sen", "uśpienie", "ekran", "awake", "keep awake"],
            perform: { KeepAwakeManager.shared.toggle() }
        ))
        for choice in KeepAwakeManager.durationChoices where choice.minutes != nil {
            registry.register(PaletteCommand(
                id: "system.keepAwake.\(choice.minutes ?? 0)",
                title: "Nie usypiaj Maca: \(choice.title.lowercased())",
                symbol: "cup.and.saucer.fill",
                keywords: ["caffeine", "kofeina", "sen", "awake"],
                perform: { KeepAwakeManager.shared.activate(minutes: choice.minutes) }
            ))
        }

        registry.register(PaletteCommand(
            id: "system.mic.toggle",
            title: "Wycisz mikrofon",
            subtitle: "Wycisza lub włącza domyślny mikrofon",
            symbol: "mic.slash.fill",
            keywords: ["mikrofon", "mute", "wyciszenie", "mic", "włącz mikrofon"],
            perform: { MicMuteManager.shared.toggle() }
        ))

        registry.register(PaletteCommand(
            id: "system.audioOutput.menu",
            title: "Zmień wyjście dźwięku",
            subtitle: "Głośniki, słuchawki, AirPods",
            symbol: "speaker.wave.2.fill",
            keywords: ["audio", "dźwięk", "głośniki", "słuchawki", "output", "airpods"],
            perform: { AudioOutputManager.shared.showMenu() }
        ))
    }
}
