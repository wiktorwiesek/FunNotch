//
//  Components.swift
//  FunNotch
//
//  Reusable pieces: the spectrum visualizer, scrolling text, and the hover
//  buttons used throughout the notch.
//

import AppKit
import SwiftUI

/// Four bars that bounce while music plays and settle flat when it stops.
struct MusicVisualizer: View {
    let isPlaying: Bool
    let color: Color

    @AppStorage(MediaExtrasDefaults.realSpectrumKey) private var realSpectrum = false

    private let barCount = 4
    /// Per-bar phase and rate so the bars never move in lockstep.
    private let phases: [Double] = [0.0, 1.7, 0.6, 2.4]
    private let rates: [Double] = [3.1, 4.3, 2.6, 3.7]

    var body: some View {
        Group {
            if realSpectrum || Motion.filmSpectrum != nil || Motion.snapshotMode {
                // Real levels change every frame, and the offline renderers
                // draw views rather than layer animations.
                timeline
            } else {
                // The made-up bounce is a fixed function of time, so Core
                // Animation can play it in the render server. The closed notch
                // shows these bars for as long as music plays, and the 30 fps
                // timeline below re-rendered the notch window on every frame.
                LayerVisualizer(isPlaying: isPlaying, color: NSColor(color), phases: phases, rates: rates)
            }
        }
        // The analyzer runs only while some visualiser is on screen.
        .onAppear { if Motion.filmSpectrum == nil { SpectrumAnalyzer.shared.acquire() } }
        .onDisappear { if Motion.filmSpectrum == nil { SpectrumAnalyzer.shared.release() } }
    }

