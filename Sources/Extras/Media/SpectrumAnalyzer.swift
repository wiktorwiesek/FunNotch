//
//  SpectrumAnalyzer.swift
//  FunNotch
//
//  A real spectrum for the music visualiser: a global process tap on the
//  system output, a Hann-windowed FFT with Accelerate, folded into the four
//  bars. It runs only while a visualiser is on screen and something is
//  playing, and it only listens — nothing is muted or changed.
//
//  When the tap is unavailable (older macOS, permission refused, a failed
//  device) or hears only silence, `level(_:)` returns nil and the visualiser
//  keeps its synthetic animation.
//

import Accelerate
import AppKit
import Combine
import CoreAudio
import Foundation

/// The audio-thread half: gathers samples, runs the FFT, writes four levels.
final class SpectrumRenderState: @unchecked Sendable {
    static let barCount = 4
    private static let fftSize = 2048
    private static let hop = 1024
    private static let log2Size = vDSP_Length(11)
    /// Band edges in Hz, one bar per pair. Roughly bass, low mid, high mid, treble.
    private static let edges: [Double] = [40, 200, 800, 3200, 12000]

    // Shared with the main thread: written here, read there. Aligned stores.
    let levels: UnsafeMutablePointer<Float>
    /// `CFAbsoluteTime` of the last buffer with audible signal.
    let lastSignal: UnsafeMutablePointer<Double>

    private let skipInputBuffers: Int
    private let setup: FFTSetup
    private let window: UnsafeMutablePointer<Float>
    private let samples: UnsafeMutablePointer<Float>
    private let hopBuffer: UnsafeMutablePointer<Float>
    private let real: UnsafeMutablePointer<Float>
    private let imaginary: UnsafeMutablePointer<Float>
    private let power: UnsafeMutablePointer<Float>
    private let windowed: UnsafeMutablePointer<Float>
    private let bandDB: UnsafeMutablePointer<Float>
    private let smoothed: UnsafeMutablePointer<Float>
    private let bandRanges: [Range<Int>]
    private var hopFill = 0
    /// Loudest band seen lately, in dB, decaying: bars are relative to it so
    /// they fill the same at any system volume.
    private var reference: Float = -60

    private let inPointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    private let inStrides: UnsafeMutablePointer<Int>
    private static let maxChannels = 8

    init?(sampleRate: Double, skipInputBuffers: Int) {
        guard let setup = vDSP_create_fftsetup(Self.log2Size, FFTRadix(kFFTRadix2)) else { return nil }
        self.setup = setup
        self.skipInputBuffers = skipInputBuffers

        let n = Self.fftSize
        levels = .allocate(capacity: Self.barCount)
        levels.initialize(repeating: 0, count: Self.barCount)
        lastSignal = .allocate(capacity: 1)
        lastSignal.initialize(to: 0)
        window = .allocate(capacity: n)
        samples = .allocate(capacity: n)
        samples.initialize(repeating: 0, count: n)
        hopBuffer = .allocate(capacity: Self.hop)
        hopBuffer.initialize(repeating: 0, count: Self.hop)
        real = .allocate(capacity: n / 2)
        real.initialize(repeating: 0, count: n / 2)
        imaginary = .allocate(capacity: n / 2)
        imaginary.initialize(repeating: 0, count: n / 2)
        power = .allocate(capacity: n / 2)
        power.initialize(repeating: 0, count: n / 2)
        windowed = .allocate(capacity: n)
        windowed.initialize(repeating: 0, count: n)
        bandDB = .allocate(capacity: Self.barCount)
        bandDB.initialize(repeating: -120, count: Self.barCount)
        smoothed = .allocate(capacity: Self.barCount)
        smoothed.initialize(repeating: 0, count: Self.barCount)
        inPointers = .allocate(capacity: Self.maxChannels)
        inPointers.initialize(repeating: nil, count: Self.maxChannels)
        inStrides = .allocate(capacity: Self.maxChannels)
        inStrides.initialize(repeating: 1, count: Self.maxChannels)

        vDSP_hann_window(window, vDSP_Length(n), Int32(vDSP_HANN_NORM))

        // Bin k sits at k * rate / n; every band gets at least one bin.
        let binWidth = sampleRate / Double(n)
        var ranges: [Range<Int>] = []
        for index in 0 ..< Self.barCount {
            let low = max(Int((Self.edges[index] / binWidth).rounded()), 1)
            let high = min(max(Int((Self.edges[index + 1] / binWidth).rounded()), low + 1), n / 2)
            ranges.append(low ..< high)
        }
        bandRanges = ranges
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        levels.deallocate()
        lastSignal.deallocate()
        window.deallocate()
        samples.deallocate()
        hopBuffer.deallocate()
        real.deallocate()
        imaginary.deallocate()
        power.deallocate()
        windowed.deallocate()
        bandDB.deallocate()
        smoothed.deallocate()
        inPointers.deallocate()
        inStrides.deallocate()
    }

