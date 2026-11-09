//
//  AgentViews.swift
//  FunNotch
//
//  The pieces a Claude Code or Codex session is drawn with: Claude's own
//  spinner while it works, an orange hand while it waits for you, and a check
//  that draws itself when it is done. Plus the small motion toolkit every
//  announcement in the notch uses.
//

import AppKit
import SwiftUI

// MARK: - Motion

/// Easing and springs as plain functions of time.
///
/// Announcements animate procedurally — each piece works out where it should
/// be from the seconds since it appeared — rather than through SwiftUI's
/// implicit animations. The entrances then play identically every time, can
/// be layered with precise delays, and render correctly in the snapshot
/// renderer, which cannot wait for SwiftUI to animate anything.
enum Motion {
    /// Set by the snapshot renderer: every entrance is drawn finished.
    nonisolated(unsafe) static var snapshotMode = false

    /// Set by the film renderer (`--render-film`): seconds since the shot
    /// began. Every clock-driven view reads this instead of the wall clock, so
    /// a video can be rendered one exact frame at a time.
    nonisolated(unsafe) static var filmTime: Double?

    /// The wall-clock time the film pretends it is, advancing with the shot.
    nonisolated(unsafe) static var filmDate: Date?

    /// Set by the film renderer: the level of each of the spectrum's bars for
    /// this frame, 0...1, so the bars move the same way in every render.
    nonisolated(unsafe) static var filmSpectrum: [Double]?

    static func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }

    /// 0 → 1 over `duration`, starting after `delay`.
    static func progress(_ t: Double, delay: Double = 0, duration: Double) -> Double {
        clamp((t - delay) / max(duration, 0.0001))
    }

    static func easeOut(_ x: Double) -> Double { 1 - pow(1 - clamp(x), 3) }

    static func easeInOut(_ x: Double) -> Double {
        let t = clamp(x)
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    /// An underdamped spring's step response: overshoots, then settles on 1.
    /// The same curve SwiftUI's `.spring(response:dampingFraction:)` follows.
    static func spring(_ t: Double, response: Double = 0.42, damping: Double = 0.55) -> Double {
        guard t > 0 else { return 0 }
        let natural = 2 * Double.pi / response
        let zeta = min(max(damping, 0.01), 0.99)
        let damped = natural * (1 - zeta * zeta).squareRoot()
        let decay = exp(-zeta * natural * t)
        return 1 - decay * (cos(damped * t) + (zeta * natural / damped) * sin(damped * t))
    }
}

/// Hands its content the seconds elapsed since it first appeared, then stops
/// ticking once the entrance is over.
struct IntroTimeline<Content: View>: View {
    /// How long the content keeps changing. Past this it is drawn once more
    /// and left alone.
    var duration: Double = 1.2
    @ViewBuilder let content: (Double) -> Content

    @State private var start = Date()
    @State private var settled = false

    var body: some View {
        if let film = Motion.filmTime {
            content(film)
        } else if Motion.snapshotMode {
            content(60)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: settled)) { context in
                content(settled ? 60 : context.date.timeIntervalSince(start))
            }
            .task {
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                settled = true
            }
        }
    }
}

// MARK: - Working

/// Claude Code's own spinner — the glyph that turns beside "Thinking…" in the
/// terminal — so a working session looks the way it does in Claude.
struct ClaudeSpinner: View {
    var size: CGFloat = 13
    var tint: Color = AgentPalette.claude

    private static let frames = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]
    private static let interval = 0.12

    var body: some View {
        if let film = Motion.filmTime {
            glyph(Self.frames[Int(film / Self.interval) % Self.frames.count])
        } else if Motion.snapshotMode {
            glyph(Self.frames[4])
        } else {
            TimelineView(.periodic(from: .now, by: Self.interval)) { context in
                let index = Int(context.date.timeIntervalSinceReferenceDate / Self.interval) % Self.frames.count
                glyph(Self.frames[index])
            }
        }
    }

    private func glyph(_ character: String) -> some View {
        Text(character)
            .font(.system(size: size, weight: .heavy))
            .foregroundStyle(tint)
            .shadow(color: tint.opacity(0.6), radius: size * 0.3)
            .frame(width: size * 1.3, height: size * 1.3)
    }
}

/// Codex has no signature glyph, so it gets a quiet orbit.
struct OrbitSpinner: View {
    var size: CGFloat = 13
    var tint: Color = AgentPalette.codex
    @Environment(\.decorAnimationsPaused) private var paused

