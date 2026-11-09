//
//  DecorMascots.swift
//  FunNotch
//
//  Small animated animals and a rocket, drawn with SwiftUI paths, that ride a
//  progress track beside the countdown. They are drawn on a 20×14 grid facing
//  right and scaled to fit, so one set of coordinates serves every size.
//

import SwiftUI

// MARK: - Animation clock

private struct DecorAnimationsPausedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while nothing the user can see should animate: the notch is
    /// hidden for a fullscreen video, say. The root of the notch sets it.
    var decorAnimationsPaused: Bool {
        get { self[DecorAnimationsPausedKey.self] }
        set { self[DecorAnimationsPausedKey.self] = newValue }
    }
}

enum DecorClock {
    /// Every decoration redraws at this rate and no faster. These are 20×14
    /// pixel animals and a bouncing GIF beside the camera; a display-rate
    /// timeline made SwiftUI re-evaluate them (and everything it reports up to)
    /// 30–60 times a second, which showed up as a steady share of a core.
    static let framesPerSecond = 12.0

    /// A schedule that ticks on the same grid for everybody, so views that
    /// appear at different moments still land on shared frame boundaries.
    static var schedule: PeriodicTimelineSchedule {
        .periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: 1 / framesPerSecond)
    }
}

/// One mascot drawn at a fixed size. The timeline lives inside this view and
/// only its canvas changes between frames, so a frame costs a 20×14 draw and
/// never reaches layout; `drawingGroup` keeps even that in its own layer.
struct DecorMascotCanvas: View {
    let mascot: DecorMascot
    /// False freezes the animation, e.g. when a countdown is paused.
    var isMoving = true
    var scale: CGFloat = 1

    static let grid = CGSize(width: 20, height: 14)

    @Environment(\.decorAnimationsPaused) private var paused

    var body: some View {
        Group {
            if isMoving && !paused {
                TimelineView(DecorClock.schedule) { context in
                    canvas(time: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                canvas(time: 0)
            }
        }
        .frame(width: Self.grid.width * scale, height: Self.grid.height * scale)
        .drawingGroup()
        .accessibilityHidden(true)
    }

    private func canvas(time: Double) -> some View {
        Canvas { context, _ in
            context.scaleBy(x: scale, y: scale)
            DecorMascotArt.draw(mascot, in: &context, time: time)
        }
        .frame(width: Self.grid.width * scale, height: Self.grid.height * scale)
    }
}

// MARK: - Views

/// A mascot walking along a thin track; how far it has got is how much of the
/// countdown has gone.
struct DecorMascotTrack: View {
    let mascot: DecorMascot
    /// 0 at the start of the countdown, 1 at the end.
    let progress: Double
    var tint: Color = .white
    /// False freezes the animation, e.g. when a countdown is paused.
    var isMoving = true

    static let width: CGFloat = 56
    static let height: CGFloat = 20
    /// Gap between the camera cutout and the track in the closed notch.
    static let cameraGap: CGFloat = 6
    private static let figure = DecorMascotCanvas.grid

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // The track: a hairline, with the part already covered lit.
            Capsule()
                .fill(.white.opacity(0.18))
                .frame(width: Self.width, height: 2)
            Capsule()
                .fill(tint.opacity(0.9))
                .frame(width: max(Self.width * clamped, 2), height: 2)

            if mascot != .none {
                DecorMascotCanvas(mascot: mascot, isMoving: isMoving)
                    .offset(x: (Self.width - Self.figure.width) * clamped, y: -3)
            }
        }
        .frame(width: Self.width, height: Self.height, alignment: .bottomLeading)
        .accessibilityHidden(true)
    }

    /// Progress to the nearest 1/200 of the track (a quarter of a point).
    /// The timer manager publishes `remaining` thirty times a second while a
    /// timer runs; unquantised, the track moved 30 times a second by amounts
    /// no pixel can show.
    private var clamped: CGFloat {
        CGFloat((min(max(progress, 0), 1) * 200).rounded() / 200)
    }
}

/// A single mascot on its own, for the settings picker.
struct DecorMascotFigure: View {
    let mascot: DecorMascot
    var scale: CGFloat = 1.6

    var body: some View {
        DecorMascotCanvas(mascot: mascot, scale: scale)
    }
}

// MARK: - Art

enum DecorMascotArt {
    static func draw(_ mascot: DecorMascot, in context: inout GraphicsContext, time: Double) {
        switch mascot {
        case .none: break
        case .cat: cat(&context, time)
        case .dog: dog(&context, time)
        case .snail: snail(&context, time)
        case .rocket: rocket(&context, time)
        }
    }

    // MARK: Helpers

