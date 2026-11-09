//
//  AudioTapSession.swift
//  FunNotch
//
//  Core Audio process taps (macOS 14.2+) wrapped as one object: a tap, a
//  private aggregate device that carries it next to the real output device,
//  and an IO proc that receives the tapped audio and fills the output.
//
//  The mixer taps single apps and plays them back changed; the spectrum taps
//  the whole mix and only listens. Both sit on this.
//

import AppKit
import CoreAudio
import Foundation

/// Whether the system lets us record system audio — the permission process taps
/// need. macOS has no public API to ask, so this uses the TCC preflight the
/// system's own tools use, and degrades to `.unknown` when it is not there.
enum AudioCapturePermission {
    enum Status {
        case granted
        case denied
        /// Not asked yet; the prompt appears when a tap first starts.
        case notDetermined
        case unknown
    }

    private typealias PreflightFunction = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunction = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let service = "kTCCServiceAudioCapture" as CFString

    private static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static var status: Status {
        guard let handle, let symbol = dlsym(handle, "TCCAccessPreflight") else { return .unknown }
        let preflight = unsafeBitCast(symbol, to: PreflightFunction.self)
        switch preflight(service, nil) {
        case 0: return .granted
        case 1: return .denied
        case 2: return .notDetermined
        default: return .unknown
        }
    }

    /// Shows the system prompt if the user has not decided yet.
    static func request(_ completion: @escaping @MainActor (Bool) -> Void) {
        guard let handle, let symbol = dlsym(handle, "TCCAccessRequest") else {
            Task { @MainActor in completion(false) }
            return
        }
        let function = unsafeBitCast(symbol, to: RequestFunction.self)
        function(service, nil) { granted in
            Task { @MainActor in completion(granted) }
        }
    }

    static func openSystemSettings() {
        let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }
}

enum AudioTapError: Error, CustomStringConvertible {
    case unsupportedOS
    case noOutputDevice
    case createTap(OSStatus)
    case createAggregate(OSStatus)
    case createIOProc(OSStatus)
    case start(OSStatus)

    var description: String {
        switch self {
        case .unsupportedOS: return "wymaga macOS 14.2"
        case .noOutputDevice: return "brak urządzenia wyjściowego"
        case let .createTap(code): return "nie udało się utworzyć tapa (\(code))"
        case let .createAggregate(code): return "nie udało się utworzyć urządzenia agregującego (\(code))"
        case let .createIOProc(code): return "nie udało się utworzyć procedury audio (\(code))"
        case let .start(code): return "nie udało się uruchomić dźwięku (\(code))"
        }
    }
}

/// Gathers the float channel planes of `list`, starting after `skip` buffers:
/// a headset's microphone, when the output device has one, comes first in the
/// aggregate's input and is not the tap's.
@inline(__always)
func gatherPlanes(
    _ list: UnsafeMutableAudioBufferListPointer,
    skippingLeading skip: Int,
    into pointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>,
    strides: UnsafeMutablePointer<Int>,
    capacity: Int
) -> (count: Int, frames: Int) {
    var count = 0
    var frames = Int.max
    var index = max(skip, 0)
    while index < list.count, count < capacity {
        let buffer = list[index]
        index += 1
        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
        let channels = max(Int(buffer.mNumberChannels), 1)
        let bufferFrames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
        frames = min(frames, bufferFrames)
        var channel = 0
        while channel < channels, count < capacity {
            pointers[count] = data + channel
            strides[count] = channels
            count += 1
            channel += 1
        }
    }
    return (count, frames == Int.max ? 0 : frames)
}

@available(macOS 14.2, *)
final class AudioTapSession {
    typealias Render = (_ input: UnsafeMutableAudioBufferListPointer, _ output: UnsafeMutableAudioBufferListPointer) -> Void

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var isRunning = false

    /// Format of the audio the tap delivers.
    private(set) var format = AudioStreamBasicDescription()
    /// How many buffers of the aggregate's input precede the tap's.
    private(set) var leadingInputBuffers = 0

