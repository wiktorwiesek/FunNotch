//
//  CatArt.swift
//  FunNotch
//
//  Draws one pose of the cat with vector paths, on a 100 × 100 grid with y
//  pointing down. The cat is a small fluffy semi-longhaired kitten in diluted
//  tortie-and-white: blue-grey fur with lighter and darker streaks, cream
//  patches (a stripe down the forehead, one cheek, the hip), a white chin,
//  muzzle and bib, white socks, big hazel eyes, a slate nose and long white
//  whiskers. Edges are scalloped rather than smooth so the coat looks soft,
//  and every shape has a light rim outside and a thin dark line inside, so the
//  grey neither vanishes into the notch's black nor melts into itself where
//  one part overlaps another. The accent colour goes on the collar and on the
//  prop of the moment (laptop glow, "!", note, "z").
//
//  This runs once per distinct pose, size and tint (see `CatFrameCache`),
//  never per frame.
//

import CoreGraphics
import Foundation

enum CatArt {
    // MARK: Palette

    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    private static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(
            srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha
        )
    }

    private static let gray = rgb(0x7C7F86)
    private static let grayLight = rgb(0x9A9DA4)
    private static let grayDark = rgb(0x5E6168)
    private static let cream = rgb(0xE8C9A6)
    private static let creamDeep = rgb(0xD9B08C)
    private static let white = rgb(0xF7F7F9)
    private static let pad = rgb(0xE9A3A9)
    private static let iris = rgb(0x9DA67A)
    private static let nose = rgb(0x4A4D52)
    private static let ink = rgb(0x1E1F23)
    private static let earInside = rgb(0xB9B1AB)
    /// Outside the shape: keeps grey fur visible against black.
    private static let rim = rgb(0xC4C8D0, 0.55)
    /// Inside the shape: separates one part from another.
    private static let edge = rgb(0x3E4046, 0.7)

    private enum Fur {
        case gray, white, grayLight

        var colors: (top: CGColor, bottom: CGColor) {
            switch self {
            case .gray: return (CatArt.grayLight, CatArt.rgb(0x686B72))
            case .white: return (CatArt.white, CatArt.rgb(0xD3D4DB))
            case .grayLight: return (CatArt.rgb(0xA9ACB3), CatArt.gray)
            }
        }
    }

    // MARK: Entry

    /// The pose as an image `pixels` square. `tint` is the accent as RGBA 0…1.
    static func image(_ pose: CatPose, pixels: Int, tint: (r: Double, g: Double, b: Double, a: Double)) -> CGImage? {
        guard pixels > 0,
              let context = CGContext(
                  data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
              )
        else { return nil }
        context.setAllowsAntialiasing(true)
        context.interpolationQuality = .high
        // y down, 100 units across.
        context.translateBy(x: 0, y: CGFloat(pixels))
        context.scaleBy(x: CGFloat(pixels) / 100, y: -CGFloat(pixels) / 100)
        let accent = CGColor(srgbRed: tint.r, green: tint.g, blue: tint.b, alpha: tint.a)
        // Fine detail (mouth, toe lines) is mush below this and only costs fill.
        draw(pose, in: context, accent: accent, detailed: pixels >= 40)
        return context.makeImage()
    }

    private static func draw(_ pose: CatPose, in c: CGContext, accent: CGColor, detailed: Bool) {
        switch pose.body {
        case .sit: drawSitting(pose, c, accent, detailed)
        case .curled: drawCurled(pose, c, accent, detailed)
        case .walk: drawWalking(pose, c, accent, detailed)
        case .peek: drawPeeking(pose, c, accent, detailed)
        }
    }

    // MARK: Fluffy shapes

    /// A closed polygon whose every edge bulges outwards a little, like tufts of fur.
    private static func scallop(_ points: [CGPoint], bulge: CGFloat) -> CGPath {
        let path = CGMutablePath()
        guard points.count > 2 else { return path }
        var area: CGFloat = 0
        for index in points.indices {
            let a = points[index]
            let b = points[(index + 1) % points.count]
            area += a.x * b.y - b.x * a.y
        }
        let sign: CGFloat = area > 0 ? 1 : -1
        path.move(to: points[0])
        for index in points.indices {
            let a = points[index]
            let b = points[(index + 1) % points.count]
            let dx = b.x - a.x
            let dy = b.y - a.y
            let length = max(hypot(dx, dy), 0.001)
            let control = CGPoint(
                x: (a.x + b.x) / 2 + sign * dy / length * bulge,
                y: (a.y + b.y) / 2 - sign * dx / length * bulge
            )
            path.addQuadCurve(to: b, control: control)
        }
        path.closeSubpath()
        return path
    }

    /// An ellipse of points with alternating tufts; `ruff` adds the fuller cheeks of a longhair.
    private static func fluffyEllipse(
        _ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, count: Int = 24, ruff: CGFloat = 0, tuft: CGFloat = 0.035
    ) -> [CGPoint] {
        (0 ..< count).map { index in
            let angle = Double(index) / Double(count) * 2 * Double.pi
            var radius = 1 + (index.isMultiple(of: 2) ? tuft : -tuft)
            if ruff > 0 {
                // Lower left and right of the face: the cheek ruff.
                for centre in [0.3 * Double.pi, 0.7 * Double.pi] {
                    let distance = (angle - centre) / (0.14 * Double.pi)
                    radius += Double(ruff) * exp(-distance * distance)
                }
            }
            return CGPoint(x: cx + rx * CGFloat(radius * cos(angle)), y: cy + ry * CGFloat(radius * sin(angle)))
        }
    }

    private static func cubic(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, steps: Int) -> [CGPoint] {
        (0 ..< steps).map { index in
            let t = CGFloat(index) / CGFloat(steps)
            let u = 1 - t
            let x = u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x
            let y = u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y
            return CGPoint(x: x, y: y)
        }
    }

    private static func fluffyEllipsePath(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, count: Int = 18, bulge: CGFloat = 1.1) -> CGPath {
        scallop(fluffyEllipse(cx, cy, rx, ry, count: count), bulge: bulge)
    }

    // MARK: Primitives

    /// Light rim outside, gradient inside, thin dark line on the edge.
    private static func furFill(_ c: CGContext, _ path: CGPath, _ fur: Fur = .gray, rimWidth: CGFloat = 2.8) {
        c.setLineJoin(.round)
        c.addPath(path)
        c.setStrokeColor(rim)
        c.setLineWidth(rimWidth)
        c.strokePath()
        c.saveGState()
        c.addPath(path)
        c.clip()
        let box = path.boundingBox
        let colors = fur.colors
        let gradient = CGGradient(colorsSpace: space, colors: [colors.top, colors.bottom] as CFArray, locations: [0, 1])!
        c.drawLinearGradient(gradient, start: CGPoint(x: 0, y: box.minY), end: CGPoint(x: 0, y: box.maxY), options: [])
        c.restoreGState()
        c.addPath(path)
        c.setStrokeColor(edge)
        c.setLineWidth(0.9)
        c.strokePath()
    }

    /// Runs `body` clipped to `path`, for patches and streaks that must stay inside a shape.
    private static func clipped(_ c: CGContext, to path: CGPath, _ body: () -> Void) {
        c.saveGState()
        c.addPath(path)
        c.clip()
        body()
        c.restoreGState()
    }

    private static func line(_ c: CGContext, _ from: CGPoint, _ to: CGPoint, width: CGFloat, color: CGColor) {
        c.setLineCap(.round)
        c.setStrokeColor(color)
        c.setLineWidth(width)
        c.move(to: from)
        c.addLine(to: to)
        c.strokePath()
    }

    private static func fillEllipse(_ c: CGContext, _ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ color: CGColor) {
        c.setFillColor(color)
        c.fillEllipse(in: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
    }

    private static func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2), transform: nil)
    }

    private static func arc(_ c: CGContext, from: CGPoint, control: CGPoint, to: CGPoint, width: CGFloat, color: CGColor) {
        c.setStrokeColor(color)
        c.setLineWidth(width)
        c.setLineCap(.round)
        c.move(to: from)
        c.addQuadCurve(to: to, control: control)
        c.strokePath()
    }

    private static func polar(_ origin: CGPoint, angle degrees: Double, length: Double, leftSide: Bool) -> CGPoint {
        let radians = degrees * Double.pi / 180
        let direction: Double = leftSide ? -1 : 1
        return CGPoint(
            x: Double(origin.x) + direction * length * sin(radians),
            y: Double(origin.y) + length * cos(radians)
        )
    }

    /// A limb as a capsule: rim, then fur.
    private static func limb(_ c: CGContext, from: CGPoint, to: CGPoint, width: CGFloat, color: CGColor? = nil) {
        c.setLineCap(.round)
        c.setLineJoin(.round)
        c.setStrokeColor(rim)
        c.setLineWidth(width + 2.8)
        c.move(to: from)
        c.addLine(to: to)
        c.strokePath()
        c.setStrokeColor(edge)
        c.setLineWidth(width + 1)
        c.move(to: from)
        c.addLine(to: to)
        c.strokePath()
        c.setStrokeColor(color ?? gray)
        c.setLineWidth(width - 0.4)
        c.move(to: from)
        c.addLine(to: to)
        c.strokePath()
        // A lighter streak down the limb.
        line(c, from, to, width: width * 0.26, color: (color == nil ? grayLight : white).copy(alpha: 0.22) ?? grayLight)
    }

    /// A rounded triangle: rim, then fill.
    private static func triangle(
        _ c: CGContext, _ a: CGPoint, _ b: CGPoint, _ tip: CGPoint, fill: CGColor, rimColor: CGColor = rim, rounding: CGFloat = 4
    ) {
        let path = CGMutablePath()
        path.move(to: a)
        path.addLine(to: tip)
        path.addLine(to: b)
        path.closeSubpath()
        c.setLineJoin(.round)
        c.addPath(path)
        c.setStrokeColor(rimColor)
        c.setLineWidth(rounding + 2.6)
        c.strokePath()
        c.addPath(path)
        c.setFillColor(fill)
        c.setStrokeColor(fill)
        c.setLineWidth(rounding)
        c.drawPath(using: .fillStroke)
    }

    /// A bushy tail: overlapping tufts along a curve, fuller in the middle, with the rim drawn first.
    private static func bushyTail(_ c: CGContext, along points: [CGPoint], radii: [CGFloat]) {
        for (point, radius) in zip(points, radii) { fillEllipse(c, point.x, point.y, radius + 1.4, radius + 1.4, rim) }
        for (index, (point, radius)) in zip(points, radii).enumerated() {
            let shade = index.isMultiple(of: 2) ? gray : rgb(0x73767D)
            fillEllipse(c, point.x, point.y, radius, radius, shade)
        }
        // Light and dark streaks along the middle.
        if let first = points.first {
            c.setLineCap(.round)
            c.setLineWidth(1.8)
            c.setStrokeColor(grayLight.copy(alpha: 0.7) ?? grayLight)
            c.move(to: CGPoint(x: first.x + 1, y: first.y - 1))
            for point in points.dropFirst() { c.addLine(to: CGPoint(x: point.x + 1.4, y: point.y - 1.2)) }
            c.strokePath()
            c.setStrokeColor(grayDark.copy(alpha: 0.55) ?? grayDark)
            c.move(to: CGPoint(x: first.x - 1.5, y: first.y + 1.5))
            for point in points.dropFirst() { c.addLine(to: CGPoint(x: point.x - 1.8, y: point.y + 1.4)) }
            c.strokePath()
            c.setLineWidth(1)
        }
    }

    // MARK: Face

    private static func eye(
        _ c: CGContext, x: CGFloat, y: CGFloat, scale s: CGFloat, size: CGFloat = 1, pupil: CGFloat = 1, detailed: Bool, lidded: Bool = false
    ) {
        let rx = 5.0 * s * size
        let ry = 5.7 * s * size
        c.saveGState()
        if lidded {
            c.clip(to: CGRect(x: x - rx - 1, y: y - ry * 0.25, width: rx * 2 + 2, height: ry * 2))
        }
        fillEllipse(c, x, y, rx + 0.9, ry + 0.9, ink)
        fillEllipse(c, x, y, rx, ry, iris)
        // Darker ring at the top of the iris, as in a real eye.
        fillEllipse(c, x, y - ry * 0.35, rx * 0.8, ry * 0.5, rgb(0x7A8560, 0.55))
        fillEllipse(c, x, y + 0.3 * s, 2.3 * s * pupil, 4.4 * s * size * pupil, ink)
        fillEllipse(c, x + 1.7 * s, y - 2.1 * s, 1.35 * s, 1.5 * s, white)
        if detailed { fillEllipse(c, x - 1.6 * s, y + 2.2 * s, 0.7 * s, 0.7 * s, white.copy(alpha: 0.8) ?? white) }
        c.restoreGState()
        if lidded {
            line(c, CGPoint(x: x - rx - 0.5, y: y - ry * 0.25), CGPoint(x: x + rx + 0.5, y: y - ry * 0.25), width: 1.8 * s, color: edge)
        }
    }

    /// Eyes, nose, mouth and whiskers around (cx, cy) = the middle of the face.
    private static func face(
        _ pose: CatPose, _ c: CGContext, cx: CGFloat, cy: CGFloat, scale: CGFloat, detailed: Bool
    ) {
        var shift: CGFloat = 0
        switch pose.eyes {
        case .glanceLeft: shift = -3
        case .glanceRight: shift = 3
        default: break
        }
        let eyeY = cy + 1 + (pose.eyes == .wide ? -1.5 : 0)
        let spread: CGFloat = 12 * scale
        for side: CGFloat in [-1, 1] {
            let x = cx + side * spread + shift
            switch pose.eyes {
            case .open, .glanceLeft, .glanceRight:
                eye(c, x: x, y: eyeY, scale: scale, detailed: detailed)
            case .wide:
                eye(c, x: x, y: eyeY, scale: scale, size: 1.12, pupil: 0.85, detailed: detailed)
            case .blink, .closed:
                arc(c, from: CGPoint(x: x - 4.4 * scale, y: eyeY), control: CGPoint(x: x, y: eyeY + 4 * scale),
                    to: CGPoint(x: x + 4.4 * scale, y: eyeY), width: 2.4 * scale, color: ink)
            case .happy:
                arc(c, from: CGPoint(x: x - 4.4 * scale, y: eyeY + 1.8), control: CGPoint(x: x, y: eyeY - 4.6 * scale),
                    to: CGPoint(x: x + 4.4 * scale, y: eyeY + 1.8), width: 2.6 * scale, color: ink)
            case .focus:
                eye(c, x: x, y: eyeY + 0.8, scale: scale, size: 0.95, detailed: false, lidded: true)
            }
        }

        // Nose, slate, on the white muzzle.
        let noseX = cx + shift
        let noseY = cy + 7.6 * scale
        let nosePath = CGMutablePath()
        nosePath.move(to: CGPoint(x: noseX - 3 * scale, y: noseY - 1.5))
        nosePath.addLine(to: CGPoint(x: noseX + 3 * scale, y: noseY - 1.5))
        nosePath.addLine(to: CGPoint(x: noseX, y: noseY + 2.2))
        nosePath.closeSubpath()
        c.addPath(nosePath)
        c.setFillColor(nose)
        c.setStrokeColor(nose)
        c.setLineJoin(.round)
        c.setLineWidth(1.6)
        c.drawPath(using: .fillStroke)

        if detailed {
            c.setStrokeColor(nose.copy(alpha: 0.9) ?? nose)
            c.setLineWidth(1.1)
            c.setLineCap(.round)
            if pose.smile {
                c.move(to: CGPoint(x: noseX - 4.5 * scale, y: noseY + 3.4))
                c.addQuadCurve(to: CGPoint(x: noseX, y: noseY + 4.6), control: CGPoint(x: noseX - 2.5 * scale, y: noseY + 6.8))
                c.addQuadCurve(to: CGPoint(x: noseX + 4.5 * scale, y: noseY + 3.4), control: CGPoint(x: noseX + 2.5 * scale, y: noseY + 6.8))
            } else {
                c.move(to: CGPoint(x: noseX, y: noseY + 2.2))
                c.addLine(to: CGPoint(x: noseX, y: noseY + 4.2))
            }
            c.strokePath()
        }

        // Long white whiskers, the one thing of the face that has to read on black.
        c.setStrokeColor(white.copy(alpha: 0.92) ?? white)
        c.setLineWidth(detailed ? 1.0 : 1.8)
        c.setLineCap(.round)
        for side: CGFloat in [-1, 1] {
            for tilt: CGFloat in [-5, 0, 5] {
                c.move(to: CGPoint(x: cx + side * 14 * scale + shift, y: cy + 9.5 * scale + tilt * 0.15))
                c.addQuadCurve(
                    to: CGPoint(x: cx + side * 41 * scale + shift, y: cy + 8 * scale + tilt),
                    control: CGPoint(x: cx + side * 27 * scale + shift, y: cy + 6.5 * scale + tilt * 0.5)
                )
            }
        }
        c.strokePath()
    }

    // MARK: Ears and head

    private static func ears(_ pose: CatPose, _ c: CGContext, headCenterY y: CGFloat) {
        for left in [true, false] {
            let fold = CGFloat(left ? pose.earL : pose.earR)
            let sign: CGFloat = left ? -1 : 1
            let cx: CGFloat = 50
            // Big, pointed ears set wide.
            let tip = CGPoint(x: cx + sign * 25 - sign * 3 * fold, y: y - 36 + 6 * fold)
            let outer = CGPoint(x: cx + sign * 27, y: y - 2)
            let inner = CGPoint(x: cx + sign * 5, y: y - 20)
            triangle(c, outer, inner, tip, fill: gray)
            // The inside is lighter and tufted with white.
            let middle = CGPoint(x: (outer.x + inner.x + tip.x) / 3, y: (outer.y + inner.y + tip.y) / 3)
            func pull(_ p: CGPoint, _ t: CGFloat) -> CGPoint {
                CGPoint(x: p.x + (middle.x - p.x) * t, y: p.y + (middle.y - p.y) * t)
            }
            triangle(c, pull(outer, 0.42), pull(inner, 0.42), pull(tip, 0.4), fill: earInside, rimColor: .clear, rounding: 2)
            let start = pull(outer, 0.5)
            let end = pull(inner, 0.5)
            for step in 0 ..< 3 {
                let t = CGFloat(step) / 2
                let base = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                let toward = CGPoint(x: base.x + (middle.x - base.x) * 0.55, y: base.y + (middle.y - base.y) * 0.55)
                line(c, base, toward, width: 2.2, color: white)
            }
        }
    }

    /// Ears, fluffy head with its markings, and the face; the head's centre is (50, 40).
    private static func drawHead(_ pose: CatPose, _ c: CGContext, detailed: Bool) {
        ears(pose, c, headCenterY: 40)
        let head = scallop(fluffyEllipse(50, 40, 27, 22, count: 26, ruff: 0.09), bulge: 1.2)
        furFill(c, head)
        clipped(c, to: head) {
            // Darker and lighter streaks over the brows and the crown.
            for side: CGFloat in [-1, 1] {
                line(c, CGPoint(x: 50 + side * 16, y: 21), CGPoint(x: 50 + side * 11, y: 29), width: 2.4, color: grayDark.copy(alpha: 0.55) ?? grayDark)
                line(c, CGPoint(x: 50 + side * 22, y: 27), CGPoint(x: 50 + side * 18, y: 33), width: 2, color: grayDark.copy(alpha: 0.45) ?? grayDark)
                line(c, CGPoint(x: 50 + side * 9, y: 19), CGPoint(x: 50 + side * 14, y: 24), width: 2, color: grayLight.copy(alpha: 0.8) ?? grayLight)
            }
            // A cream patch on one cheek.
            let cheek = CGMutablePath()
            cheek.addEllipse(in: CGRect(x: 61, y: 43, width: 18, height: 15))
            c.addPath(cheek)
            c.setFillColor(creamDeep.copy(alpha: 0.95) ?? creamDeep)
            c.fillPath()
            fillEllipse(c, 68, 49, 5, 3.5, cream.copy(alpha: 0.8) ?? cream)
            // The stripe down the forehead between the eyes, into the muzzle.
            let stripe = CGMutablePath()
            stripe.move(to: CGPoint(x: 48, y: 17))
            stripe.addLine(to: CGPoint(x: 52, y: 17))
            stripe.addQuadCurve(to: CGPoint(x: 54.5, y: 44), control: CGPoint(x: 52.5, y: 31))
            stripe.addLine(to: CGPoint(x: 45.5, y: 44))
            stripe.addQuadCurve(to: CGPoint(x: 48, y: 17), control: CGPoint(x: 47.5, y: 31))
            stripe.closeSubpath()
            c.addPath(stripe)
            c.setFillColor(cream)
            c.fillPath()
            c.addPath(stripe)
            c.setStrokeColor(creamDeep.copy(alpha: 0.7) ?? creamDeep)
            c.setLineWidth(1)
            c.strokePath()
            // White muzzle and chin.
            let muzzle = fluffyEllipsePath(50, 51, 10.5, 7.5, count: 14, bulge: 0.8)
            c.addPath(muzzle)
            c.setFillColor(white)
            c.fillPath()
            let chin = fluffyEllipsePath(50, 59, 7, 4.5, count: 12, bulge: 0.7)
            c.addPath(chin)
            c.setFillColor(white)
            c.fillPath()
        }
        face(pose, c, cx: 50, cy: 40, scale: 1, detailed: detailed)
    }

    // MARK: Paws

    /// A white-tipped paw: the sock, and the pink pads when it is lifted and shows them.
    private static func paw(_ c: CGContext, at point: CGPoint, raised: Bool, scale: CGFloat = 1) {
        let sock = scallop(fluffyEllipse(point.x, point.y, 6.2 * scale, (raised ? 5.8 : 4.8) * scale, count: 12, tuft: 0.05), bulge: 0.8)
        furFill(c, sock, .white, rimWidth: 2.4)
        if raised {
            // Palm facing us: a main pad and three toe beans.
            fillEllipse(c, point.x, point.y + 1.4 * scale, 2.6 * scale, 2.1 * scale, pad)
            for dx: CGFloat in [-3.2, 0, 3.2] {
                fillEllipse(c, point.x + dx * scale, point.y - 2.4 * scale + (dx == 0 ? -0.6 : 0), 1.15 * scale, 1.3 * scale, pad)
            }
        }
    }

    /// A front leg: grey capsule from the shoulder, a white sock at the end. A
    /// raised one starts further out, so it clears the head.
    private static func drawArm(_ c: CGContext, _ arm: CatArm, left: Bool) {
        let raised = arm.angle > 60
        let shoulder = CGPoint(x: left ? (raised ? 36 : 41) : (raised ? 64 : 59), y: raised ? 66 : 68)
        let end = polar(shoulder, angle: arm.angle, length: arm.reach, leftSide: left)
        limb(c, from: shoulder, to: end, width: 8.5)
        paw(c, at: end, raised: raised)
    }

    // MARK: Sitting

    private static let bodyOutline: [CGPoint] = {
        var points: [CGPoint] = []
        points += cubic(CGPoint(x: 30, y: 95), CGPoint(x: 23, y: 90), CGPoint(x: 26, y: 74), CGPoint(x: 34, y: 66), steps: 5)
        points += cubic(CGPoint(x: 34, y: 66), CGPoint(x: 40, y: 58), CGPoint(x: 44, y: 56), CGPoint(x: 50, y: 56), steps: 4)
        points += cubic(CGPoint(x: 50, y: 56), CGPoint(x: 56, y: 56), CGPoint(x: 60, y: 58), CGPoint(x: 66, y: 66), steps: 4)
        points += cubic(CGPoint(x: 66, y: 66), CGPoint(x: 74, y: 74), CGPoint(x: 77, y: 90), CGPoint(x: 70, y: 95), steps: 5)
        points.append(CGPoint(x: 50, y: 96.5))
        return points
    }()

    private static func drawSitting(_ pose: CatPose, _ c: CGContext, _ accent: CGColor, _ detailed: Bool) {
        // Tail first, behind everything: a bushy plume that leans with `tail`.
        let sway = CGFloat(pose.tail)
        let tailPoints = cubic(
            CGPoint(x: 64, y: 90), CGPoint(x: 92, y: 96), CGPoint(x: 98 + 2 * sway, y: 74),
            CGPoint(x: 86 + 7 * sway, y: 58 - 2 * sway), steps: 9
        )
        bushyTail(c, along: tailPoints, radii: [4.6, 5.4, 6, 6.2, 6.2, 6, 5.6, 5, 4.2])

        // Body, haunches and the arms hanging at rest scale about the floor, so
        // a hop squashes and stretches the cat from its feet.
        let lift = CGFloat(pose.lift)
        let headLift = -1.7 * lift
        c.saveGState()
        c.translateBy(x: 50, y: 94)
        c.scaleBy(x: 1 - 0.03 * lift, y: 1 + 0.06 * lift)
        c.translateBy(x: -50, y: -94)

        let body = scallop(bodyOutline, bulge: 1.3)
        furFill(c, body)
        clipped(c, to: body) {
            // Streaks, a cream patch down the right flank, the white bib.
            line(c, CGPoint(x: 33, y: 70), CGPoint(x: 31, y: 82), width: 2.2, color: grayDark.copy(alpha: 0.5) ?? grayDark)
            line(c, CGPoint(x: 38, y: 64), CGPoint(x: 36, y: 72), width: 2, color: grayLight.copy(alpha: 0.7) ?? grayLight)
            let patch = CGMutablePath()
            patch.addEllipse(in: CGRect(x: 63, y: 62, width: 14, height: 24))
            c.addPath(patch)
            c.setFillColor(creamDeep.copy(alpha: 0.95) ?? creamDeep)
            c.fillPath()
            fillEllipse(c, 70, 70, 3.5, 6, cream.copy(alpha: 0.7) ?? cream)
            let bib = scallop(fluffyEllipse(50, 74, 9.5, 15, count: 16, tuft: 0.07), bulge: 1)
            c.addPath(bib)
            c.setFillColor(white)
            c.fillPath()
        }
        furFill(c, fluffyEllipsePath(32, 86, 11, 10))
        let hip = fluffyEllipsePath(68, 86, 11, 10)
        furFill(c, hip)
        clipped(c, to: hip) {
            fillEllipse(c, 72, 82, 7, 7, creamDeep)
            fillEllipse(c, 73, 80, 3.5, 3.5, cream.copy(alpha: 0.8) ?? cream)
        }
        // Hind feet: one grey, one white sock.
        furFill(c, ellipse(31, 94.5, 6, 3.4), .grayLight, rimWidth: 2.2)
        furFill(c, ellipse(70, 94.5, 6.4, 3.6), .white, rimWidth: 2.2)

        if pose.laptop {
            drawLaptop(pose, c, accent)
        } else {
            for (left, arm) in [(true, pose.armL), (false, pose.armR)] where arm.angle <= 60 {
                drawArm(c, arm, left: left)
            }
        }
        c.restoreGState()

        // Head, tilted about the neck.
        c.saveGState()
        c.translateBy(x: 50, y: 60 + CGFloat(pose.headDY) + headLift)
        c.rotate(by: CGFloat(pose.headTilt) * .pi / 180)
        c.translateBy(x: -50, y: -60)
        drawHead(pose, c, detailed: detailed)
        c.restoreGState()

        // A slim collar on the neck, in the accent: it must not hide the bib.
        c.saveGState()
        c.translateBy(x: 0, y: CGFloat(pose.headDY) + headLift)
        arc(c, from: CGPoint(x: 37, y: 60), control: CGPoint(x: 50, y: 68.5), to: CGPoint(x: 63, y: 60), width: 4.4, color: accent)
        fillEllipse(c, 50, 66, 2.4, 2.4, rgb(0xFFEDB3))
        c.restoreGState()

        // Paws raised past the head sit on top of it.
        c.saveGState()
        c.translateBy(x: 50, y: 94)
        c.scaleBy(x: 1 - 0.03 * lift, y: 1 + 0.06 * lift)
        c.translateBy(x: -50, y: -94)
        for (left, arm) in [(true, pose.armL), (false, pose.armR)] where arm.angle > 60 {
            drawArm(c, arm, left: left)
        }
        c.restoreGState()

        drawProp(pose, c, accent)
    }

    private static func drawLaptop(_ pose: CatPose, _ c: CGContext, _ accent: CGColor) {
        let lid = CGPath(roundedRect: CGRect(x: 22, y: 73, width: 56, height: 25), cornerWidth: 5, cornerHeight: 5, transform: nil)
        c.saveGState()
        c.addPath(lid)
        c.clip()
        let dark = CGGradient(
            colorsSpace: space,
            colors: [rgb(0x30303A), rgb(0x16161C)] as CFArray,
            locations: [0, 1]
        )!
        c.drawLinearGradient(dark, start: CGPoint(x: 0, y: 73), end: CGPoint(x: 0, y: 98), options: [])
        c.restoreGState()
        c.addPath(lid)
        c.setStrokeColor(rgb(0xB8BCC6, 0.8))
        c.setLineWidth(1.8)
        c.strokePath()

        // The logo: a glow that brightens and dims as the cat types.
        let glow = CGFloat(pose.glow)
        fillEllipse(c, 50, 86, 11, 8, accent.copy(alpha: 0.22 * glow) ?? accent)
        fillEllipse(c, 50, 86, 5.2, 5.2, accent.copy(alpha: 0.5 + 0.5 * glow) ?? accent)

        for (x, tap) in [(37, CGFloat(pose.tapL)), (63, CGFloat(pose.tapR))] {
            paw(c, at: CGPoint(x: CGFloat(x), y: 75.5 - 4.5 * tap), raised: false, scale: 1.1)
        }
    }

    // MARK: Curled up

    private static func drawCurled(_ pose: CatPose, _ c: CGContext, _ accent: CGColor, _ detailed: Bool) {
        let lift = CGFloat(pose.lift)
        // Body: a loaf that rises a touch with every breath.
        c.saveGState()
        c.translateBy(x: 50, y: 96)
        c.scaleBy(x: 1 + 0.01 * lift, y: 1 + 0.07 * lift)
        c.translateBy(x: -50, y: -96)
        let body = fluffyEllipsePath(54, 76, 37, 20, count: 30, bulge: 1.4)
        furFill(c, body)
        clipped(c, to: body) {
            line(c, CGPoint(x: 60, y: 60), CGPoint(x: 58, y: 70), width: 2.4, color: grayDark.copy(alpha: 0.5) ?? grayDark)
            line(c, CGPoint(x: 72, y: 62), CGPoint(x: 70, y: 68), width: 2, color: grayDark.copy(alpha: 0.45) ?? grayDark)
            line(c, CGPoint(x: 50, y: 60), CGPoint(x: 54, y: 65), width: 2, color: grayLight.copy(alpha: 0.75) ?? grayLight)
            // A cream patch over the hip.
            fillEllipse(c, 80, 72, 8, 14, creamDeep)
            fillEllipse(c, 80, 68, 3.5, 6, cream.copy(alpha: 0.75) ?? cream)
        }
        c.restoreGState()

        // Bushy tail wrapped round the front, from the rump to under the chin.
        let wrap = cubic(CGPoint(x: 84, y: 82), CGPoint(x: 88, y: 100), CGPoint(x: 52, y: 102), CGPoint(x: 30, y: 94), steps: 10)
        bushyTail(c, along: wrap, radii: [5.2, 5.6, 5.8, 5.8, 5.6, 5.4, 5.2, 4.8, 4.4, 3.8])

        // Head resting low on the left, tipped a little.
        let rise = -1.2 * lift
        c.saveGState()
        c.translateBy(x: 33, y: 80 + rise)
        c.rotate(by: -9 * .pi / 180)
        c.scaleBy(x: 0.82, y: 0.82)
        c.translateBy(x: -50, y: -40)
        drawHead(pose, c, detailed: detailed)
        c.restoreGState()

        // White socks tucked under the chin.
        furFill(c, ellipse(42, 93, 6.5, 4.2), .white, rimWidth: 2.2)
        furFill(c, ellipse(54, 93, 6.5, 4.2), .white, rimWidth: 2.2)

        drawProp(pose, c, accent)
    }

    // MARK: Walking

    private static func drawWalking(_ pose: CatPose, _ c: CGContext, _ accent: CGColor, _ detailed: Bool) {
        let sway = CGFloat(pose.tail)
        // Tail up and over the back, bushy.
        let tail = cubic(CGPoint(x: 20, y: 58), CGPoint(x: 4, y: 56), CGPoint(x: 5, y: 34), CGPoint(x: 18 + 3 * sway, y: 24 - 3 * sway), steps: 9)
        bushyTail(c, along: tail, radii: [4.2, 4.8, 5.3, 5.5, 5.5, 5.3, 5, 4.6, 4])

        // Legs: the far pair darker, the near pair in front of the body; every
        // front foot a white sock, one hind foot white.
        func leg(_ x: CGFloat, phase: Int, color: CGColor, sock: Bool) {
            let angle = Double(phase % 4) / 4 * 2 * Double.pi
            let swing = CGFloat(sin(angle)) * 6
            let lifted = CGFloat(max(0, cos(angle))) * 4
            let foot = CGPoint(x: x + swing, y: 90 - lifted)
            limb(c, from: CGPoint(x: x, y: 68), to: foot, width: 8, color: color)
            if sock { fillEllipse(c, foot.x, foot.y + 0.6, 4.8, 3.6, white) }
        }
        leg(24, phase: pose.legPhase + 2, color: grayDark, sock: false)
        leg(57, phase: pose.legPhase, color: grayDark, sock: true)

        let bodyBob = CGFloat(pose.headDY) * 0.6
        c.saveGState()
        c.translateBy(x: 0, y: bodyBob)
        let body = scallop(
            fluffyEllipse(42, 60, 31, 17, count: 28, tuft: 0.03), bulge: 1.3
        )
        furFill(c, body)
        clipped(c, to: body) {
            line(c, CGPoint(x: 38, y: 48), CGPoint(x: 36, y: 56), width: 2.4, color: grayDark.copy(alpha: 0.5) ?? grayDark)
            line(c, CGPoint(x: 48, y: 46), CGPoint(x: 50, y: 52), width: 2, color: grayLight.copy(alpha: 0.7) ?? grayLight)
            fillEllipse(c, 16, 58, 9, 14, creamDeep)
            fillEllipse(c, 16, 54, 3.5, 6, cream.copy(alpha: 0.75) ?? cream)
            // White chest where the head meets the body.
            fillEllipse(c, 66, 66, 9, 12, white)
        }
        c.restoreGState()

        leg(32, phase: pose.legPhase + 3, color: gray, sock: false)
        // The near hind foot is the white one.
        leg(63, phase: pose.legPhase + 1, color: gray, sock: true)

        // Collar at the neck.
        arc(c, from: CGPoint(x: 62, y: 47 + bodyBob), control: CGPoint(x: 68, y: 58 + bodyBob), to: CGPoint(x: 62, y: 71 + bodyBob), width: 4.4, color: accent)

        // Head in profile, facing right.
        let headY = 48 + CGFloat(pose.headDY)
        triangle(c, CGPoint(x: 66, y: headY - 8), CGPoint(x: 77, y: headY - 15), CGPoint(x: 69, y: headY - 30), fill: grayDark)
        triangle(c, CGPoint(x: 80, y: headY - 12), CGPoint(x: 88, y: headY - 6), CGPoint(x: 86, y: headY - 29), fill: gray)
        triangle(c, CGPoint(x: 82, y: headY - 13), CGPoint(x: 86, y: headY - 9), CGPoint(x: 85, y: headY - 24), fill: earInside, rimColor: .clear, rounding: 1.6)
        let head = scallop(fluffyEllipse(77, headY, 17, 15, count: 22, ruff: 0.06), bulge: 1.1)
        furFill(c, head)
        clipped(c, to: head) {
            fillEllipse(c, 76, headY + 7, 9, 6, creamDeep)
            line(c, CGPoint(x: 80, y: headY - 15), CGPoint(x: 82, y: headY - 6), width: 3, color: cream)
            fillEllipse(c, 90, headY + 5, 8, 6.5, white)
        }
        eye(c, x: 83, y: headY - 2, scale: 0.62, detailed: false)
        fillEllipse(c, 93.2, headY + 2.4, 2.4, 1.9, nose)
        c.setStrokeColor(white.copy(alpha: 0.9) ?? white)
        c.setLineWidth(1.4)
        c.setLineCap(.round)
        for tilt: CGFloat in [-4, 0, 4] {
            c.move(to: CGPoint(x: 91, y: headY + 4))
            c.addQuadCurve(to: CGPoint(x: 99, y: headY + 3 + tilt), control: CGPoint(x: 95, y: headY + 3 + tilt * 0.4))
        }
        c.strokePath()
    }

    // MARK: Peeking

    private static func drawPeeking(_ pose: CatPose, _ c: CGContext, _ accent: CGColor, _ detailed: Bool) {
        // Only the head and two paws on the edge; the rest is below the frame.
        c.saveGState()
        c.translateBy(x: 50, y: 74)
        c.rotate(by: CGFloat(pose.headTilt) * .pi / 180)
        c.scaleBy(x: 1.1, y: 1.1)
        c.translateBy(x: -50, y: -40)
        drawHead(pose, c, detailed: detailed)
        c.restoreGState()
        // The edge it is looking over, then the paws on it.
        c.setStrokeColor(rgb(0xFFFFFF, 0.35))
        c.setLineWidth(2.4)
        c.setLineCap(.round)
        c.move(to: CGPoint(x: 12, y: 98.5))
        c.addLine(to: CGPoint(x: 88, y: 98.5))
        c.strokePath()
        furFill(c, fluffyEllipsePath(31, 92, 10, 6.5, count: 14, bulge: 0.8), .white, rimWidth: 2.4)
        furFill(c, fluffyEllipsePath(69, 92, 10, 6.5, count: 14, bulge: 0.8), .white, rimWidth: 2.4)
        if detailed {
            c.setStrokeColor(edge)
            c.setLineWidth(1.1)
            c.setLineCap(.round)
            for x: CGFloat in [31, 69] {
                for dx: CGFloat in [-3, 3] {
                    c.move(to: CGPoint(x: x + dx, y: 90))
                    c.addLine(to: CGPoint(x: x + dx, y: 94))
                }
            }
            c.strokePath()
        }
    }

    // MARK: Props

    private static func drawProp(_ pose: CatPose, _ c: CGContext, _ accent: CGColor) {
        let phase = CGFloat(pose.propPhase)
        switch pose.prop {
        case .none:
            break
        case .zzz:
            // Two "z"s, half a loop apart, growing as they climb away from the head.
            for offset: CGFloat in [0, 0.5] {
                let p = (phase + offset).truncatingRemainder(dividingBy: 1)
                let size = 5 + 7 * p
                let x = 52 + 16 * p
                let y = 52 - 28 * p
                let alpha = min(p * 4, 1) * (1 - p * p)
                let z = CGMutablePath()
                z.move(to: CGPoint(x: x - size / 2, y: y - size / 2))
                z.addLine(to: CGPoint(x: x + size / 2, y: y - size / 2))
                z.addLine(to: CGPoint(x: x - size / 2, y: y + size / 2))
                z.addLine(to: CGPoint(x: x + size / 2, y: y + size / 2))
                c.addPath(z)
                c.setStrokeColor(accent.copy(alpha: alpha) ?? accent)
                c.setLineWidth(2.6)
                c.setLineCap(.round)
                c.setLineJoin(.round)
                c.strokePath()
            }
        case .note:
            // A note that climbs away from the right ear.
            for offset: CGFloat in [0, 0.5] {
                let p = (phase + offset).truncatingRemainder(dividingBy: 1)
                let x = 80 + 8 * sin(p * 5)
                let y = 42 - 28 * p
                let alpha = min(p * 5, 1) * (1 - p * p * p)
                let color = accent.copy(alpha: alpha) ?? accent
                fillEllipse(c, x, y + 6, 3.4, 2.7, color)
                c.setStrokeColor(color)
                c.setLineWidth(2)
                c.setLineCap(.round)
                c.move(to: CGPoint(x: x + 2.9, y: y + 5.5))
                c.addLine(to: CGPoint(x: x + 2.9, y: y - 6))
                c.addQuadCurve(to: CGPoint(x: x + 8, y: y + 1), control: CGPoint(x: x + 3, y: y - 2))
                c.strokePath()
            }
        case .exclaim:
            // A badge at the top right that swells a little on every other beat.
            let swell = 1 + 0.14 * phase
            c.saveGState()
            c.translateBy(x: 87, y: 15)
            c.scaleBy(x: swell, y: swell)
            fillEllipse(c, 0, 0, 9.5, 9.5, accent)
            c.setStrokeColor(rgb(0xFFFFFF))
            c.setLineWidth(2.8)
            c.setLineCap(.round)
            c.move(to: CGPoint(x: 0, y: -5))
            c.addLine(to: CGPoint(x: 0, y: 1))
            c.strokePath()
            fillEllipse(c, 0, 5, 1.7, 1.7, rgb(0xFFFFFF))
            c.restoreGState()
        case .sparkle:
            // Three four-point stars popping around the cat.
            let spots: [(CGFloat, CGFloat, CGFloat)] = [(14, 20, 1.0), (88, 24, 0.8), (84, 62, 0.6)]
            for (index, spot) in spots.enumerated() {
                let local = min(max((phase * 1.6 - CGFloat(index) * 0.15), 0), 1)
                guard local > 0 else { continue }
                let grow = local < 0.5 ? local * 2 : 1
                let alpha = local < 0.7 ? 1 : (1 - local) / 0.3
                let r = 9 * spot.2 * grow
                let star = CGMutablePath()
                star.move(to: CGPoint(x: spot.0, y: spot.1 - r))
                star.addQuadCurve(to: CGPoint(x: spot.0 + r, y: spot.1), control: CGPoint(x: spot.0 + 1.5, y: spot.1 - 1.5))
                star.addQuadCurve(to: CGPoint(x: spot.0, y: spot.1 + r), control: CGPoint(x: spot.0 + 1.5, y: spot.1 + 1.5))
                star.addQuadCurve(to: CGPoint(x: spot.0 - r, y: spot.1), control: CGPoint(x: spot.0 - 1.5, y: spot.1 + 1.5))
                star.addQuadCurve(to: CGPoint(x: spot.0, y: spot.1 - r), control: CGPoint(x: spot.0 - 1.5, y: spot.1 - 1.5))
                c.addPath(star)
                let color = index == 1 ? rgb(0xFFFFFF, alpha) : (accent.copy(alpha: alpha) ?? accent)
                c.setFillColor(color)
                c.fillPath()
            }
        }
    }
}