    var body: some View {
        if Motion.filmTime != nil || Motion.snapshotMode {
            // The offline renderers draw views, not layer animations.
            drawn(angle: Motion.filmTime.map { $0 * 300 } ?? 40)
        } else {
            // Turned by Core Animation in the render server: an agent can
            // work for hours, and the 15 fps SwiftUI timeline this replaces
            // re-laid-out the whole notch window on every frame of it.
            LayerOrbit(size: size, tint: NSColor(tint), paused: paused)
                .frame(width: size, height: size)
        }
    }

    private func drawn(angle: Double) -> some View {
        ZStack {
            Circle().stroke(tint.opacity(0.25), lineWidth: 1.6)
            Circle()
                .trim(from: 0, to: 0.3)
                .stroke(tint, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .rotationEffect(.degrees(angle))
        }
        .frame(width: size, height: size)
    }
}

/// Whichever spinner belongs to the agent.
struct AgentWorkingGlyph: View {
    let agent: AgentSessionsManager.Agent
    var size: CGFloat = 13

    var body: some View {
        switch agent {
        case .claude: ClaudeSpinner(size: size)
        case .codex: OrbitSpinner(size: size * 0.95)
        case .omp: OrbitSpinner(size: size * 0.95, tint: AgentPalette.omp)
        }
    }
}

// MARK: - Waiting

/// A raised hand that waves every couple of seconds, with a ring that keeps
/// pulsing out from it — hard to miss, easy to ignore.
struct AgentWaitingGlyph: View {
    var size: CGFloat = 13
    /// Seconds since the wait began, when the caller already has a clock.
    var time: Double?
    @Environment(\.decorAnimationsPaused) private var paused

    var body: some View {
        if let time = time ?? Motion.filmTime {
            drawn(time)
        } else if Motion.snapshotMode {
            drawn(1.1)
        } else {
            // A session can wait for an answer all night; Core Animation
            // plays the wave without waking the app (see `LayerOrbit`).
            LayerWaitingHand(size: size, paused: paused)
                .frame(width: size * 1.3, height: size * 1.3)
        }
    }

    static let period = 2.2
    static let ringPeriod = 1.4

    /// The hand's tilt in degrees, clockwise, at `t` seconds.
    static func waveAngle(_ t: Double) -> Double {
        let local = t.truncatingRemainder(dividingBy: period)
        let wave = max(0, 1 - local / 0.9)
        return sin(local * 16) * 16 * wave
    }

    private func drawn(_ t: Double) -> some View {
        let ring = t.truncatingRemainder(dividingBy: Self.ringPeriod) / Self.ringPeriod
        return ZStack {
            Circle()
                .stroke(AgentPalette.waiting.opacity(0.55 * (1 - ring)), lineWidth: 1.2)
                .scaleEffect(0.7 + ring * 0.9)
            Image(systemName: "hand.raised.fill")
                .font(.system(size: size * 0.82, weight: .semibold))
                .foregroundStyle(AgentPalette.waiting)
                .rotationEffect(.degrees(Self.waveAngle(t)), anchor: .bottom)
        }
        .frame(width: size * 1.3, height: size * 1.3)
    }
}

// MARK: - Layer-driven glyphs

/// Base for glyphs animated by Core Animation. The animations run in the
/// render server, so a glyph that moves for hours costs the app nothing per
/// frame; they are dropped while paused and stop being drawn with the window.
/// Each one also asks for the frame rate the SwiftUI version had, so the
/// render server does not redraw it at the display's full refresh rate.
private class AgentLayerView: NSView {
    /// Holds the glyph's layers, with y growing downwards like SwiftUI's, so
    /// "bottom" and "clockwise" mean the same as in the drawn fallback.
    let canvas = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        canvas.isGeometryFlipped = true
        layer?.addSublayer(canvas)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvas.frame = bounds
        layoutCanvas()
        CATransaction.commit()
    }

    /// Lays the glyph out in `canvas.bounds`; actions are already disabled.
    func layoutCanvas() {}

    var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    static func frameRate(_ fps: Float) -> CAFrameRateRange {
        CAFrameRateRange(minimum: fps / 2, maximum: fps, preferred: fps)
    }
}

private struct LayerOrbit: NSViewRepresentable {
    let size: CGFloat
    let tint: NSColor
    let paused: Bool