    var sampleRate: Double { format.mSampleRate > 0 ? format.mSampleRate : 48000 }

    init(description: CATapDescription, render: @escaping Render) throws {
        guard let outputUID = AudioObjects.uid(of: AudioObjects.defaultOutput()) else {
            throw AudioTapError.noOutputDevice
        }

        description.isPrivate = true
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw AudioTapError.createTap(status) }

        do {
            if let tapFormat = AudioObjects.value(tapID, kAudioTapPropertyFormat, as: AudioStreamBasicDescription.self) {
                format = tapFormat
            }

            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Fun Notch audio",
                kAudioAggregateDeviceUIDKey: AudioObjects.ownAggregateUIDPrefix + UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]],
            ]
            status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
            guard status == noErr else { throw AudioTapError.createAggregate(status) }

            // The tap's streams come after any the output device itself has
            // (a headset's microphone), so skip those when reading input.
            leadingInputBuffers = max(Self.inputBufferCount(of: aggregateID) - Self.tapBufferCount(format), 0)

            let queue = DispatchQueue(label: "pl.funnotch.audio-tap", qos: .userInteractive)
            let block = Self.makeBlock(render)
            status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue, block)
            guard status == noErr, let createdProc = procID else { throw AudioTapError.createIOProc(status) }

            // Only the tap's streams are wanted. Leaving the output device's own
            // microphone stream on would make macOS count Fun Notch as recording
            // (and switch a Bluetooth headset to its call profile).
            Self.disableInputStreams(
                of: aggregateID, proc: createdProc,
                total: Self.inputBufferCount(of: aggregateID), leading: leadingInputBuffers
            )

        } catch {
            teardown()
            throw error
        }
    }

    deinit { teardown() }

    /// Separate from `init` so the caller can finish setting up whatever the
    /// render closure uses before the first buffer arrives.
    func start() throws {
        guard let procID, !isRunning else { return }
        let status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            teardown()
            throw AudioTapError.start(status)
        }
        isRunning = true
    }

    func stop() { teardown() }

    private func teardown() {
        if let procID, aggregateID != kAudioObjectUnknown {
            if isRunning { AudioDeviceStop(aggregateID, procID) }
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        isRunning = false
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// Built outside the class body's isolation so the audio thread never
    /// touches an actor.
    private static func makeBlock(_ render: @escaping Render) -> AudioDeviceIOBlock {
        { _, input, _, output, _ in
            render(
                UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)),
                UnsafeMutableAudioBufferListPointer(output)
            )
        }
    }

    private static func tapBufferCount(_ format: AudioStreamBasicDescription) -> Int {
        let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        return planar ? max(Int(format.mChannelsPerFrame), 1) : 1
    }

    /// Turns off the first `leading` input streams of `proc` on `device`; the IO
    /// proc then sees NULL buffers for them, which `gatherPlanes` already skips.
    /// Best effort: a device that refuses just keeps the stream.
    private static func disableInputStreams(
        of device: AudioObjectID, proc: AudioDeviceIOProcID, total: Int, leading: Int
    ) {
        guard leading > 0, total >= leading else { return }
        let flagsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn) ?? 12
        let size = flagsOffset + total * MemoryLayout<UInt32>.size
        let storage = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { storage.deallocate() }
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        let usage = storage.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
        usage.pointee.mIOProc = unsafeBitCast(proc, to: UnsafeMutableRawPointer.self)
        usage.pointee.mNumberStreams = UInt32(total)
        let flags = (storage + flagsOffset).assumingMemoryBound(to: UInt32.self)
        for index in 0..<total { flags[index] = index < leading ? 0 : 1 }

        var address = AudioObjects.address(kAudioDevicePropertyIOProcStreamUsage, scope: kAudioObjectPropertyScopeInput)
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(size), storage)
        if status != noErr {
            DiagnosticLog.write("audio", "could not disable microphone stream on tap device: \(status)")
        }
    }

    private static func inputBufferCount(of device: AudioObjectID) -> Int {
        var address = AudioObjects.address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        return list.count
    }
}
