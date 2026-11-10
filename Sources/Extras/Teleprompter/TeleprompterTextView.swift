//
//  TeleprompterTextView.swift
//  FunNotch
//
//  The scrolling text of the teleprompter, built on Core Animation instead of
//  SwiftUI. One layer holds the whole laid-out script; scrolling is a single
//  CABasicAnimation of its position from where it is now to the end, with a
//  duration worked out from the words that remain and the reading speed. While
//  it runs nothing in the app executes per frame: the render server moves the
//  layer. Pausing reads the presentation layer, removes the animation and
//  writes the model value, so the text stops exactly where it was drawn.
//
//  Dimming and the soft fade at top and bottom are one static gradient mask, so
//  text that is further from the reading line is dimmer without any per-line
//  work. Only the few slices of the script near the reading line carry a
//  bitmap; a one-shot timer, armed only while a timed scroll is running, moves
//  that window along.
//

import AppKit
import QuartzCore

@MainActor
final class TeleprompterTextView: NSView, CAAnimationDelegate {
    static let sidePadding: CGFloat = 28
    /// Where the reading line sits, measured down from the top of the view.
    static let readingFraction: CGFloat = 0.34

    private enum Motion { case timed, jump }

    /// Called when a timed scroll reaches the end of the text.
    var onFinished: (() -> Void)?

    private let clipLayer = CALayer()
    private let fadeMask = CAGradientLayer()
    private let contentLayer = CALayer()
    private(set) var textLayout: TeleprompterTextLayout?

    private var chunkLayers: [Int: TeleprompterChunkLayer] = [:]
    /// Model value: the offset the text rests at, or is heading for while an
    /// animation runs.
    private var offset: CGFloat = 0
    private var animation: CAAnimation?
    private var animationToken = 0
    private var motion = Motion.timed
    private var jumpCompletion: (() -> Void)?
    private var refreshTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        contentLayer.anchorPoint = .zero

        // Brightest at the reading line, fading out above and below it.
        let stops: [(location: Double, alpha: CGFloat)] = [
            (0.0, 0.0), (0.14, 0.38), (Double(Self.readingFraction), 1.0),
            (0.62, 0.5), (0.86, 0.2), (1.0, 0.0),
        ]
        fadeMask.colors = stops.map { NSColor(white: 1, alpha: $0.alpha).cgColor }
        fadeMask.locations = stops.map { NSNumber(value: $0.location) }
        // Layers are y-up here: (0.5, 1) is the top edge.
        fadeMask.startPoint = CGPoint(x: 0.5, y: 1)
        fadeMask.endPoint = CGPoint(x: 0.5, y: 0)

