//
//  ExtrasPage.swift
//  FunNotch
//
//  Settings for everything added in this build on top of Fun Notch 1.3: the
//  system toggles, lyrics and the mixer, the local API and dev tiles, shelf
//  and clipboard actions, window snapping, the notification mirror, the
//  decorations and the tools. Each feature owns its section.
//

import SwiftUI

struct ExtrasPage: View {
    var body: some View {
        SettingsPage(
            title: SettingsTab.extras.title,
            subtitle: "Funkcje dodane w tej wersji Fun Notch.",
            symbol: SettingsTab.extras.symbol,
            tint: SettingsTab.extras.tint
        ) {
            SystemExtrasSettings()
            MediaExtrasSettings()
            ShelfClipExtrasSettings()
            DevExtrasSettings()
            NotifyExtrasSettings()
            WindowSnapSettings()
            DecorSettings()
            // A view builder takes ten views; the newer sections share one.
            Group {
                GestureSettings()
                TerminalSettings()
                TeleprompterSettings()
                ScreenAssistantSettings()
            }
        }
    }
}