    private static func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    private static func triangle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Path {
        var path = Path()
        path.move(to: a)
        path.addLine(to: b)
        path.addLine(to: c)
        path.closeSubpath()
        return path
    }

    private static func dot(_ context: inout GraphicsContext, _ x: Double, _ y: Double, _ r: Double, _ color: Color) {
        context.fill(Path(ellipseIn: rect(x - r, y - r, r * 2, r * 2)), with: .color(color))
    }

    /// A pair of legs that swing against each other, `phase` apart.
    private static func legs(
        _ context: inout GraphicsContext, xs: [Double], top: Double, length: Double,
        time: Double, speed: Double, color: Color
    ) {
        for (index, x) in xs.enumerated() {
            let swing = sin(time * speed + Double(index) * .pi) * 1.1
            var path = Path()
            path.move(to: CGPoint(x: x, y: top))
            path.addLine(to: CGPoint(x: x + swing, y: top + length))
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
    }

    // MARK: Cat

    private static func cat(_ context: inout GraphicsContext, _ t: Double) {
        let fur = Color(red: 0.98, green: 0.64, blue: 0.27)
        let dark = Color(red: 0.72, green: 0.4, blue: 0.12)
        let bob = abs(sin(t * 9)) * -0.7
        context.translateBy(x: 0, y: bob)

        // Tail first, so it sits behind the body and sways.
        var tail = Path()
        let sway = sin(t * 5) * 2
        tail.move(to: CGPoint(x: 3, y: 8))
        tail.addQuadCurve(to: CGPoint(x: 0.5 + sway * 0.2, y: 2.5 + sway), control: CGPoint(x: -1, y: 8))
        context.stroke(tail, with: .color(dark), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))

        legs(&context, xs: [5, 7.5, 10, 12], top: 10.5, length: 3, time: t, speed: 14, color: dark)
        context.fill(Path(ellipseIn: rect(2.5, 5.5, 11, 6)), with: .color(fur))

        // Head, ears, face.
        context.fill(Path(ellipseIn: rect(11.5, 2.2, 7, 6.4)), with: .color(fur))
        context.fill(triangle(CGPoint(x: 12, y: 4.2), CGPoint(x: 12.4, y: 0.6), CGPoint(x: 14.4, y: 2.8)), with: .color(fur))
        context.fill(triangle(CGPoint(x: 15.6, y: 2.8), CGPoint(x: 17.6, y: 0.6), CGPoint(x: 18, y: 4.2)), with: .color(fur))
        let blink = sin(t * 1.3) > 0.96
        dot(&context, 14.2, 5.2, blink ? 0.25 : 0.7, .black)
        dot(&context, 16.8, 5.2, blink ? 0.25 : 0.7, .black)
        dot(&context, 15.5, 6.6, 0.5, Color(red: 0.95, green: 0.45, blue: 0.5))
        var whiskers = Path()
        whiskers.move(to: CGPoint(x: 17.2, y: 6.6)); whiskers.addLine(to: CGPoint(x: 19.6, y: 6))
        whiskers.move(to: CGPoint(x: 17.2, y: 7.2)); whiskers.addLine(to: CGPoint(x: 19.6, y: 7.8))
        context.stroke(whiskers, with: .color(.white.opacity(0.8)), lineWidth: 0.5)
    }

    // MARK: Dog

    private static func dog(_ context: inout GraphicsContext, _ t: Double) {
        let coat = Color(red: 0.86, green: 0.68, blue: 0.45)
        let patch = Color(red: 0.5, green: 0.31, blue: 0.17)
        let bob = abs(sin(t * 10)) * -0.8
        context.translateBy(x: 0, y: bob)

        // The tail goes like a metronome.
        var tail = Path()
        let wag = sin(t * 16) * 1.8
        tail.move(to: CGPoint(x: 3, y: 6.5))
        tail.addLine(to: CGPoint(x: 0.6 + wag, y: 3))
        context.stroke(tail, with: .color(patch), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))

        legs(&context, xs: [5, 7.5, 10, 12], top: 10.5, length: 3, time: t, speed: 16, color: patch)
        context.fill(Path(roundedRect: rect(2.5, 5.3, 11.5, 6), cornerRadius: 3), with: .color(coat))
        context.fill(Path(ellipseIn: rect(4.5, 5.6, 4.5, 4)), with: .color(patch.opacity(0.85)))

