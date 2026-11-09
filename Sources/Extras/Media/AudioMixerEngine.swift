//
//  AudioMixerEngine.swift
//  FunNotch
//
//  The audio-thread half of the mixer: gain with a ramp, a three-band EQ and a
//  soft limiter, applied to the audio a process tap hands over and written to
//  the output device. Nothing here allocates, locks or touches an object with
//  reference counting while rendering.
//

import CoreAudio
import Foundation

/// One biquad section in transposed-form-free direct form I, normalised so
/// `a0 == 1`. Coefficients follow the Audio EQ Cookbook.
struct BiquadCoefficients {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0

    static let identity = BiquadCoefficients()

    private init(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) {
        self.b0 = b0 / a0
        self.b1 = b1 / a0
        self.b2 = b2 / a0
        self.a1 = a1 / a0
        self.a2 = a2 / a0
    }

    private init() {}

    static func lowShelf(frequency: Double, gainDB: Double, sampleRate: Double) -> BiquadCoefficients {
        guard abs(gainDB) > 0.01 else { return .identity }
        let a = pow(10, gainDB / 40)
        let w = 2 * Double.pi * frequency / sampleRate
        let cosw = cos(w)
        let alpha = sin(w) / 2 * 2.0.squareRoot()
        let root = 2 * a.squareRoot() * alpha
        return BiquadCoefficients(
            b0: a * ((a + 1) - (a - 1) * cosw + root),
            b1: 2 * a * ((a - 1) - (a + 1) * cosw),
            b2: a * ((a + 1) - (a - 1) * cosw - root),
            a0: (a + 1) + (a - 1) * cosw + root,
            a1: -2 * ((a - 1) + (a + 1) * cosw),
            a2: (a + 1) + (a - 1) * cosw - root
        )
    }

    static func highShelf(frequency: Double, gainDB: Double, sampleRate: Double) -> BiquadCoefficients {
        guard abs(gainDB) > 0.01 else { return .identity }
        let a = pow(10, gainDB / 40)
        let w = 2 * Double.pi * frequency / sampleRate
        let cosw = cos(w)
        let alpha = sin(w) / 2 * 2.0.squareRoot()
        let root = 2 * a.squareRoot() * alpha
        return BiquadCoefficients(
            b0: a * ((a + 1) + (a - 1) * cosw + root),
            b1: -2 * a * ((a - 1) + (a + 1) * cosw),
            b2: a * ((a + 1) + (a - 1) * cosw - root),
            a0: (a + 1) - (a - 1) * cosw + root,
            a1: 2 * ((a - 1) - (a + 1) * cosw),
            a2: (a + 1) - (a - 1) * cosw - root
        )
    }

    static func peaking(frequency: Double, gainDB: Double, q: Double, sampleRate: Double) -> BiquadCoefficients {
        guard abs(gainDB) > 0.01 else { return .identity }
        let a = pow(10, gainDB / 40)
        let w = 2 * Double.pi * frequency / sampleRate
        let cosw = cos(w)
        let alpha = sin(w) / (2 * q)
        return BiquadCoefficients(
            b0: 1 + alpha * a, b1: -2 * cosw, b2: 1 - alpha * a,
            a0: 1 + alpha / a, a1: -2 * cosw, a2: 1 - alpha / a
        )
    }
}

/// What the audio thread reads. The main thread writes the four parameters;
/// aligned 32-bit stores are atomic on arm64 and x86-64, and a parameter seen
/// one buffer late is inaudible, so there is no lock.
final class MixerRenderState: @unchecked Sendable {
    static let maxChannels = 8
    private static let sections = 3
    /// Per channel and section: x1, x2, y1, y2.
    private static let stateStride = 4

    // Written by the main thread.
    private let parameters: UnsafeMutablePointer<Float>
    // Written by the audio thread, read by the main thread.
    private let peak: UnsafeMutablePointer<Float>

