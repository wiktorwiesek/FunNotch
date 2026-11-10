//
//  SystemExtras.swift
//  FunNotch
//
//  One entry point that starts every system extra. Every manager's `start()`
//  is idempotent, so this is too — views call it again from `onAppear`.
//

import Foundation

@MainActor
enum SystemExtras {
    static func start() {
        KeepAwakeManager.shared.start()
        MicMuteManager.shared.start()
        PrivacyIndicatorManager.shared.start()
        AudioOutputManager.shared.start()
        CapsLockWatcher.shared.start()
        BatteryAlertWatcher.shared.start()
        VolumeMountWatcher.shared.start()
    }
}