        // Head with a snout, and a floppy ear that flaps with each step.
        context.fill(Path(ellipseIn: rect(11.6, 2, 6.2, 6.4)), with: .color(coat))
        context.fill(Path(roundedRect: rect(15.4, 4.6, 4.2, 3.2), cornerRadius: 1.4), with: .color(coat))
        dot(&context, 19.2, 5.3, 0.9, .black)
        dot(&context, 15.2, 4.6, 0.65, .black)
        var ear = Path()
        let flap = sin(t * 10) * 0.8
        ear.move(to: CGPoint(x: 12.8, y: 3))
        ear.addQuadCurve(to: CGPoint(x: 12.4, y: 7.8 + flap), control: CGPoint(x: 10.6, y: 5))
        ear.addQuadCurve(to: CGPoint(x: 14.4, y: 3.2), control: CGPoint(x: 14.2, y: 6))
        ear.closeSubpath()
        context.fill(ear, with: .color(patch))
    }

    // MARK: Snail

    private static func snail(_ context: inout GraphicsContext, _ t: Double) {
        let body = Color(red: 0.93, green: 0.84, blue: 0.62)
        let shell = Color(red: 0.7, green: 0.45, blue: 0.82)
        // Slow, stretching crawl rather than a bounce.
        let stretch = 1 + sin(t * 3) * 0.05
        context.translateBy(x: 0, y: 14)
        context.scaleBy(x: stretch, y: 1)
        context.translateBy(x: 0, y: -14)

        context.fill(Path(roundedRect: rect(0.5, 10, 16.5, 3.4), cornerRadius: 1.7), with: .color(body))
        context.fill(Path(ellipseIn: rect(14.2, 6.4, 4.6, 6.6)), with: .color(body))

        // Antennae wave slightly out of step.
        for (index, base) in [16.0, 18.0].enumerated() {
            let lean = sin(t * 4 + Double(index)) * 0.8
            var feeler = Path()
            feeler.move(to: CGPoint(x: base, y: 7.4))
            feeler.addLine(to: CGPoint(x: base + 0.8 + lean, y: 3.4))
            context.stroke(feeler, with: .color(body), style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
            dot(&context, base + 0.8 + lean, 3.2, 0.9, body)
        }
        dot(&context, 17.9, 8.6, 0.55, .black)

        // The shell, with its spiral.
        context.fill(Path(ellipseIn: rect(2.2, 1.6, 10.6, 10.6)), with: .color(shell))
        var spiral = Path()
        var angle = 0.0
        var radius = 0.4
        spiral.move(to: CGPoint(x: 7.5, y: 6.9))
        while angle < .pi * 4 {
            angle += 0.35
            radius += 0.17
            spiral.addLine(to: CGPoint(x: 7.5 + cos(angle) * radius, y: 6.9 + sin(angle) * radius))
        }
        context.stroke(spiral, with: .color(.white.opacity(0.75)), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
    }

    // MARK: Rocket

    private static func rocket(_ context: inout GraphicsContext, _ t: Double) {
        let hull = Color(red: 0.94, green: 0.95, blue: 0.98)
        let red = Color(red: 0.92, green: 0.28, blue: 0.3)
        // A gentle hover; the flame does the visible work.
        context.translateBy(x: 0, y: sin(t * 7) * 0.5)

        let flame = 3.2 + sin(t * 32) * 0.9 + sin(t * 19) * 0.6
        context.fill(
            triangle(CGPoint(x: 4.6, y: 4.6), CGPoint(x: 4.6, y: 9.4), CGPoint(x: 4.6 - flame, y: 7)),
            with: .color(Color(red: 1, green: 0.62, blue: 0.2))
        )
        context.fill(
            triangle(CGPoint(x: 4.6, y: 5.8), CGPoint(x: 4.6, y: 8.2), CGPoint(x: 4.6 - flame * 0.55, y: 7)),
            with: .color(Color(red: 1, green: 0.92, blue: 0.5))
        )

        // Fins behind, hull, nose, porthole.
        context.fill(triangle(CGPoint(x: 5, y: 4.4), CGPoint(x: 9, y: 4.4), CGPoint(x: 4.4, y: 0.8)), with: .color(red))
        context.fill(triangle(CGPoint(x: 5, y: 9.6), CGPoint(x: 9, y: 9.6), CGPoint(x: 4.4, y: 13.2)), with: .color(red))
        context.fill(Path(roundedRect: rect(4.6, 4.2, 10, 5.6), cornerRadius: 2.4), with: .color(hull))
        context.fill(triangle(CGPoint(x: 13.2, y: 4.3), CGPoint(x: 13.2, y: 9.7), CGPoint(x: 19.6, y: 7)), with: .color(red))
        dot(&context, 10.4, 7, 1.7, Color(red: 0.35, green: 0.62, blue: 0.95))
        context.stroke(
            Path(ellipseIn: rect(8.7, 5.3, 3.4, 3.4)),
            with: .color(Color(red: 0.55, green: 0.6, blue: 0.7)), lineWidth: 0.6
        )
    }
}
