//
//  CatLayerView.swift
//  FunNotch
//
//  Plays the cat with Core Animation, so the app does close to nothing while
//  it moves. Every pose of a clip is drawn once into a `CGImage` (see
//  `CatFrameCache`), the stills are stepped through by a discrete keyframe
//  animation on the layer's `contents`, and the bounce, hop and slide ride on
//  top as transform keyframes. The render server runs all of it; no timer, no
//  SwiftUI state and no `TimelineView` is involved, and a state change swaps
//  animation sets on the same layer instead of rebuilding any view tree.
//
//  Motion stops (the layer shows a still) while the view is not in a visible
//  window, the notch is hidden for a fullscreen app (`decorAnimationsPaused`),
//  the screen is off or locked, Low Power Mode is on, or Reduce Motion is.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Tint

enum CatTint {
    /// 8-bit sRGB, packed. The cache key and the accent handed to the drawing.
    static func pack(_ color: NSColor) -> UInt32 {
        let srgb = color.usingColorSpace(.sRGB) ?? NSColor.white
        func byte(_ value: CGFloat) -> UInt32 { UInt32(min(max(value, 0), 1) * 255 + 0.5) }
        return byte(srgb.redComponent) << 24 | byte(srgb.greenComponent) << 16 | byte(srgb.blueComponent) << 8 | byte(srgb.alphaComponent)
    }

    static func components(_ packed: UInt32) -> (r: Double, g: Double, b: Double, a: Double) {
        (
            Double(packed >> 24 & 0xFF) / 255, Double(packed >> 16 & 0xFF) / 255,
            Double(packed >> 8 & 0xFF) / 255, Double(packed & 0xFF) / 255
        )
    }
}

// MARK: - Frames

/// Stills of the cat, drawn on demand and shared by every view that needs the
/// same pose at the same size and tint. Small by construction (a pose at 18 pt
/// on a 2× screen is 5 KB); when the budget is passed the whole cache is
/// dropped, and the next view to need a pose draws it again.
@MainActor
enum CatFrameCache {
    private struct Key: Hashable {
        let pose: CatPose
        let pixels: Int
        let tint: UInt32
    }

    private static var images: [Key: CGImage] = [:]
    /// Pixel bytes held right now.
    private(set) static var bytes = 0
    /// How many images were drawn since launch; the cache working shows as this standing still.
    private(set) static var drawn = 0
    static let budget = 1_500_000

    static func image(_ pose: CatPose, pixels: Int, tint: UInt32) -> CGImage? {
        let key = Key(pose: pose, pixels: pixels, tint: tint)
        if let cached = images[key] { return cached }
        guard let image = CatArt.image(pose, pixels: pixels, tint: CatTint.components(tint)) else { return nil }
        let cost = image.bytesPerRow * image.height
        if bytes + cost > budget {
            images.removeAll(keepingCapacity: true)
            bytes = 0
        }
        images[key] = image
        bytes += cost
        drawn += 1
        return image
    }
}

// MARK: - When may it move

/// One answer to "may the cat animate right now": the screen is being
/// watched, the Mac is not saving power, the user has not asked for less
/// motion. Views subscribe and drop or restart their animations when it flips.
@MainActor
final class CatMotionGate: ObservableObject {
    static let shared = CatMotionGate()

    @Published private(set) var allowsMotion = true

    private var cancellables = Set<AnyCancellable>()

    private init() {
        recompute()
        SystemActivityMonitor.shared.$isIdle
            .sink { [weak self] _ in
                // `$isIdle` publishes before its value lands.
                DispatchQueue.main.async { self?.recompute() }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)
    }

    private func recompute() {
        let allowed = !SystemActivityMonitor.shared.isIdle
            && !ProcessInfo.processInfo.isLowPowerModeEnabled
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if allowed != allowsMotion { allowsMotion = allowed }
    }
}

// MARK: - SwiftUI

/// The cat at `size` × `size` points.
struct CatView: View {
    var state: CatState
    var size: CGFloat = 16
    /// The accent: collar and the prop of the moment.
    var tint: Color = .white
    /// Hold the resting pose, e.g. while the countdown the cat walks for is paused.
    var still = false
    @Environment(\.decorAnimationsPaused) private var paused

