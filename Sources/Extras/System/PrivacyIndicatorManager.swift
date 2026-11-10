//
//  PrivacyIndicatorManager.swift
//  FunNotch
//
//  Says when the camera, the microphone or the screen is in use by any app,
//  the way the dots in the menu bar do. None needs a permission and all
//  arrive as callbacks, so nothing polls:
//    · camera     CoreMediaIO  kCMIODevicePropertyDeviceIsRunningSomewhere
//    · microphone CoreAudio    kAudioProcessPropertyIsRunningInput, per client
//                              process (not the device-level "running somewhere",
//                              which a headset also reports while it only plays)
//    · screen     the window server's "screen watcher" events (see ScreenWatcher)
//  Devices and audio clients come and go, so those lists are watched too and the
//  per-object listeners are rebuilt when they change.
//

import AppKit
import CoreAudio
import CoreMediaIO
import Foundation
import SwiftUI

@MainActor
final class PrivacyIndicatorManager: ObservableObject {
    static let shared = PrivacyIndicatorManager()

    static let announceKey = "extras.system.privacy.announce"

    @Published private(set) var cameraActive = false
    @Published private(set) var microphoneActive = false
    /// Something is recording or sharing the screen.
    @Published private(set) var screenActive = false
    /// Names of the devices currently in use, for tooltips.
    @Published private(set) var cameraNames: [String] = []
    @Published private(set) var microphoneNames: [String] = []

    private let audioObserver = AudioPropertyObserver()
    private let audioListObserver = AudioPropertyObserver()
    private var cameraListeners: [CameraListener] = []
    private var cameraListListener: CameraListener?
    private var started = false
    private var pendingAnnouncement: Task<Void, Never>?
    private var pendingCamera = false
    private var pendingMicrophone = false
    /// Set after the first read so devices already in use at launch stay quiet.
    private var hasBaseline = false

    private init() {
        UserDefaults.standard.register(defaults: [Self.announceKey: true])
    }

    /// Safe to call repeatedly: listeners are installed once.
    func start() {
        guard !started else { return }
        started = true

        // Clients appear and disappear as apps open audio, so the per-process
        // listeners follow the process list.
        audioListObserver.add(AudioObjects.system, kAudioHardwarePropertyProcessObjectList) { [weak self] in
            self?.rebuildAudioListeners()
        }
        rebuildAudioListeners()

        cameraListListener = CameraListener(
            object: CMIOObjectID(kCMIOObjectSystemObject),
            selector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices)
        ) { [weak self] in
            self?.rebuildCameraListeners()
        }
        rebuildCameraListeners()

        // What is already being recorded at launch is not news.
        screenActive = ScreenWatcher.isPresent
        ScreenWatcher.observe()