    // Audio thread only.
    private let history: UnsafeMutablePointer<Double>
    private let coefficients: UnsafeMutablePointer<BiquadCoefficients>
    private let outPointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    private let outStrides: UnsafeMutablePointer<Int>
    private let inPointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    private let inStrides: UnsafeMutablePointer<Int>
    private var currentGain: Float = 1
    private var isPrimed = false
    private var appliedEQ: (Float, Float, Float) = (0, 0, 0)
    private var eqActive = false

    private let sampleRate: Double
    private let skipInputBuffers: Int

    init(sampleRate: Double, skipInputBuffers: Int) {
        self.sampleRate = sampleRate
        self.skipInputBuffers = skipInputBuffers
        parameters = .allocate(capacity: 4)
        parameters.initialize(repeating: 0, count: 4)
        parameters[0] = 1
        peak = .allocate(capacity: 1)
        peak.initialize(to: 0)
        let historyCount = Self.maxChannels * Self.sections * Self.stateStride
        history = .allocate(capacity: historyCount)
        history.initialize(repeating: 0, count: historyCount)
        coefficients = .allocate(capacity: Self.sections)
        coefficients.initialize(repeating: .identity, count: Self.sections)
        outPointers = .allocate(capacity: Self.maxChannels)
        outPointers.initialize(repeating: nil, count: Self.maxChannels)
        outStrides = .allocate(capacity: Self.maxChannels)
        outStrides.initialize(repeating: 1, count: Self.maxChannels)
        inPointers = .allocate(capacity: Self.maxChannels)
        inPointers.initialize(repeating: nil, count: Self.maxChannels)
        inStrides = .allocate(capacity: Self.maxChannels)
        inStrides.initialize(repeating: 1, count: Self.maxChannels)
    }

    deinit {
        parameters.deallocate()
        peak.deallocate()
        history.deallocate()
        coefficients.deallocate()
        outPointers.deallocate()
        outStrides.deallocate()
        inPointers.deallocate()
        inStrides.deallocate()
    }

    // MARK: Main thread

    /// `gain` is linear (0 is silence), the EQ gains are in decibels.
    func update(gain: Float, bassDB: Float, midDB: Float, trebleDB: Float) {
        parameters[0] = gain
        parameters[1] = bassDB
        parameters[2] = midDB
        parameters[3] = trebleDB
    }

    /// Loudest input sample since the last call, then reset. Zero for a while
    /// while an app is playing means the tap is getting nothing.
    func takePeak() -> Float {
        let value = peak.pointee
        peak.pointee = 0
        return value
    }

    // MARK: Audio thread

    func render(input: UnsafeMutableAudioBufferListPointer, output: UnsafeMutableAudioBufferListPointer) {
        let source = gatherPlanes(
            input, skippingLeading: skipInputBuffers,
            into: inPointers, strides: inStrides, capacity: Self.maxChannels
        )
        let destination = gatherPlanes(
            output, skippingLeading: 0,
            into: outPointers, strides: outStrides, capacity: Self.maxChannels
        )
        let frames = min(source.frames, destination.frames)

        // Always fill the output; leaving it alone would replay old samples.
        guard source.count > 0, frames > 0 else {
            silence(output)
            return
        }

        let targetGain = max(parameters[0], 0)
        let bass = parameters[1], mid = parameters[2], treble = parameters[3]
        updateEQ(bass, mid, treble)

        // The first buffer starts at the target, or a quiet setting would open
        // with a one-buffer blast at full level.
        if !isPrimed {
            currentGain = targetGain
            isPrimed = true
        }
        let startGain = currentGain
        let step = (targetGain - startGain) / Float(frames)
        // Boosting can push past full scale; a soft knee beats hard clipping.
        let limit = targetGain > 1 || startGain > 1 || bass > 0 || mid > 0 || treble > 0
        var inputPeak: Float = 0

        for channel in 0 ..< destination.count {
            guard let out = outPointers[channel] else { continue }
            let outStride = outStrides[channel]

            // A tap with fewer channels than the output feeds only the ones it
            // has, apart from mono, which goes everywhere.
            let sourceChannel = channel < source.count ? channel : (source.count == 1 ? 0 : -1)
            guard sourceChannel >= 0, let input = inPointers[sourceChannel] else {
                for frame in 0 ..< frames { out[frame * outStride] = 0 }
                continue
            }
            let inStride = inStrides[sourceChannel]
            let state = history + (min(channel, Self.maxChannels - 1) * Self.sections * Self.stateStride)

            var gain = startGain
            for frame in 0 ..< frames {
                var sample = input[frame * inStride]
                inputPeak = max(inputPeak, abs(sample))
                if eqActive {
                    var value = Double(sample)
                    for section in 0 ..< Self.sections {
                        value = Self.biquad(value, coefficients[section], state + section * Self.stateStride)
                    }
                    sample = Float(value)
                }
                sample *= gain
                gain += step
                out[frame * outStride] = limit ? Self.softClip(sample) : sample
            }
        }
        currentGain = targetGain
        if inputPeak > peak.pointee { peak.pointee = inputPeak }
    }