    func makeNSView(context: Context) -> OrbitLayerView { OrbitLayerView() }

    func updateNSView(_ view: OrbitLayerView, context: Context) {
        view.configure(tint: tint, paused: paused)
    }
}

private final class OrbitLayerView: AgentLayerView {
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private var paused = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        for shape in [track, arc] {
            shape.fillColor = nil
            canvas.addSublayer(shape)
        }
        track.lineWidth = 1.6
        arc.lineWidth = 1.8
        arc.lineCap = .round
        arc.strokeEnd = 0.3
    }

    func configure(tint: NSColor, paused: Bool) {
        track.strokeColor = tint.withAlphaComponent(0.25).cgColor
        arc.strokeColor = tint.cgColor
        self.paused = paused
        updateAnimation()
    }

    override func layoutCanvas() {
        let bounds = canvas.bounds
        let side = min(bounds.width, bounds.height)
        let box = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        for shape in [track, arc] {
            shape.frame = box
            shape.contentsScale = scale
            shape.path = CGPath(ellipseIn: CGRect(origin: .zero, size: box.size).insetBy(dx: 0.9, dy: 0.9), transform: nil)
        }
    }

    private func updateAnimation() {
        let key = "spin"
        if paused {
            arc.removeAnimation(forKey: key)
        } else if arc.animation(forKey: key) == nil {
            // 300° a second, as the drawn fallback; clockwise on screen,
            // like SwiftUI's positive rotation, in the flipped canvas.
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = 2 * Double.pi
            spin.duration = 1.2
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            spin.preferredFrameRateRange = Self.frameRate(15)
            arc.add(spin, forKey: key)
        }
    }
}

private struct LayerWaitingHand: NSViewRepresentable {
    let size: CGFloat
    let paused: Bool

    func makeNSView(context: Context) -> WaitingLayerView { WaitingLayerView() }

    func updateNSView(_ view: WaitingLayerView, context: Context) {
        view.configure(size: size, paused: paused)
    }
}

private final class WaitingLayerView: AgentLayerView {
    private let ring = CAShapeLayer()
    private let hand = CALayer()
    private var size: CGFloat = 0
    private var paused = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        ring.fillColor = nil
        ring.lineWidth = 1.2
        ring.strokeColor = NSColor(AgentPalette.waiting).cgColor
        // Seen only through the pulse animation, which fades it out.
        ring.opacity = 0
        hand.contentsGravity = .resizeAspect
        // Waves from the wrist: the bottom edge in the flipped canvas.
        hand.anchorPoint = CGPoint(x: 0.5, y: 1)
        canvas.addSublayer(ring)
        canvas.addSublayer(hand)
    }

    func configure(size: CGFloat, paused: Bool) {
        if size != self.size {
            self.size = size
            needsLayout = true
        }
        self.paused = paused
        updateAnimations()
    }

    override func layoutCanvas() {
        let bounds = canvas.bounds
        ring.frame = bounds
        ring.contentsScale = scale
        ring.path = CGPath(ellipseIn: bounds.insetBy(dx: 0.6, dy: 0.6), transform: nil)

        let config = NSImage.SymbolConfiguration(pointSize: size * 0.82, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(AgentPalette.waiting)]))
        if let image = NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            hand.contentsScale = scale
            hand.contents = image.layerContents(forContentsScale: scale)
            hand.bounds = CGRect(origin: .zero, size: image.size)
            hand.position = CGPoint(x: bounds.midX, y: bounds.midY + image.size.height / 2)
        }
    }

    private func updateAnimations() {
        guard !paused else {
            ring.removeAllAnimations()
            hand.removeAllAnimations()
            return
        }
        if ring.animation(forKey: "pulse") == nil {
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.7
            grow.toValue = 1.6
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.55
            fade.toValue = 0
            let pulse = CAAnimationGroup()
            pulse.animations = [grow, fade]
            pulse.duration = AgentWaitingGlyph.ringPeriod
            pulse.repeatCount = .infinity
            pulse.isRemovedOnCompletion = false
            pulse.preferredFrameRateRange = Self.frameRate(15)
            ring.add(pulse, forKey: "pulse")
        }
        if hand.animation(forKey: "wave") == nil {
            // The same damped wave as the drawn glyph, sampled at 30 points
            // a second and interpolated by Core Animation.
            let steps = Int(AgentWaitingGlyph.period * 30)
            let wave = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            wave.values = (0 ... steps).map { step in
                AgentWaitingGlyph.waveAngle(Double(step) / 30) * Double.pi / 180
            }
            wave.duration = AgentWaitingGlyph.period
            wave.repeatCount = .infinity
            wave.isRemovedOnCompletion = false
            wave.preferredFrameRateRange = Self.frameRate(20)
            hand.add(wave, forKey: "wave")
        }
    }
}

