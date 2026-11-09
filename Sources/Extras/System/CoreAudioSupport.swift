//
//  CoreAudioSupport.swift
//  FunNotch
//
//  The small amount of CoreAudio plumbing the system extras share: typed
//  property reads and writes, and listeners that call back on the main actor.
//  Everything here is property-based, so a change made anywhere on the Mac
//  (System Settings, a headset's own button) reaches us as a callback and
//  nothing has to poll.
//

import AppKit
import CoreAudio
import Foundation

enum AudioObjects {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> Bool {
        var address = address(selector, scope: scope, element: element)
        return AudioObjectHasProperty(object, &address)
    }

    static func isSettable(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> Bool {
        var address = address(selector, scope: scope, element: element)
        guard AudioObjectHasProperty(object, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(object, &address, &settable) == noErr && settable.boolValue
    }

    /// A fixed-size value such as `UInt32`, `Float32` or an object id.
    static func value<T>(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        as type: T.Type
    ) -> T? {
        var address = address(selector, scope: scope, element: element)
        var size = UInt32(MemoryLayout<T>.size)
        let storage = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, storage) == noErr else { return nil }
        return storage.pointee
    }

    @discardableResult
    static func set<T>(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector, to newValue: T,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> Bool {
        var address = address(selector, scope: scope, element: element)
        var copy = newValue
        return AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), &copy) == noErr
    }

    static func objectIDs(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [AudioObjectID] {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func string(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> String? {
        var address = address(selector, scope: scope)
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr else { return nil }
        return result?.takeRetainedValue() as String?
    }

    // MARK: Devices

    static func defaultInput() -> AudioObjectID {
        value(system, kAudioHardwarePropertyDefaultInputDevice, as: AudioObjectID.self) ?? AudioObjectID(kAudioObjectUnknown)
    }

    static func defaultOutput() -> AudioObjectID {
        value(system, kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self) ?? AudioObjectID(kAudioObjectUnknown)
    }

    static func allDevices() -> [AudioObjectID] {
        objectIDs(system, kAudioHardwarePropertyDevices)
    }

    static func name(of device: AudioObjectID) -> String {
        string(device, kAudioObjectPropertyName) ?? "Nieznane urządzenie"
    }

    static func uid(of device: AudioObjectID) -> String? {
        string(device, kAudioDevicePropertyDeviceUID)
    }

    /// True when the device has at least one stream in `scope`.
    static func hasStreams(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    // MARK: Our own tap aggregates

    /// UID prefix of the private aggregate devices `AudioTapSession` creates. They
    /// are visible to this process in the device list, and the tap shows up as an
    /// input stream on them, so anything that lists microphones or outputs has to
    /// skip them or Fun Notch would report itself as "microphone in use".
    static let ownAggregateUIDPrefix = "pl.funnotch.tap."

    static func isOwnAggregate(_ device: AudioObjectID) -> Bool {
        uid(of: device)?.hasPrefix(ownAggregateUIDPrefix) == true
    }

    // MARK: Processes

    /// Audio client processes known to the HAL (macOS 14.0+). Unlike the device
    /// property "running somewhere", they carry a direction, so a headset that is
    /// only playing does not look like a recording microphone.
    static func processObjects() -> [AudioObjectID] {
        objectIDs(system, kAudioHardwarePropertyProcessObjectList)
    }
}

/// Owns a set of CoreAudio property listeners and removes them together. The
/// handlers run on the main queue, so they may touch main-actor state.
@MainActor
final class AudioPropertyObserver {
    private struct Registration {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private var registrations: [Registration] = []

    func add(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        handler: @escaping @MainActor () -> Void
    ) {
        var address = AudioObjects.address(selector, scope: scope, element: element)
        // `@Sendable` so the block does not inherit main-actor isolation: CoreAudio
        // invokes it on the queue we hand it, which is the main queue.
        let block: AudioObjectPropertyListenerBlock = { @Sendable _, _ in
            MainActor.assumeIsolated { handler() }
        }
        guard AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block) == noErr else { return }
        registrations.append(Registration(object: object, address: address, block: block))
    }

    func removeAll() {
        for var registration in registrations {
            AudioObjectRemovePropertyListenerBlock(
                registration.object, &registration.address, DispatchQueue.main, registration.block
            )
        }
        registrations.removeAll()
    }

    deinit {
        // Listeners must not outlive the observer; the block captured nothing
        // that is freed here, but CoreAudio would keep calling a dead handler.
        for var registration in registrations {
            AudioObjectRemovePropertyListenerBlock(
                registration.object, &registration.address, DispatchQueue.main, registration.block
            )
        }
    }
}

/// Opens a small `NSMenu` at the pointer, because the notch panel is not a
/// place SwiftUI's own `Menu` behaves well.
///
/// `NSMenu.popUp` does not return until the menu closes: it runs its own event
/// loop. Called from a button's action, that loop would start inside SwiftUI's
/// event dispatch and graph transaction, with every run-loop observer (SwiftUI's
/// transaction flush among them) still firing around it. So the menu is only
/// built here and shown a turn later, once the action has returned.
@MainActor
enum PointerMenu {
    private final class Target: NSObject {
        let action: @MainActor () -> Void
        init(_ action: @escaping @MainActor () -> Void) { self.action = action }
        @objc func run() { MainActor.assumeIsolated { action() } }
    }

    struct Item {
        var title: String
        var symbol: String?
        var isChecked = false
        var isEnabled = true
        var perform: @MainActor () -> Void
    }

    /// The targets must outlive the menu, which only retains them weakly.
    private static var targets: [Target] = []
    /// A menu is queued or open; a second click on the button meanwhile must
    /// not stack another one behind it.
    private static var isPresenting = false

    static func show(_ items: [Item]) {
        guard !isPresenting else { return }
        isPresenting = true

        let menu = NSMenu()
        menu.autoenablesItems = false
        targets = []
        for item in items {
            let target = Target(item.perform)
            targets.append(target)
            let menuItem = NSMenuItem(title: item.title, action: #selector(Target.run), keyEquivalent: "")
            menuItem.target = target
            menuItem.isEnabled = item.isEnabled
            menuItem.state = item.isChecked ? .on : .off
            if let symbol = item.symbol {
                menuItem.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            }
            menu.addItem(menuItem)
        }

        // Where the pointer is now, not where it will be a turn later.
        let location = NSEvent.mouseLocation
        DispatchQueue.main.async {
            menu.popUp(positioning: nil, at: location, in: nil)
            isPresenting = false
        }
    }
}