    private var timeline: some View {
        TimelineView(.animation(minimumInterval: isPlaying ? 1.0 / 30.0 : nil, paused: !isPlaying)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            GeometryReader { proxy in
                let spacing = proxy.size.width / CGFloat(barCount * 2 - 1)
                HStack(alignment: .center, spacing: spacing) {
                    ForEach(0 ..< barCount, id: \.self) { index in
                        Capsule()
                            .fill(color)
                            .frame(
                                width: spacing,
                                height: barHeight(index: index, time: time, maximum: proxy.size.height)
                            )
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
            }
        }
        .animation(.easeOut(duration: 0.25), value: isPlaying)
    }

    private func barHeight(index: Int, time: Double, maximum: CGFloat) -> CGFloat {
        guard isPlaying else { return max(maximum * 0.18, 2) }
        if let levels = Motion.filmSpectrum, index < levels.count {
            return max(maximum * (0.2 + 0.8 * CGFloat(levels[index])), 2)
        }
        // Real levels from the system output when the tap is up and hearing
        // something; otherwise the animation below.
        if let level = SpectrumAnalyzer.shared.level(index) {
            return max(maximum * (0.2 + 0.8 * CGFloat(level)), 2)
        }
        let normalised = Self.bounce(time: time, rate: rates[index], phase: phases[index])
        return max(maximum * (0.2 + 0.8 * normalised), 2)
    }

    /// The made-up level, 0...1, of a bar with this rate and phase. The
    /// slower secondary wave runs at 0.53 of the rate unless told otherwise.
    static func bounce(time: Double, rate: Double, phase: Double, secondaryRate: Double? = nil) -> Double {
        let wave = sin(time * rate + phase)
        let secondary = sin(time * (secondaryRate ?? rate * 0.53) + phase * 1.7)
        return (wave * 0.6 + secondary * 0.4 + 1) / 2
    }
}

private struct LayerVisualizer: NSViewRepresentable {
    let isPlaying: Bool
    let color: NSColor
    let phases: [Double]
    let rates: [Double]

    func makeNSView(context: Context) -> VisualizerLayerView {
        VisualizerLayerView(phases: phases, rates: rates)
    }

    func updateNSView(_ view: VisualizerLayerView, context: Context) {
        view.configure(isPlaying: isPlaying, color: color)
    }
}

/// `MusicVisualizer`'s bars as layers whose heights Core Animation plays from
/// precomputed keyframes, so the app does no work per frame while they move.
private final class VisualizerLayerView: NSView {
    private let bars: [CALayer]
    private let phases: [Double]
    private let rates: [Double]
    private var isPlaying = false
    private var animatedHeight: CGFloat = 0

    /// The keyframes repeat after this many seconds. Each wave's rate is
    /// nudged to a whole number of cycles in the loop, so the wrap-around is
    /// seamless; twenty seconds keeps every nudge within 3% and no two bars
    /// on the same rate.
    private static let loop = 20.0
    private static let samplesPerSecond = 30.0

    init(phases: [Double], rates: [Double]) {
        self.phases = phases
        self.rates = rates
        bars = phases.map { _ in CALayer() }
        super.init(frame: .zero)
        wantsLayer = true
        bars.forEach { layer?.addSublayer($0) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(isPlaying: Bool, color: NSColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bars.forEach { $0.backgroundColor = color.cgColor }
        CATransaction.commit()
        guard isPlaying != self.isPlaying else { return }
        self.isPlaying = isPlaying
        updateAnimations(settling: true)
    }

    private var flatHeight: CGFloat { max(bounds.height * 0.18, 2) }

    override func layout() {
        super.layout()
        let spacing = bounds.width / CGFloat(bars.count * 2 - 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: spacing, height: flatHeight)
            bar.position = CGPoint(x: spacing * (CGFloat(index) * 2 + 0.5), y: bounds.midY)
            bar.cornerRadius = spacing / 2
        }
        CATransaction.commit()
        // The keyframes are absolute heights; a new size needs new ones.
        if isPlaying, animatedHeight != bounds.height { updateAnimations(settling: false) }
    }

    private func updateAnimations(settling: Bool) {
        let key = "bounce"
        guard isPlaying else {
            for bar in bars {
                let from = bar.presentation()?.bounds.height ?? flatHeight
                bar.removeAnimation(forKey: key)
                guard settling else { continue }
                let settle = CABasicAnimation(keyPath: "bounds.size.height")
                settle.fromValue = from
                settle.toValue = flatHeight
                settle.duration = 0.25
                settle.timingFunction = CAMediaTimingFunction(name: .easeOut)
                bar.add(settle, forKey: "settle")
            }
            animatedHeight = 0
            return
        }
        animatedHeight = bounds.height
        let maximum = bounds.height
        let steps = Int(Self.loop * Self.samplesPerSecond)
        let now = CACurrentMediaTime()
        func looped(_ rate: Double) -> Double {
            let cycles = max((rate * Self.loop / (2 * Double.pi)).rounded(), 1)
            return cycles * 2 * Double.pi / Self.loop
        }
        for (index, bar) in bars.enumerated() {
            let rate = looped(rates[index])
            let secondaryRate = looped(rates[index] * 0.53)
            let animation = CAKeyframeAnimation(keyPath: "bounds.size.height")
            animation.values = (0 ... steps).map { step in
                let level = MusicVisualizer.bounce(
                    time: Double(step) / Self.samplesPerSecond,
                    rate: rate, phase: phases[index], secondaryRate: secondaryRate
                )
                return max(maximum * (0.2 + 0.8 * level), 2)
            }
            animation.duration = Self.loop
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            animation.beginTime = now
            animation.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            bar.removeAnimation(forKey: "settle")
            bar.add(animation, forKey: key)
        }
    }
}

/// Text that scrolls horizontally when it does not fit, and sits still when it does.
struct MarqueeText: View {
    let text: String
    var font: Font = .body
    var speed: Double = 30
    var pause: Double = 1.6
    /// The row is a fixed height so the text never reflows its neighbours;
    /// compact layouts ask for less than the default.
    var lineHeight: CGFloat = 18

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private var overflows: Bool { textWidth > containerWidth + 1 }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                if overflows {
                    HStack(spacing: gap) {
                        label
                        label
                    }
                    .offset(x: offset)
                } else {
                    label
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
            .onAppear {
                containerWidth = proxy.size.width
                restart()
            }
            .onChange(of: proxy.size.width) { _, newValue in
                containerWidth = newValue
                restart()
            }
        }
        .frame(height: lineHeight)
        .clipped()
        .onChange(of: text) { restart() }
        .onChange(of: textWidth) { restart() }
    }

    private var gap: CGFloat { 40 }

    private var label: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .background(
                GeometryReader { proxy in
                    Color.clear.onAppear { textWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, newValue in textWidth = newValue }
                }
            )
    }

    private func restart() {
        offset = 0
        guard overflows else { return }
        let distance = textWidth + gap
        let duration = Double(distance) / speed
        withAnimation(.linear(duration: duration).delay(pause).repeatForever(autoreverses: false)) {
            offset = -distance
        }
    }
}

/// Button that lights up on hover, used for every control in the notch.
struct HoverButton: View {
    let systemName: String
    var size: CGFloat = 16
    var padding: CGFloat = 7
    var isActive: Bool = false
    var tint: Color = .white
    /// Optional glyph drawn over the symbol, e.g. the "1" of repeat-one.
    var badge: String? = nil
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(isActive ? tint : .white)
                .overlay {
                    if let badge {
                        Text(badge)
                            .font(.system(size: size * 0.5, weight: .bold))
                            .foregroundStyle(isActive ? tint : .white)
                            .padding(.horizontal, 1)
                            .background(Color.black)
                    }
                }
                .frame(width: size + padding * 2, height: size + padding * 2)
                .background(
                    Circle()
                        .fill(Color.white.opacity(isHovering ? 0.16 : 0))
                )
                .scaleEffect(isHovering ? 1.06 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
        }
    }
}