// MARK: - Done

/// A circle that draws itself, a check inside it, and a small burst of sparks
/// as it lands.
struct CheckmarkBurst: View {
    /// Seconds since the check started drawing.
    let time: Double
    var size: CGFloat = 17
    var tint: Color = AgentPalette.done

    var body: some View {
        let ring = Motion.easeOut(Motion.progress(time, duration: 0.36))
        let tick = Motion.easeOut(Motion.progress(time, delay: 0.24, duration: 0.26))
        let pop = Motion.spring(time, response: 0.46, damping: 0.48)
        let burst = Motion.progress(time, delay: 0.32, duration: 0.62)

        return ZStack {
            ForEach(0 ..< 8, id: \.self) { index in
                let angle = Double(index) / 8 * 2 * Double.pi + 0.2
                let radius = Double(size) * (0.58 + 0.5 * Motion.easeOut(burst))
                Circle()
                    .fill(index.isMultiple(of: 2) ? tint : .white)
                    .frame(width: 2.3, height: 2.3)
                    .offset(x: cos(angle) * radius, y: sin(angle) * radius)
                    .opacity(burst > 0 && burst < 1 ? 1 - burst : 0)
            }
            Circle()
                .fill(tint.opacity(0.18 * ring))
            Circle()
                .trim(from: 0, to: ring)
                .stroke(tint, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            CheckShape()
                .trim(from: 0, to: tick)
                .stroke(tint, style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
                .padding(size * 0.28)
        }
        .frame(width: size, height: size)
        .scaleEffect(0.5 + 0.5 * pop)
    }
}

struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.55))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY - rect.height * 0.08))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.1))
        return path
    }
}

// MARK: - Beside the cutout

/// The small light beside the camera while any session is busy: Claude's
/// spinner, or the waving hand if one of them is waiting for you, with a count
/// when there is more than one.
struct AgentPip: View {
    @ObservedObject private var agents = AgentSessionsManager.shared

    var body: some View {
        HStack(spacing: 2) {
            if agents.waitingCount > 0 {
                AgentWaitingGlyph(size: 12)
            } else {
                AgentWorkingGlyph(agent: agents.headline?.agent ?? .claude, size: 12)
            }
            if agents.activeCount > 1 {
                Text("\(agents.activeCount)")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
                    .contentTransition(.numericText(value: Double(agents.activeCount)))
            }
        }
        // Clear of the camera housing, the way the widgets beside it are.
        .padding(.leading, 11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .transition(.scale(scale: 0.3).combined(with: .opacity))
        .help(summary)
    }

    private var summary: String {
        let working = agents.workingCount
        let waiting = agents.waitingCount
        var parts: [String] = []
        if working > 0 { parts.append("\(working) \(working == 1 ? "pracuje" : "pracują")") }
        if waiting > 0 { parts.append("\(waiting) \(waiting == 1 ? "czeka" : "czekają") na Ciebie") }
        return parts.joined(separator: ", ")
    }
}

/// With nothing else beside the cutout, a working session gets both wings:
/// the spinner on the left…
struct AgentWingGlyph: View {
    @ObservedObject private var agents = AgentSessionsManager.shared

    var body: some View {
        Group {
            if agents.waitingCount > 0 {
                AgentWaitingGlyph(size: 13)
            } else {
                AgentWorkingGlyph(agent: agents.headline?.agent ?? .claude, size: 13)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// …and how long it has been at it on the right.
struct AgentWingClock: View {
    @ObservedObject private var agents = AgentSessionsManager.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let session = agents.headline
            let since = session?.turnStartedAt ?? session?.statusSince ?? context.date
            Text(agents.activeCount > 1
                 ? "×\(agents.activeCount)"
                 : AgentSessionsManager.clock(context.date.timeIntervalSince(since)))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(agents.waitingCount > 0 ? AgentPalette.waiting : .white.opacity(0.85))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
