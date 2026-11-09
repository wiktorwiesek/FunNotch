//
//  PaletteHotKey.swift
//  FunNotch
//
//  ⌃⌥K from any app, through Carbon's RegisterEventHotKey. Unlike an event tap
//  it needs no Accessibility or Input Monitoring permission, and the system
//  swallows the keystroke so the front app never sees it.
//

import Carbon.HIToolbox
import Foundation

@MainActor
final class PaletteHotKey: ObservableObject {
    static let shared = PaletteHotKey()

    enum Status: Equatable {
        case off
        case active
        /// Another app already owns the combination, or the system refused.
        case failed(Int32)
    }

    /// Distinguishes our hot key from those other features register on the
    /// same application event target ("FNPL").
    fileprivate nonisolated static let signature: OSType = 0x464E_504C
    fileprivate nonisolated static let identifier: UInt32 = 1

    @Published private(set) var status: Status = .off

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    private init() {}

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: PaletteDefaults.hotKeyEnabled) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: PaletteDefaults.hotKeyEnabled)
            apply()
        }
    }

    /// Safe to call repeatedly: the key is registered once.
    func start() {
        apply()
    }

    private func apply() {
        if isEnabled {
            register()
        } else {
            unregister()
        }
    }

    private func register() {
        guard hotKey == nil else { return }

        if handler == nil {
            var spec = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            let installed = InstallEventHandler(
                GetApplicationEventTarget(), paletteHotKeyCallback, 1, &spec, nil, &handler
            )
            guard installed == noErr else {
                status = .failed(installed)
                DiagnosticLog.write("palette", "hotkey handler install failed (\(installed))")
                return
            }
        }

        let id = EventHotKeyID(signature: Self.signature, id: Self.identifier)
        let result = RegisterEventHotKey(
            UInt32(kVK_ANSI_K), UInt32(controlKey | optionKey), id,
            GetApplicationEventTarget(), 0, &hotKey
        )
        if result == noErr {
            status = .active
        } else {
            hotKey = nil
            status = .failed(result)
            DiagnosticLog.write("palette", "hotkey ⌃⌥K registration failed (\(result))")
        }
    }

    private func unregister() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        status = .off
    }
}

/// Carbon calls this on the main thread. Events that belong to another hot key
/// are passed on untouched.
private func paletteHotKeyCallback(
    _ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let result = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &id
    )
    guard result == noErr, id.signature == PaletteHotKey.signature, id.id == PaletteHotKey.identifier else {
        return OSStatus(eventNotHandledErr)
    }
    DispatchQueue.main.async {
        MainActor.assumeIsolated { PaletteController.shared.toggle() }
    }
    return noErr
}