    func render(input: UnsafeMutableAudioBufferListPointer, output: UnsafeMutableAudioBufferListPointer) {
        // The aggregate has the real output device in it, so this proc's output
        // reaches the speakers. It must be silence: this tap only listens.
        for buffer in output {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }

        let source = gatherPlanes(
            input, skippingLeading: skipInputBuffers,
            into: inPointers, strides: inStrides, capacity: Self.maxChannels
        )
        guard source.count > 0, source.frames > 0 else { return }

        var peak: Float = 0
        let scale = 1 / Float(source.count)
        for frame in 0 ..< source.frames {
            var mono: Float = 0
            for channel in 0 ..< source.count {
                if let pointer = inPointers[channel] { mono += pointer[frame * inStrides[channel]] }
            }
            mono *= scale
            peak = max(peak, abs(mono))
            hopBuffer[hopFill] = mono
            hopFill += 1
            if hopFill == Self.hop {
                hopFill = 0
                analyse()
            }
        }
        if peak > 0.000_03 { lastSignal.pointee = CFAbsoluteTimeGetCurrent() }
    }

    /// Slides the window by one hop, transforms it and updates the four bars.
    private func analyse() {
        let n = Self.fftSize
        let half = n / 2

        memmove(samples, samples + Self.hop, (n - Self.hop) * MemoryLayout<Float>.size)
        memcpy(samples + (n - Self.hop), hopBuffer, Self.hop * MemoryLayout<Float>.size)

        // Window into a scratch copy, pack even/odd samples as split complex,
        // transform, and take squared magnitudes.
        vDSP_vmul(samples, 1, window, 1, windowed, 1, vDSP_Length(n))

        var split = DSPSplitComplex(realp: real, imagp: imaginary)
        windowed.withMemoryRebound(to: DSPComplex.self, capacity: half) { complex in
            vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(half))
        }
        vDSP_fft_zrip(setup, &split, 1, Self.log2Size, FFTDirection(kFFTDirection_Forward))
        vDSP_zvmags(&split, 1, power, 1, vDSP_Length(half))

        // Absolute calibration does not matter here: the bars are drawn
        // relative to the loudest band. This only keeps the numbers in a
        // sensible range for the dB conversion.
        var norm = 4 / Float(n * n)
        vDSP_vsmul(power, 1, &norm, power, 1, vDSP_Length(half))

        for (index, range) in bandRanges.enumerated() {
            var mean: Float = 0
            vDSP_meanv(power + range.lowerBound, 1, &mean, vDSP_Length(range.count))
            // High bands carry far less energy in music; tilt so the bars are
            // comparable.
            bandDB[index] = 10 * log10f(mean + 1e-12) + Float(index) * 5
        }

        var loudest: Float = -120
        for index in 0 ..< Self.barCount { loudest = max(loudest, bandDB[index]) }
        reference = max(loudest, reference - 0.4, -70)