/// Slim, draggable progress bar used for the scrubber and HUD levels.
struct NotchSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0 ... 1
    var color: Color = .white
    var height: CGFloat = 5
    var isEnabled: Bool = true
    var onEditingChanged: ((Bool) -> Void)?

    @State private var isDragging = false
    @State private var isHovering = false

    var body: some View {
        GeometryReader { proxy in
            let span = max(range.upperBound - range.lowerBound, 0.0001)
            let fraction = min(max((value - range.lowerBound) / span, 0), 1)
            let barHeight = (isHovering || isDragging) ? height + 3 : height

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.22))
                Capsule()
                    .fill(color)
                    .frame(width: proxy.size.width * fraction)
            }
            .frame(height: barHeight)
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard isEnabled else { return }
                        if !isDragging {
                            isDragging = true
                            onEditingChanged?(true)
                        }
                        let ratio = min(max(gesture.location.x / proxy.size.width, 0), 1)
                        value = range.lowerBound + ratio * span
                    }
                    .onEnded { _ in
                        // Not `isEnabled`: it can turn false mid-drag, and the
                        // drag that began must still end.
                        guard isDragging else { return }
                        isDragging = false
                        onEditingChanged?(false)
                    }
            )
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
            }
            .animation(.easeOut(duration: 0.15), value: isDragging)
        }
    }
}

/// Compact battery pill shown in the open notch's header.
struct BatteryPill: View {
    @ObservedObject private var battery = BatteryManager.shared
    @EnvironmentObject private var settings: Settings

    @State private var showsDetail = false

    var body: some View {
        HStack(spacing: 5) {
            if settings.showBatteryPercentage {
                Text(battery.percentageText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .monospacedDigit()
            }

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.white.opacity(0.45), lineWidth: 1)
                    .frame(width: 24, height: 12)

                RoundedRectangle(cornerRadius: 1.5)
                    .fill(battery.indicatorColor)
                    .frame(width: max(2, 20 * CGFloat(battery.level)), height: 8)
                    .padding(.leading, 2)

                if battery.isCharging || battery.isPluggedIn, settings.showPowerStatusIcons {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 24, height: 12)
                }
            }
            .overlay(alignment: .trailing) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(0.45))
                    .frame(width: 2, height: 5)
                    .offset(x: 3)
            }
        }
        .help(battery.timeRemainingText ?? battery.percentageText)
        .onHover { showsDetail = $0 }
    }
}