    var body: some View {
        Group {
            if Motion.snapshotMode || Motion.filmTime != nil {
                // The offline renderers draw views, not layer animations (and
                // may not draw layers at all): they get the resting pose as an image.
                CatStillImage(pose: CatClips.clip(for: state).rest, size: size, tint: tint)
            } else {
                CatLayerRepresentable(state: state, tint: NSColor(tint), paused: paused || still)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// One pose as a plain SwiftUI image.
struct CatStillImage: View {
    let pose: CatPose
    var size: CGFloat = 16
    var tint: Color = .white

    var body: some View {
        let scale = max(NSScreen.main?.backingScaleFactor ?? 2, 2)
        if let image = CatFrameCache.image(pose, pixels: Int((size * scale).rounded()), tint: CatTint.pack(NSColor(tint))) {
            Image(decorative: image, scale: scale)
                .resizable()
                .interpolation(.high)
        } else {
            Color.clear
        }
    }
}

private struct CatLayerRepresentable: NSViewRepresentable {
    let state: CatState
    let tint: NSColor
    let paused: Bool

    func makeNSView(context: Context) -> CatLayerView { CatLayerView() }

    func updateNSView(_ view: CatLayerView, context: Context) {
        view.configure(state: state, tint: tint, paused: paused)
    }
}

// MARK: - The layer view

@MainActor
final class CatLayerView: NSView {
    /// Views whose animations are running; for the perf harness.
    nonisolated(unsafe) private(set) static var playing = 0

    private let sprite = CALayer()
    private var state = CatState.awake
    private var tint: UInt32 = 0xFFFF_FFFF
    private var paused = false
    private var gateAllows = true
    private var cancellables = Set<AnyCancellable>()
    private var windowObservers: [NSObjectProtocol] = []
    private var isPlaying = false
    /// What the layer was last built for, so a no-op update does nothing.
    private var builtFor: (state: CatState, tint: UInt32, pixels: Int, motion: Bool)?

    // Music: the bounce restarts at this beat when its amplitude changes.
    private var loopBegin: CFTimeInterval = 0
    private var bobAmplitude = 1.0
    private var bobTrack: CatMotionTrack?
    private var levelTimer: DispatchSourceTimer?
    private var holdsAnalyzer = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        sprite.contentsGravity = .resizeAspect
        layer?.addSublayer(sprite)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(state: CatState, tint: NSColor, paused: Bool) {
        let packed = CatTint.pack(tint)
        guard state != self.state || packed != self.tint || paused != self.paused else { return }
        self.state = state
        self.tint = packed
        self.paused = paused
        rebuild()
    }

    // MARK: Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers.removeAll()
        cancellables.removeAll()
        if let window {
            // Occluded or minimised windows are not drawn; do not run for them.
            let names: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification, NSWindow.didChangeScreenNotification,
            ]
            for name in names {
                windowObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in MainActor.assumeIsolated { self?.rebuild() } })
            }
            CatMotionGate.shared.$allowsMotion
                .receive(on: RunLoop.main)
                .sink { [weak self] allowed in
                    guard let self, allowed != gateAllows else { return }
                    gateAllows = allowed
                    rebuild()
                }
                .store(in: &cancellables)
            gateAllows = CatMotionGate.shared.allowsMotion
        }
        rebuild()
    }

    override func viewDidHide() {
        super.viewDidHide()
        rebuild()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        rebuild()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rebuild()
    }

