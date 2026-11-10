//
//  CPUTemperatureSensor.swift
//  FunNotch
//
//  CPU temperature on Apple Silicon, read from the thermal sensors that the
//  IOHID event system exposes. There is no public API for this, so every
//  function is looked up with `dlsym` and a single missing symbol turns the
//  feature off (`init` returns nil) rather than crashing.
//
//  The object is created only while a widget that shows the temperature is on
//  screen and closed again afterwards: it holds an IOHID client and a list of
//  service references, which are the only things this feature ever keeps.
//

import Darwin
import Foundation

@MainActor
final class CPUTemperatureSensor {
    private typealias CreateClient = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
    private typealias SetMatching = @convention(c) (UnsafeMutableRawPointer, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
    private typealias CopyEvent = @convention(c) (UnsafeMutableRawPointer, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
    private typealias CopyProperty = @convention(c) (UnsafeMutableRawPointer, CFString) -> UnsafeMutableRawPointer?
    private typealias FloatValue = @convention(c) (UnsafeMutableRawPointer, Int32) -> Double

    /// `kIOHIDEventTypeTemperature`.
    private static let temperatureEventType: Int64 = 15
    /// The temperature field of that event: `type << 16`.
    private static let temperatureField: Int32 = 15 << 16

    private let copyServices: CopyServices
    private let copyEvent: CopyEvent
    private let copyProperty: CopyProperty
    private let floatValue: FloatValue

    /// Owned (+1) by this object until `close()`.
    private var client: UnsafeMutableRawPointer?
    /// Keeps the service references below alive.
    private var servicesArray: CFArray?
    /// The sensors worth reading, and whether they were picked by name (average)
    /// or are simply every temperature sensor (maximum).
    private var sensors: [UnsafeMutableRawPointer] = []
    private var sensorsAreNamedCPU = false
    private var didDiscover = false

    init?() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let createSymbol = dlsym(handle, "IOHIDEventSystemClientCreate"),
              let matchingSymbol = dlsym(handle, "IOHIDEventSystemClientSetMatching"),
              let servicesSymbol = dlsym(handle, "IOHIDEventSystemClientCopyServices"),
              let eventSymbol = dlsym(handle, "IOHIDServiceClientCopyEvent"),
              let propertySymbol = dlsym(handle, "IOHIDServiceClientCopyProperty"),
              let valueSymbol = dlsym(handle, "IOHIDEventGetFloatValue")
        else { return nil }

        let create = unsafeBitCast(createSymbol, to: CreateClient.self)
        let setMatching = unsafeBitCast(matchingSymbol, to: SetMatching.self)
        copyServices = unsafeBitCast(servicesSymbol, to: CopyServices.self)
        copyEvent = unsafeBitCast(eventSymbol, to: CopyEvent.self)
        copyProperty = unsafeBitCast(propertySymbol, to: CopyProperty.self)
        floatValue = unsafeBitCast(valueSymbol, to: FloatValue.self)

        guard let client = create(kCFAllocatorDefault) else { return nil }
        // Vendor usage page 0xff00, usage 5: the temperature sensors.
        let matching: [String: Int] = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5]
        _ = setMatching(client, matching as CFDictionary)
        self.client = client
    }

    /// Releases the IOHID client and everything derived from it.
    func close() {
        sensors = []
        servicesArray = nil
        if let client {
            Unmanaged<AnyObject>.fromOpaque(client).release()
        }
        client = nil
    }

    /// Degrees Celsius, or nil when no usable sensor answered.
    func read() -> Double? {
        guard client != nil else { return nil }
        if !didDiscover { discoverSensors() }
        guard !sensors.isEmpty else { return nil }

        var readings: [Double] = []
        readings.reserveCapacity(sensors.count)
        for service in sensors {
            guard let event = copyEvent(service, Self.temperatureEventType, 0, 0) else { continue }
            let value = floatValue(event, Self.temperatureField)
            Unmanaged<AnyObject>.fromOpaque(event).release()
            // Sensors that are asleep report absurd values such as -127 or 0.
            if value > 0, value <= 130 { readings.append(value) }
        }
        guard !readings.isEmpty else { return nil }

        if sensorsAreNamedCPU {
            return readings.reduce(0, +) / Double(readings.count)
        }
        return readings.max()
    }

    /// The list of services does not change while the app runs, so the names
    /// are inspected once and only the CPU sensors are polled afterwards.
    private func discoverSensors() {
        didDiscover = true
        guard let client, let raw = copyServices(client) else { return }
        let array = Unmanaged<CFArray>.fromOpaque(raw).takeRetainedValue()
        servicesArray = array

        var all: [UnsafeMutableRawPointer] = []
        var named: [UnsafeMutableRawPointer] = []
        for index in 0..<CFArrayGetCount(array) {
            guard let element = CFArrayGetValueAtIndex(array, index) else { continue }
            let service = UnsafeMutableRawPointer(mutating: element)
            all.append(service)
            if isCPUSensor(service) { named.append(service) }
        }

        if named.isEmpty {
            sensors = all
            sensorsAreNamedCPU = false
        } else {
            sensors = named
            sensorsAreNamedCPU = true
        }
    }

    private func isCPUSensor(_ service: UnsafeMutableRawPointer) -> Bool {
        guard let raw = copyProperty(service, "Product" as CFString) else { return false }
        let object = Unmanaged<AnyObject>.fromOpaque(raw).takeRetainedValue()
        guard let name = (object as? String)?.lowercased() else { return false }
        return name.contains("tdie") || name.contains("pacc") || name.contains("eacc")
    }
}