        for index in 0 ..< Self.barCount {
            // 36 dB below the reference is the bottom of the bar.
            let target = min(max((bandDB[index] - (reference - 36)) / 36, 0), 1)
            let previous = smoothed[index]
            // Quick to rise, slower to fall.
            smoothed[index] = previous + (target - previous) * (target > previous ? 0.7 : 0.22)
            levels[index] = smoothed[index]
        }
    }
}

@MainActor
final class SpectrumAnalyzer {
    static let shared = SpectrumAnalyzer()

    /// How long after the last audible buffer the bars still count as live.
    /// A pause in the music should show flat real bars, not a fake dance.
    private static let signalMemory: TimeInterval = 3

    private var references = 0
    private var started = false
    private var cancellables = Set<AnyCancellable>()
    private var stopWorkItem: DispatchWorkItem?
    private var running = false
    private var loggedRefusal = false
    private let observer = AudioPropertyObserver()
    // Type-erased because the session is macOS 14.2+.
    private var session: AnyObject?
    private var renderState: SpectrumRenderState?

    private init() {}

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true

        MusicManager.shared.$track
            .map(\.isPlaying)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.evaluate() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.evaluate() }
            .store(in: &cancellables)

        // The tap is bound to the output device it was built on.
        observer.add(AudioObjects.system, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            guard let self, running else { return }
            stopTap()
            evaluate()
        }
    }

    /// A visualiser came on screen.
    func acquire() {
        references += 1
        evaluate()
    }

    /// A visualiser went away.
    func release() {
        references = max(references - 1, 0)
        evaluate()
    }

    /// Whether the tap should be running right now, and making it so. Starting
    /// is immediate; stopping waits a moment, because a visualiser handing over
    /// to another (peek to closed notch) releases before the next one acquires.
    private func evaluate() {
        let wanted = references > 0
            && MediaExtrasDefaults.realSpectrum
            && MusicManager.shared.isPlaying

        if wanted {
            stopWorkItem?.cancel()
            stopWorkItem = nil
            if !running { startTap() }
        } else if running, stopWorkItem == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                stopWorkItem = nil
                stopTap()
            }
            stopWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
    }

    private func startTap() {
        guard #available(macOS 14.2, *) else { return }

        // A refused permission would make the tap deliver zeros; do not even
        // try. The check is a cheap call, so a change in System Settings is
        // picked up the next time a visualiser appears.
        if AudioCapturePermission.status == .denied {
            if !loggedRefusal {
                loggedRefusal = true
                DiagnosticLog.write("spectrum", "audio capture permission denied; using the animation")
            }
            return
        }
        loggedRefusal = false

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted

        let box = RenderBox()
        do {
            let created = try AudioTapSession(description: description) { input, output in
                box.state?.render(input: input, output: output)
            }
            guard let state = SpectrumRenderState(sampleRate: created.sampleRate, skipInputBuffers: created.leadingInputBuffers) else {
                created.stop()
                return
            }
            box.state = state
            try created.start()
            session = created
            renderState = state
            running = true
        } catch {
            DiagnosticLog.write("spectrum", "tap failed: \(error)")
        }
    }

    private func stopTap() {
        guard #available(macOS 14.2, *) else { return }
        (session as? AudioTapSession)?.stop()
        session = nil
        renderState = nil
        running = false
    }

    private final class RenderBox: @unchecked Sendable {
        var state: SpectrumRenderState?
    }

    // MARK: Reading

    /// Level of bar `index`, 0...1, or nil when the visualiser should fall
    /// back to its synthetic animation.
    func level(_ index: Int) -> Double? {
        guard let renderState, running, index < SpectrumRenderState.barCount else { return nil }
        guard CFAbsoluteTimeGetCurrent() - renderState.lastSignal.pointee < Self.signalMemory else { return nil }
        return Double(renderState.levels[index])
    }
}
