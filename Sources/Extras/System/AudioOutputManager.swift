//
//  AudioOutputManager.swift
//  FunNotch
//
//  Lists the sound outputs and switches the default one — what the sound
//  menu bar item does, minus leaving the notch. Changes made elsewhere
//  (AirPods connecting, System Settings) arrive as property callbacks, and
//  each one is announced.
//

import AppKit
import CoreAudio
import Foundation
import SwiftUI

@MainActor
final class AudioOutputManager: ObservableObject {
    static let shared = AudioOutputManager()

    static let announceKey = "extras.system.audioOutput.announce"

    struct Output: Identifiable, Equatable {
        let id: AudioObjectID
        let name: String
        let symbol: String
    }

    @Published private(set) var outputs: [Output] = []
    @Published private(set) var current: Output?

    private let observer = AudioPropertyObserver()
    private var started = false
    /// The first read at launch is not a change worth announcing.
    private var hasBaseline = false

    private init() {
        UserDefaults.standard.register(defaults: [Self.announceKey: true])
    }

    /// Safe to call repeatedly: listeners are installed once.
    func start() {
        guard !started else { return }
        started = true
        observer.add(AudioObjects.system, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            self?.refresh()
        }
        observer.add(AudioObjects.system, kAudioHardwarePropertyDevices) { [weak self] in
            self?.refresh()
        }
        refresh()
        hasBaseline = true
    }

    private func refresh() {
        let devices = AudioObjects.allDevices().compactMap { device -> Output? in
            guard AudioObjects.hasStreams(device, scope: kAudioDevicePropertyScopeOutput),
                  // Hidden helpers such as multi-output aggregates created by
                  // other apps report that they cannot be the default.
                  (AudioObjects.value(
                      device, kAudioDevicePropertyDeviceCanBeDefaultDevice,
                      scope: kAudioDevicePropertyScopeOutput, as: UInt32.self
                  ) ?? 1) != 0
            else { return nil }
            return Output(id: device, name: AudioObjects.name(of: device), symbol: Self.symbol(for: device))
        }
        if devices != outputs { outputs = devices }

        let defaultID = AudioObjects.defaultOutput()
        let next = devices.first { $0.id == defaultID }
        guard next != current else { return }
        let changed = next?.id != current?.id
        current = next
        if changed, hasBaseline, let next { announce(next) }
    }

    func select(_ output: Output) {
        guard output.id != current?.id else { return }
        // System Settings sets both: the sound-effects device follows the main one.
        let main = AudioObjects.set(AudioObjects.system, kAudioHardwarePropertyDefaultOutputDevice, to: output.id)
        AudioObjects.set(AudioObjects.system, kAudioHardwarePropertyDefaultSystemOutputDevice, to: output.id)
        guard main else {
            DiagnosticLog.write("audio", "could not switch output to \(output.name)")
            IslandCenter.shared.post(Island(
                symbol: "speaker.slash", tint: .orange, title: output.name, detail: " · nie udało się przełączyć", duration: 3
            ))
            return
        }
        refresh()
    }

    func showMenu() {
        refresh()
        guard !outputs.isEmpty else { return }
        PointerMenu.show(outputs.map { output in
            PointerMenu.Item(
                title: output.name, symbol: output.symbol, isChecked: output.id == current?.id
            ) { [weak self] in
                self?.select(output)
            }
        })
    }

    private func announce(_ output: Output) {
        guard UserDefaults.standard.bool(forKey: Self.announceKey) else { return }
        IslandCenter.shared.post(Island(
            symbol: output.symbol, tint: .white, title: output.name, detail: " · wyjście dźwięku", duration: 2.5
        ))
    }

    var helpText: String {
        current.map { "Wyjście dźwięku: \($0.name) — kliknij, aby zmienić" } ?? "Wyjście dźwięku: brak urządzenia"
    }

    // MARK: Icons

    /// A glyph that says what kind of output this is.
    private static func symbol(for device: AudioObjectID) -> String {
        let name = AudioObjects.name(of: device).lowercased()
        let transport = AudioObjects.value(device, kAudioDevicePropertyTransportType, as: UInt32.self) ?? 0

        if name.contains("airpods max") { return "airpodsmax" }
        if name.contains("airpods pro") { return "airpodspro" }
        if name.contains("airpods") { return "airpods" }
        if name.contains("homepod") { return "homepod.fill" }

        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            // The jack and the speakers share one device; its data source says which is in use.
            let source = AudioObjects.value(
                device, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput, as: UInt32.self
            )
            return source == fourCC("hdpn") ? "headphones" : "speaker.wave.2.fill"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "display"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        case kAudioDeviceTransportTypeUSB:
            return name.contains("headset") || name.contains("headphone") || name.contains("słuchaw")
                ? "headphones" : "hifispeaker.fill"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate:
            return "waveform"
        default:
            return "speaker.wave.2"
        }
    }

    private static func fourCC(_ code: String) -> UInt32 {
        code.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