    override func layout() {
        super.layout()
        let side = min(bounds.width, bounds.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sprite.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        sprite.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
        rebuild()
    }

    // MARK: Building

    private var motionAllowed: Bool {
        guard !paused, gateAllows, let window, !isHiddenOrHasHiddenAncestor else { return false }
        return window.occlusionState.contains(.visible)
    }

    private func rebuild() {
        let side = min(bounds.width, bounds.height)
        guard side >= 1 else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let pixels = Int((side * scale).rounded())
        let moving = motionAllowed
        if let builtFor, builtFor == (state, tint, pixels, moving) { return }
        builtFor = (state, tint, pixels, moving)

        let clip = CatClips.clip(for: state)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stopAnimations()
        sprite.contentsScale = scale
        layer?.masksToBounds = clip.clipsToBounds

        let tint = tint
        func image(_ pose: CatPose) -> CGImage? {
            CatFrameCache.image(pose, pixels: pixels, tint: tint)
        }
        guard moving else {
            sprite.contents = image(clip.rest)
            CATransaction.commit()
            return
        }
        sprite.contents = clip.loop.first.flatMap { image($0.pose) }
        play(clip, side: side, image: image)
        CATransaction.commit()
    }

    private func stopAnimations() {
        sprite.removeAllAnimations()
        stopLevelTimer()
        if isPlaying {
            isPlaying = false
            Self.playing -= 1
        }
    }

    @MainActor
    private func play(_ clip: CatClip, side: CGFloat, image: (CatPose) -> CGImage?) {
        isPlaying = true
        bobAmplitude = 1
        Self.playing += 1
        let now = sprite.convertTime(CACurrentMediaTime(), from: nil)
        let introLength = clip.introDuration
        loopBegin = now + introLength

        if !clip.intro.isEmpty {
            if let animation = contents(clip.intro, clip: clip, image: image, repeats: false, begin: now) {
                sprite.add(animation, forKey: "introContents")
            }
            for (index, track) in clip.introMotion.enumerated() {
                sprite.add(motion(track, side: side, amplitude: 1, duration: introLength, repeats: false, begin: now, clip: clip), forKey: "introMotion\(index)")
            }
        }
        if let animation = contents(clip.loop, clip: clip, image: image, repeats: true, begin: loopBegin) {
            sprite.add(animation, forKey: "loopContents")
        }
        for (index, track) in clip.loopMotion.enumerated() {
            sprite.add(
                motion(track, side: side, amplitude: bobAmplitude, duration: clip.loopDuration, repeats: true, begin: loopBegin, clip: clip),
                forKey: "loopMotion\(index)"
            )
            if index == 0 { bobTrack = track }
        }
        if clip.beat != nil, MediaExtrasDefaults.realSpectrum { startLevelTimer(clip: clip, side: side) }
    }

    private func contents(
        _ steps: [CatStep], clip: CatClip, image: (CatPose) -> CGImage?, repeats: Bool, begin: CFTimeInterval
    ) -> CAKeyframeAnimation? {
        let images = steps.compactMap { image($0.pose) }
        guard images.count == steps.count else { return nil }
        // One still: nothing to play.
        guard steps.count > 1 || !repeats else { return nil }
        let total = steps.reduce(0) { $0 + $1.duration }
        var times: [NSNumber] = []
        var elapsed = 0.0
        for step in steps {
            times.append(NSNumber(value: elapsed / total))
            elapsed += step.duration
        }
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = images
        animation.keyTimes = times
        animation.calculationMode = .discrete
        animation.duration = total
        animation.beginTime = begin
        animation.repeatCount = repeats ? .infinity : 1
        animation.isRemovedOnCompletion = !repeats
        animation.preferredFrameRateRange = clip.frameRate
        return animation
    }

    private func motion(
        _ track: CatMotionTrack, side: CGFloat, amplitude: Double, duration: Double, repeats: Bool,
        begin: CFTimeInterval, clip: CatClip
    ) -> CAKeyframeAnimation {
        let scale = track.unit == .fractionOfSize ? Double(side) * amplitude : amplitude
        let count = track.values.count
        let animation = CAKeyframeAnimation(keyPath: track.keyPath)
        animation.values = track.values.map { $0 * scale }
        animation.keyTimes = (track.keyTimes ?? (0 ..< count).map { Double($0) / Double(max(count - 1, 1)) }).map(NSNumber.init(value:))
        animation.timingFunctions = track.timings.map { $0.map { CAMediaTimingFunction(name: $0) } }
            ?? Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: max(count - 1, 0))
        animation.duration = duration
        animation.beginTime = begin
        animation.repeatCount = repeats ? .infinity : 1
        animation.isRemovedOnCompletion = !repeats
        animation.preferredFrameRateRange = clip.frameRate
        return animation
    }

    // MARK: Music level

    /// With the real spectrum on, the bounce follows how loud the music is.
    /// Eight reads a second, and the animation is only replaced when the level
    /// moves into another band, so most ticks do nothing at all.
    @MainActor
    private func startLevelTimer(clip: CatClip, side: CGFloat) {
        stopLevelTimer()
        SpectrumAnalyzer.shared.acquire()
        holdsAnalyzer = true
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.25, repeating: .milliseconds(125), leeway: .milliseconds(60))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.applyLevel(clip: clip, side: side) }
        }
        levelTimer = timer
        timer.resume()
    }

    private func stopLevelTimer() {
        levelTimer?.cancel()
        levelTimer = nil
        if holdsAnalyzer {
            holdsAnalyzer = false
            MainActor.assumeIsolated { SpectrumAnalyzer.shared.release() }
        }
    }

    @MainActor
    private func applyLevel(clip: CatClip, side: CGFloat) {
        let levels = (0 ..< 4).compactMap { SpectrumAnalyzer.shared.level($0) }
        let amplitude: Double
        if levels.isEmpty {
            amplitude = 1
        } else {
            let mean = levels.reduce(0, +) / Double(levels.count)
            amplitude = ((0.4 + 1.2 * mean) * 4).rounded() / 4
        }
        guard amplitude != bobAmplitude, let track = bobTrack else { return }
        bobAmplitude = amplitude
        // Same begin time as before, so the bounce keeps its phase.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sprite.add(
            motion(track, side: side, amplitude: amplitude, duration: clip.loopDuration, repeats: true, begin: loopBegin, clip: clip),
            forKey: "loopMotion0"
        )
        CATransaction.commit()
    }
}
