//
//  DecorAnimation.swift
//  FunNotch
//
//  Decodes an animated GIF or APNG into frames and plays it back at a speed
//  of the user's choosing. `NSImageView` can animate a GIF too, but only at
//  the file's own pace; the sliders need a clock we control.
//

import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Decoded frames with their delays. Immutable once built, so it is safe to
/// hand from the decoding task to the main actor.
struct DecorAnimation: @unchecked Sendable {
    let frames: [CGImage]
    /// Seconds each frame stays up, same count as `frames`.
    let delays: [Double]
    let duration: Double
    /// Width over height of one frame.
    let aspect: CGFloat

    var isStatic: Bool { frames.count < 2 }

    /// Frames are shrunk to this on decode: the notch draws them at well under
    /// 100 points, and a full-size GIF would cost tens of megabytes.
    private static let maxPixels = 256
    /// Long animations are thinned out to about this many frames.
    private static let maxFrames = 240

    static let supportedTypes: [UTType] = [.gif, .png]

    /// Reads every frame of `url`, or nil when it is not an image at all.
    nonisolated static func load(from url: URL) -> DecorAnimation? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let total = CGImageSourceGetCount(source)
        guard total > 0 else { return nil }

        let step = max(1, Int((Double(total) / Double(maxFrames)).rounded(.up)))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels
        ]

        var frames: [CGImage] = []
        var delays: [Double] = []
        var pending = 0.0

        for index in 0 ..< total {
            pending += delay(of: source, at: index)
            // Skipped frames lend their time to the one that is kept, so the
            // loop lasts as long as the original.
            guard index % step == 0 else { continue }
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
                continue
            }
            frames.append(frame)
            delays.append(pending)
            pending = 0
        }
        guard let first = frames.first, first.height > 0 else { return nil }

        return DecorAnimation(
            frames: frames,
            delays: delays,
            duration: max(delays.reduce(0, +), 0.01),
            aspect: CGFloat(first.width) / CGFloat(first.height)
        )
    }

    /// The frame to show `seconds` into the loop. `speed` stretches time.
    func frame(at seconds: Double, speed: Double) -> CGImage {
        guard frames.count > 1 else { return frames[0] }
        var t = (seconds * speed).truncatingRemainder(dividingBy: duration)
        if t < 0 { t += duration }
        var elapsed = 0.0
        for (index, delay) in delays.enumerated() {
            elapsed += delay
            if t < elapsed { return frames[index] }
        }
        return frames[frames.count - 1]
    }

    /// GIF and APNG keep their timing in different dictionaries. Browsers
    /// treat a delay under about 20 ms as "unspecified" and use 100 ms; this
    /// does the same so files play at the pace their authors saw.
    private nonisolated static func delay(of source: CGImageSource, at index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
            return 0.1
        }
        var value: Double?
        if let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            value = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif[kCGImagePropertyGIFDelayTime] as? Double)
        } else if let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
            value = (png[kCGImagePropertyAPNGUnclampedDelayTime] as? Double)
                ?? (png[kCGImagePropertyAPNGDelayTime] as? Double)
        }
        guard let value, value >= 0.02 else { return 0.1 }
        return value
    }
}

// MARK: - Playback

/// Draws `animation` at `size`, advancing on the wall clock.
struct DecorAnimationView: View {
    let animation: DecorAnimation
    let speed: Double
    let size: CGSize

    var body: some View {
        Group {
            if animation.isStatic {
                image(animation.frames[0])
            } else {
                // 24 fps is more than any GIF asks for and keeps the idle
                // notch from costing a full 60 Hz redraw.
                TimelineView(.animation(minimumInterval: 1.0 / 24)) { context in
                    image(animation.frame(at: context.date.timeIntervalSinceReferenceDate, speed: speed))
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }

    private func image(_ frame: CGImage) -> some View {
        Image(decorative: frame, scale: 1)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
    }
}

// MARK: - In the closed notch

/// The idle picture beside the camera cutout.
struct DecorIdleView: View {
    @ObservedObject private var store = DecorStore.shared

    var body: some View {
        if store.idleIsReady, let animation = store.idleAnimation {
            DecorAnimationView(animation: animation, speed: store.idleSpeed, size: store.idleSize)
                .offset(y: CGFloat(store.idleOffsetY))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