        hasBaseline = true
    }

    // MARK: Microphone

    private func rebuildAudioListeners() {
        audioObserver.removeAll()
        for process in AudioObjects.processObjects() {
            audioObserver.add(process, kAudioProcessPropertyIsRunningInput) { [weak self] in
                self?.refreshMicrophone()
            }
        }
        refreshMicrophone()
    }

    /// System daemons that keep the microphone open all the time (the "Hey Siri"
    /// hotword listener) and are not something the menu bar's orange dot reports
    /// either. Without this the indicator would be lit permanently.
    private static let ignoredAudioClients: Set<String> = ["com.apple.CoreSpeech"]

    private func refreshMicrophone() {
        // Our own tap aggregate reads as an input stream; it is not a microphone.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var active = false
        var names: [String] = []
        for process in AudioObjects.processObjects() {
            guard (AudioObjects.value(process, kAudioProcessPropertyIsRunningInput, as: UInt32.self) ?? 0) != 0 else { continue }
            if AudioObjects.value(process, kAudioProcessPropertyPID, as: pid_t.self) == ownPID { continue }
            if let bundleID = AudioObjects.string(process, kAudioProcessPropertyBundleID),
               Self.ignoredAudioClients.contains(bundleID) { continue }
            active = true
            let devices = AudioObjects.objectIDs(process, kAudioProcessPropertyDevices, scope: kAudioDevicePropertyScopeInput)
            for device in devices where !AudioObjects.isOwnAggregate(device)
                && AudioObjects.hasStreams(device, scope: kAudioDevicePropertyScopeInput) {
                let name = AudioObjects.name(of: device)
                if !names.contains(name) { names.append(name) }
            }
        }
        if active, names.isEmpty {
            names = [AudioObjects.name(of: AudioObjects.defaultInput())]
        }
        update(microphone: active, names: names)
    }

    // MARK: Camera

    private func rebuildCameraListeners() {
        cameraListeners.removeAll()
        for device in Self.videoDevices() {
            cameraListeners.append(CameraListener(
                object: device,
                selector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)
            ) { [weak self] in
                self?.refreshCamera()
            })
        }
        refreshCamera()
    }

    private func refreshCamera() {
        let running = Self.videoDevices().filter { Self.isRunning($0) }
        update(camera: !running.isEmpty, names: running.map { Self.name(of: $0) })
    }

    private static func videoDevices() -> [CMIOObjectID] {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0
        else { return [] }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &used, &devices
        ) == noErr else { return [] }
        return devices
    }

    private static func isRunning(_ device: CMIOObjectID) -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        guard CMIOObjectHasProperty(device, &address) else { return false }
        var value: UInt32 = 0
        var used: UInt32 = 0
        let status = CMIOObjectGetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value)
        return status == noErr && value != 0
    }

    private static func name(of device: CMIOObjectID) -> String {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOObjectPropertyName),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var result: Unmanaged<CFString>?
        var used: UInt32 = 0
        let status = CMIOObjectGetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<Unmanaged<CFString>?>.size), &used, &result
        )
        guard status == noErr, let result else { return "Kamera" }
        return result.takeRetainedValue() as String
    }

    // MARK: Publishing

    private func update(camera: Bool? = nil, microphone: Bool? = nil, names: [String]) {
        var cameraStarted = false
        var microphoneStarted = false
        if let camera {
            cameraStarted = camera && !cameraActive
            cameraActive = camera
            cameraNames = names
        }
        if let microphone {
            microphoneStarted = microphone && !microphoneActive
            microphoneActive = microphone
            microphoneNames = names
        }
        guard hasBaseline, cameraStarted || microphoneStarted else { return }
        announce(camera: cameraStarted, microphone: microphoneStarted)
    }

    /// A video call starts the camera and microphone within a moment of each
    /// other; collecting what started for a beat turns two islands into one.
    private func announce(camera: Bool, microphone: Bool) {
        guard UserDefaults.standard.bool(forKey: Self.announceKey) else { return }
        pendingCamera = pendingCamera || camera
        pendingMicrophone = pendingMicrophone || microphone
        pendingAnnouncement?.cancel()
        pendingAnnouncement = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self else { return }
            // Something that already stopped again is not worth announcing.
            // The camera mirror is ours and the user just asked for it.
            let camera = self.pendingCamera && self.cameraActive && !WebcamManager.shared.isRunning
            let microphone = self.pendingMicrophone && self.microphoneActive
            self.pendingCamera = false
            self.pendingMicrophone = false
            self.post(camera: camera, microphone: microphone)
        }
    }

    private func post(camera: Bool, microphone: Bool) {
        let island: Island
        switch (camera, microphone) {
        case (true, true):
            island = Island(symbol: "video.fill", tint: .green, title: "Kamera i mikrofon", detail: "w użyciu", duration: 3)
        case (true, false):
            island = Island(symbol: "video.fill", tint: .green, title: "Kamera", detail: "w użyciu", duration: 3)
        case (false, true):
            island = Island(symbol: "mic.fill", tint: .orange, title: "Mikrofon", detail: "w użyciu", duration: 3)
        case (false, false):
            return
        }
        IslandCenter.shared.post(island)
    }

    // MARK: Screen

    private var pendingScreen: Task<Void, Never>?

    /// Called when something starts or stops watching the screen.
    fileprivate func refreshScreen() {
        let active = ScreenWatcher.isPresent
        guard active != screenActive else { return }
        screenActive = active
        DiagnosticLog.write("privacy", active ? "screen is being recorded or shared" : "screen is no longer watched")
        pendingScreen?.cancel()
        guard active, hasBaseline, UserDefaults.standard.bool(forKey: Self.announceKey) else { return }
        // A screenshot watches the screen for an instant; only something
        // that goes on doing it is worth saying.
        pendingScreen = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, let self, self.screenActive else { return }
            IslandCenter.shared.post(Island(
                symbol: "record.circle.fill", tint: .purple,
                title: "Ekran", detail: "jest nagrywany lub udostępniany", duration: 3
            ))
        }
    }

    var helpText: String {
        var lines: [String] = []
        if cameraActive { lines.append("Kamera w użyciu: " + cameraNames.joined(separator: ", ")) }
        if microphoneActive { lines.append("Mikrofon w użyciu: " + microphoneNames.joined(separator: ", ")) }
        if screenActive { lines.append("Ekran jest nagrywany lub udostępniany") }
        return lines.isEmpty ? "Kamera, mikrofon i ekran nie są używane" : lines.joined(separator: "\n")
    }
}

/// Whether anything is capturing the screen, from the window server itself.
///
/// There is no public way to learn this without the Screen Recording
/// permission (and then only by asking over and over). The window server does
/// keep the answer, and announces every change of it; both are reached here by
/// name, so that a system without them simply never reports a recording.
private enum ScreenWatcher {
    private typealias IsPresent = @convention(c) () -> Bool
    private typealias Callback = @convention(c) (Int32, Int32, Int32, UnsafeMutableRawPointer?) -> Void
    private typealias Register = @convention(c) (Callback, Int32, UnsafeMutableRawPointer?) -> Int32

    private static let handle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
    private static let isPresentSymbol = dlsym(handle, "CGSIsScreenWatcherPresent")

    static var isPresent: Bool {
        guard let isPresentSymbol else { return false }
        return unsafeBitCast(isPresentSymbol, to: IsPresent.self)()
    }

    /// A watcher connected (1502) or went away (1503).
    private static let events: [Int32] = [1502, 1503]

    @MainActor private static var observing = false

    @MainActor
    static func observe() {
        guard !observing, isPresentSymbol != nil, let symbol = dlsym(handle, "CGSRegisterNotifyProc") else { return }
        observing = true
        let register = unsafeBitCast(symbol, to: Register.self)
        let callback: Callback = { _, _, _, _ in
            // The window server calls on the main thread's run loop, but says
            // so nowhere: hop rather than assume.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { PrivacyIndicatorManager.shared.refreshScreen() }
            }
        }
        for event in events { _ = register(callback, event, nil) }
    }
}

/// One CoreMediaIO property listener, removed when it goes away.
@MainActor
private final class CameraListener {
    private let object: CMIOObjectID
    private var address: CMIOObjectPropertyAddress
    private let block: CMIOObjectPropertyListenerBlock

    init(object: CMIOObjectID, selector: CMIOObjectPropertySelector, handler: @escaping @MainActor () -> Void) {
        self.object = object
        address = CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        block = { @Sendable _, _ in
            MainActor.assumeIsolated { handler() }
        }
        CMIOObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block)
    }

    deinit {
        var address = address
        CMIOObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
    }
}