        clipLayer.addSublayer(contentLayer)
        clipLayer.mask = fadeMask
        layer?.addSublayer(clipLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var mouseDownCanMoveWindow: Bool { true }

    // MARK: - Geometry

    /// The width the script is laid out in.
    var textWidth: CGFloat { max(120, bounds.width - 2 * Self.sidePadding) }

    private var readingY: CGFloat { bounds.height * (1 - Self.readingFraction) }

    private func positionY(forOffset value: CGFloat) -> CGFloat {
        readingY - (textLayout?.height ?? 0) + value
    }

    private func offset(forPositionY y: CGFloat) -> CGFloat {
        y - readingY + (textLayout?.height ?? 0)
    }

    private func clamped(_ value: CGFloat) -> CGFloat {
        guard let layout = textLayout else { return 0 }
        return min(max(value, layout.startOffset), layout.endOffset)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clipLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        clipLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        fadeMask.frame = clipLayer.bounds
        if animation == nil {
            contentLayer.position = CGPoint(x: Self.sidePadding, y: positionY(forOffset: offset))
        }
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // A different screen means a different pixel density; redraw the slices.
        guard textLayout != nil else { return }
        removeAllChunks()
        refreshChunks(around: [currentOffset()])
    }

    func setMirrored(_ mirrored: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clipLayer.transform = mirrored ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity
        CATransaction.commit()
    }

    // MARK: - Content

    /// Replaces the script. The text rests at `start`, or at the first line.
    func setLayout(_ newLayout: TeleprompterTextLayout, startingAt start: CGFloat?) {
        stopAnimation()
        removeAllChunks()
        textLayout = newLayout
        offset = clamped(start ?? newLayout.startOffset)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.bounds = CGRect(x: 0, y: 0, width: newLayout.width, height: newLayout.height)
        contentLayer.position = CGPoint(x: Self.sidePadding, y: positionY(forOffset: offset))
        CATransaction.commit()
        refreshChunks(around: [offset])
    }

    /// Releases everything: animation, timer, slices. Called before the view
    /// is dropped.
    func teardown() {
        animation = nil
        jumpCompletion = nil
        onFinished = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        contentLayer.removeAllAnimations()
        removeAllChunks()
        textLayout = nil
    }

    // MARK: - Position

    /// The offset the text is at right now, mid-animation included.
    func currentOffset() -> CGFloat {
        guard animation != nil, let y = contentLayer.presentation()?.position.y else { return offset }
        return clamped(offset(forPositionY: y))
    }

    var isAtEnd: Bool {
        guard let layout = textLayout else { return true }
        return currentOffset() >= layout.endOffset - 1
    }

    /// Puts the text at `value` immediately.
    func setOffset(_ value: CGFloat) {
        stopAnimation()
        offset = clamped(value)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.position = CGPoint(x: Self.sidePadding, y: positionY(forOffset: offset))
        CATransaction.commit()
        refreshChunks(around: [offset])
    }

    // MARK: - Motion

    /// Scrolls from the current position to the end at `wordsPerMinute`. Calling
    /// it again while running restarts from wherever the text has got to.
    func play(wordsPerMinute: Double) {
        guard let layout = textLayout, !layout.words.isEmpty else { return }
        let from = currentOffset()
        let remaining = max(1, layout.words.count - layout.wordIndex(atOffset: from))
        let duration = Double(remaining) * 60 / max(wordsPerMinute, 1)
        animate(to: layout.endOffset, duration: duration, timing: .linear, motion: .timed, completion: nil)
    }

    /// Freezes the text where it is.
    func pause() {
        jumpCompletion = nil
        stopAnimation()
        refreshChunks(around: [offset])
    }

    /// A short eased move, for voice following and the back/restart keys.
    /// `completion` runs only if the move finishes undisturbed.
    func jump(toOffset target: CGFloat, duration: CFTimeInterval = 0.4, completion: (() -> Void)? = nil) {
        animate(to: target, duration: duration, timing: .easeInEaseOut, motion: .jump, completion: completion)
    }

    private func animate(
        to rawTarget: CGFloat, duration: CFTimeInterval, timing: CAMediaTimingFunctionName,
        motion: Motion, completion: (() -> Void)?
    ) {
        guard textLayout != nil else { return }
        let from = currentOffset()
        stopAnimation()
        jumpCompletion = completion
        let target = clamped(rawTarget)
        self.motion = motion

        guard duration > 0.01, abs(target - from) > 0.5 else {
            offset = target
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            contentLayer.position = CGPoint(x: Self.sidePadding, y: positionY(forOffset: target))
            CATransaction.commit()
            refreshChunks(around: [target])
            let done = jumpCompletion
            jumpCompletion = nil
            switch motion {
            case .timed: onFinished?()
            case .jump: done?()
            }
            return
        }

        refreshChunks(around: [from, target])

        animationToken += 1
        let move = CABasicAnimation(keyPath: "position.y")
        move.fromValue = positionY(forOffset: from)
        move.toValue = positionY(forOffset: target)
        move.duration = duration
        move.timingFunction = CAMediaTimingFunction(name: timing)
        move.delegate = self
        // The layer holds a copy of the animation, so the delegate callback
        // cannot be matched by identity; the token travels with the copy.
        move.setValue(animationToken, forKey: "token")

        offset = target
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.position = CGPoint(x: Self.sidePadding, y: positionY(forOffset: target))
        contentLayer.add(move, forKey: "scroll")
        CATransaction.commit()
        animation = move

        if motion == .timed { scheduleRefresh() }
    }

    /// Reads the presentation value, removes any running animation and leaves
    /// the layer exactly there.
    private func stopAnimation() {
        guard animation != nil else { return }
        let current = currentOffset()
        animation = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        offset = current
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.removeAnimation(forKey: "scroll")
        contentLayer.position = CGPoint(x: Self.sidePadding, y: positionY(forOffset: current))
        CATransaction.commit()
    }

    nonisolated func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        MainActor.assumeIsolated {
            guard flag, animation != nil,
                  let token = anim.value(forKey: "token") as? Int, token == animationToken else { return }
            animation = nil
            refreshTimer?.invalidate()
            refreshTimer = nil
            refreshChunks(around: [offset])
            let done = jumpCompletion
            jumpCompletion = nil
            switch motion {
            case .timed: onFinished?()
            case .jump: done?()
            }
        }
    }

    // MARK: - Slices

    /// Keeps bitmaps for the slices around the reading line only: one view
    /// height behind it and two ahead, which at the fastest pace is many
    /// seconds of scrolling.
    private func refreshChunks(around offsets: [CGFloat]) {
        guard let layout = textLayout else { return }
        let height = bounds.height
        var wanted = Set<Int>()
        for value in offsets {
            let top = value - height * Self.readingFraction - height
            let bottom = value + height * (1 - Self.readingFraction) + 2 * height
            for (index, chunk) in layout.chunks.enumerated()
            where chunk.top + chunk.height > top && chunk.top < bottom {
                wanted.insert(index)
            }
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in Array(chunkLayers.keys) where !wanted.contains(index) {
            chunkLayers[index]?.removeFromSuperlayer()
            chunkLayers[index] = nil
        }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for index in wanted where chunkLayers[index] == nil {
            let chunk = layout.chunks[index]
            let slice = TeleprompterChunkLayer()
            slice.layout = layout
            slice.chunk = chunk
            slice.contentsScale = scale
            slice.anchorPoint = .zero
            slice.bounds = CGRect(x: 0, y: 0, width: layout.width, height: chunk.height)
            slice.position = CGPoint(x: 0, y: layout.height - (chunk.top + chunk.height))
            contentLayer.addSublayer(slice)
            slice.setNeedsDisplay()
            chunkLayers[index] = slice
        }
        CATransaction.commit()
    }

    private func removeAllChunks() {
        for slice in chunkLayers.values { slice.removeFromSuperlayer() }
        chunkLayers.removeAll()
    }

    /// One shot, re-armed from its own callback, and only while a timed scroll
    /// is running; it never exists while the prompter is paused.
    private func scheduleRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshTimer = nil
                guard self.animation != nil else { return }
                self.refreshChunks(around: [self.currentOffset()])
                self.scheduleRefresh()
            }
        }
    }
}