    private func silence(_ list: UnsafeMutableAudioBufferListPointer) {
        for buffer in list {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
    }

    /// Recomputes the filters only when a band moved.
    private func updateEQ(_ bass: Float, _ mid: Float, _ treble: Float) {
        guard (bass, mid, treble) != appliedEQ else { return }
        appliedEQ = (bass, mid, treble)
        let wasActive = eqActive
        eqActive = abs(bass) > 0.01 || abs(mid) > 0.01 || abs(treble) > 0.01
        coefficients[0] = .lowShelf(frequency: 120, gainDB: Double(bass), sampleRate: sampleRate)
        coefficients[1] = .peaking(frequency: 1000, gainDB: Double(mid), q: 0.9, sampleRate: sampleRate)
        coefficients[2] = .highShelf(frequency: 6000, gainDB: Double(treble), sampleRate: sampleRate)
        if eqActive, !wasActive {
            // Old history from before the EQ was on would click.
            history.update(repeating: 0, count: Self.maxChannels * Self.sections * Self.stateStride)
        }
    }

    @inline(__always)
    private static func biquad(_ x: Double, _ c: BiquadCoefficients, _ s: UnsafeMutablePointer<Double>) -> Double {
        let y = c.b0 * x + c.b1 * s[0] + c.b2 * s[1] - c.a1 * s[2] - c.a2 * s[3]
        s[1] = s[0]
        s[0] = x
        s[3] = s[2]
        s[2] = y
        return y
    }

    @inline(__always)
    private static func softClip(_ x: Float) -> Float {
        let magnitude = abs(x)
        guard magnitude > 0.8 else { return x }
        let shaped = 0.8 + 0.2 * tanhf((magnitude - 0.8) / 0.2)
        return x < 0 ? -shaped : shaped
    }
}

/// One app's tap, and the settings it is currently playing back with.
@available(macOS 14.2, *)
final class MixerTap {
    let processObjects: [AudioObjectID]
    private let session: AudioTapSession
    private let state: MixerRenderState
    let createdAt = Date()

    init(processObjects: [AudioObjectID], settings: MixerAppSettings) throws {
        self.processObjects = processObjects

        let description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        description.uuid = UUID()
        // Muted: the app no longer reaches the speakers by itself, only through
        // this tap, so what we write is all that is heard.
        description.muteBehavior = .muted

        // The render state needs the tap's sample rate and buffer layout, which
        // exist only once the tap does; the session is created first and not
        // started until the state is in the box the render closure reads.
        let box = StateBox()
        let session = try AudioTapSession(description: description) { input, output in
            box.state?.render(input: input, output: output)
        }
        let state = MixerRenderState(sampleRate: session.sampleRate, skipInputBuffers: session.leadingInputBuffers)
        box.state = state
        self.session = session
        self.state = state
        apply(settings)
        try session.start()
    }

    func apply(_ settings: MixerAppSettings) {
        state.update(
            gain: settings.muted ? 0 : Float(settings.volume),
            bassDB: Float(settings.bass), midDB: Float(settings.mid), trebleDB: Float(settings.treble)
        )
    }

    func takePeak() -> Float { state.takePeak() }

    func stop() { session.stop() }

    /// Carries the render state to the IO proc once it exists.
    private final class StateBox: @unchecked Sendable {
        var state: MixerRenderState?
    }
}
