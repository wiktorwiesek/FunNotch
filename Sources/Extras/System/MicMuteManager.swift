//
//  MicMuteManager.swift
//  FunNotch
//
//  Mutes the default input device for the whole system, not for one app: the
//  device's own mute control when it has one, otherwise its input volume
//  taken to zero with the old level remembered so unmuting puts it back.
//  Both are CoreAudio device properties, so a change made anywhere — here,
//  System Settings, a headset's button — arrives as a callback. When the
//  default input changes (headset plugged in) the manager follows it.
//

import AppKit
import CoreAudio
import Foundation
import SwiftUI

@MainActor
final class MicMuteManager: ObservableObject {
    static let shared = MicMuteManager()

    static let announceKey = "extras.system.mic.announce"
    /// Input volumes taken to zero by us, so they survive a restart while muted.
    private static let savedVolumesKey = "extras.system.mic.savedVolumes"

    @Published private(set) var isMuted = false
    /// False when the default input has neither a mute switch nor a volume
    /// control (some USB and aggregate devices).
    @Published private(set) var isSupported = false
    @Published private(set) var deviceName: String?

    private struct Control {
        enum Kind { case mute, volume }
        var kind: Kind
        var elements: [AudioObjectPropertyElement]
    }

    private let inputScope = kAudioDevicePropertyScopeInput
    private let systemObserver = AudioPropertyObserver()
    private let deviceObserver = AudioPropertyObserver()
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var control: Control?
    private var started = false

    private init() {
        UserDefaults.standard.register(defaults: [Self.announceKey: true])
    }

    /// Safe to call repeatedly: listeners are installed once.
    func start() {
        guard !started else { return }
        started = true
        systemObserver.add(AudioObjects.system, kAudioHardwarePropertyDefaultInputDevice) { [weak self] in
            self?.attach()
        }
        attach()
    }

    // MARK: Following the default input

    private func attach() {
        deviceObserver.removeAll()
        device = AudioObjects.defaultInput()
        guard device != AudioObjectID(kAudioObjectUnknown) else {
            control = nil
            deviceName = nil
            isSupported = false
            isMuted = false
            return
        }
        deviceName = AudioObjects.name(of: device)
        control = findControl()

        // Watch every control the device might change, not only the one we use.
        let elements = [kAudioObjectPropertyElementMain] + Array(1 ... 8)
        for element in elements {
            for selector in [kAudioDevicePropertyMute, kAudioDevicePropertyVolumeScalar]
                where AudioObjects.has(device, selector, scope: inputScope, element: element) {
                deviceObserver.add(device, selector, scope: inputScope, element: element) { [weak self] in
                    self?.refresh()
                }
            }
        }
        refresh()
    }

    /// A mute switch wins over a volume control; the main element wins over
    /// per-channel ones.
    private func findControl() -> Control? {
        let channels = Array<AudioObjectPropertyElement>(1 ... 8)
        for (kind, selector) in [(Control.Kind.mute, kAudioDevicePropertyMute), (.volume, kAudioDevicePropertyVolumeScalar)] {
            if AudioObjects.isSettable(device, selector, scope: inputScope, element: kAudioObjectPropertyElementMain) {
                return Control(kind: kind, elements: [kAudioObjectPropertyElementMain])
            }
            let settable = channels.filter {
                AudioObjects.isSettable(device, selector, scope: inputScope, element: $0)
            }
            if !settable.isEmpty { return Control(kind: kind, elements: settable) }
        }
        return nil
    }

    private func refresh() {
        guard let control else {
            isSupported = false
            isMuted = false
            return
        }
        isSupported = true
        let muted: Bool
        switch control.kind {
        case .mute:
            muted = control.elements.allSatisfy {
                (AudioObjects.value(device, kAudioDevicePropertyMute, scope: inputScope, element: $0, as: UInt32.self) ?? 0) != 0
            }
        case .volume:
            muted = control.elements.allSatisfy {
                (AudioObjects.value(device, kAudioDevicePropertyVolumeScalar, scope: inputScope, element: $0, as: Float32.self) ?? 1) <= 0.0001
            }
        }
        if muted != isMuted { isMuted = muted }
    }

    // MARK: Control

    func toggle() {
        setMuted(!isMuted)
    }

    func setMuted(_ muted: Bool) {
        // The default input may have changed since the last callback.
        if device != AudioObjects.defaultInput() { attach() }
        guard let control else {
            IslandCenter.shared.post(Island(
                symbol: "mic.slash", tint: .orange, title: "Mikrofon",
                detail: " · nie da się wyciszyć tego urządzenia", duration: 3
            ))
            return
        }

        var succeeded = true
        switch control.kind {
        case .mute:
            for element in control.elements {
                succeeded = AudioObjects.set(
                    device, kAudioDevicePropertyMute, to: UInt32(muted ? 1 : 0), scope: inputScope, element: element
                ) && succeeded
            }
        case .volume:
            succeeded = setVolumeMuted(muted, control: control)
        }
        refresh()

        guard succeeded else {
            DiagnosticLog.write("mic", "could not change mute on \(deviceName ?? "input")")
            IslandCenter.shared.post(Island(
                symbol: "mic.slash", tint: .orange, title: "Mikrofon", detail: " · nie udało się zmienić", duration: 3
            ))
            return
        }
        announce(muted: muted)
    }

    private func setVolumeMuted(_ muted: Bool, control: Control) -> Bool {
        let uid = AudioObjects.uid(of: device) ?? "device\(device)"
        var saved = UserDefaults.standard.dictionary(forKey: Self.savedVolumesKey) as? [String: Double] ?? [:]
        var succeeded = true

        for element in control.elements {
            let key = "\(uid)#\(element)"
            if muted {
                let current = AudioObjects.value(
                    device, kAudioDevicePropertyVolumeScalar, scope: inputScope, element: element, as: Float32.self
                ) ?? 1
                // Remember only a real level: muting twice must not save zero.
                if current > 0.0001 { saved[key] = Double(current) }
                succeeded = AudioObjects.set(
                    device, kAudioDevicePropertyVolumeScalar, to: Float32(0), scope: inputScope, element: element
                ) && succeeded
            } else {
                // Nothing remembered (the level was already zero, or the saved
                // value was lost): macOS's usual default, not full gain.
                let restore = Float32(saved[key] ?? 0.75)
                succeeded = AudioObjects.set(
                    device, kAudioDevicePropertyVolumeScalar, to: restore, scope: inputScope, element: element
                ) && succeeded
                saved[key] = nil
            }
        }
        UserDefaults.standard.set(saved, forKey: Self.savedVolumesKey)
        return succeeded
    }

    private func announce(muted: Bool) {
        guard UserDefaults.standard.bool(forKey: Self.announceKey) else { return }
        IslandCenter.shared.post(Island(
            symbol: muted ? "mic.slash.fill" : "mic.fill",
            tint: muted ? Color(red: 1, green: 0.35, blue: 0.32) : .green,
            title: "Mikrofon",
            detail: muted ? " · wyciszony" : " · włączony",
            duration: 2.2
        ))
    }

    var helpText: String {
        guard isSupported else { return "Mikrofon: to urządzenie nie ma regulacji wyciszenia" }
        let device = deviceName.map { " (\($0))" } ?? ""
        return isMuted ? "Mikrofon wyciszony\(device) — kliknij, aby włączyć" : "Mikrofon włączony\(device) — kliknij, aby wyciszyć"
    }
}
