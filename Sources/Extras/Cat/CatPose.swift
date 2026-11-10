//
//  CatPose.swift
//  FunNotch
//
//  The cat mascot as data: a pose is every parameter the artwork needs to draw
//  one still of the cat, a clip is a timeline of poses plus the transform
//  motion that rides on top of it, and each `CatState` names one clip.
//
//  Nothing here draws or animates. `CatArt` turns a pose into pixels once;
//  `CatLayerView` hands the stills to Core Animation, which plays them in the
//  render server. The timelines are therefore written as plain functions of
//  time and sampled into a handful of steps, with identical neighbours merged,
//  so a calm loop (a blink every few seconds) is only a few images long.
//

import CoreGraphics
import QuartzCore

// MARK: - State

/// What the cat is doing. Each one is a separate clip.
enum CatState: String, CaseIterable, Identifiable {
    /// Curled up, breathing, a "z" drifting up. The idle cat.
    case sleeping
    /// Sitting, with an occasional blink or ear twitch.
    case awake
    /// Both paws on a laptop whose glow is the agent's colour.
    case working
    /// Looking up, one paw raised and waving, a "!" beside the head.
    case waiting
    /// One happy hop, then back to sitting.
    case done
    /// Head bobbing and tail swaying to a tempo.
    case music
    /// Pops up from below and glances about.
    case peek
    /// Side view, walking: the timer mascot.
    case walking

    var id: String { rawValue }

    /// Polish caption for the settings preview.
    var title: String {
        switch self {
        case .sleeping: return "Śpi"
        case .awake: return "Czuwa"
        case .working: return "Pracuje"
        case .waiting: return "Czeka"
        case .done: return "Gotowe"
        case .music: return "Muzyka"
        case .peek: return "Wygląda"
        case .walking: return "Idzie"
        }
    }
}

// MARK: - Pose

struct CatArm: Hashable {
    /// Degrees from hanging straight down: 90 sticks out sideways, 125 is a raised paw.
    var angle = 0.0
    var reach = 24.0

    static let rest = CatArm()
}

struct CatPose: Hashable {
    enum Body: UInt8 { case sit, curled, walk, peek }
    enum Eyes: UInt8 { case open, blink, closed, happy, wide, glanceLeft, glanceRight, focus }
    enum Prop: UInt8 { case none, zzz, note, exclaim, sparkle }

    var body = Body.sit
    var eyes = Eyes.open
    /// Degrees, positive tips the head clockwise on screen.
    var headTilt = 0.0
    /// Units (the cat is drawn on a 100 × 100 grid), positive moves the head down.
    var headDY = 0.0
    /// 0 upright … 1 folded down and out.
    var earL = 0.0
    var earR = 0.0
    /// -1 … 1, which way the tail tip leans.
    var tail = 0.0
    var armL = CatArm.rest
    var armR = CatArm.rest
    /// -1 squashed … 1 stretched; the breath of a sleeping cat, a hop's landing.
    var lift = 0.0
    var laptop = false
    /// 0 paw resting on the laptop … 1 paw lifted off it.
    var tapL = 0.0
    var tapR = 0.0
    /// 0 … 1, how bright the laptop's logo is.
    var glow = 0.0
    var smile = false
    var prop = Prop.none
    /// 0 … 1, where a prop is in its little journey.
    var propPhase = 0.0
    /// Which of the four walking poses.
    var legPhase = 0
}

// MARK: - Clip

/// One transform animation that rides over the stills.
struct CatMotionTrack {
    enum Unit { case fractionOfSize, raw }

    var keyPath: String
    var values: [Double]
    /// Start of each value as a fraction of the track; evenly spaced when nil.
    var keyTimes: [Double]?
    /// Easing of each segment (`values.count - 1`), or `easeInEaseOut` throughout.
    var timings: [CAMediaTimingFunctionName]?
    var unit = Unit.fractionOfSize
}

struct CatStep: Equatable {
    var pose: CatPose
    var duration: Double
}

struct CatClip {
    /// Played once, then the loop takes over; empty for most.
    var intro: [CatStep] = []
    var introMotion: [CatMotionTrack] = []
    var introDuration: Double { intro.reduce(0) { $0 + $1.duration } }

    var loop: [CatStep]
    var loopMotion: [CatMotionTrack] = []
    var loopDuration: Double { loop.reduce(0) { $0 + $1.duration } }

    /// What is drawn while nothing moves: reduced motion, low power, a locked screen.
    var rest: CatPose
    /// Render-server frame rate the clip asks for; the stills change a few times
    /// a second at most, so there is no use in more.
    var frameRate = CAFrameRateRange(minimum: 4, maximum: 12, preferred: 10)
    /// Clip to the view's bounds, so a cat that has slid out of sight stays out of sight.
    var clipsToBounds = false
    /// Seconds one beat lasts, for the clip that follows music.
    var beat: Double?
}

// MARK: - Clips

enum CatClips {
    /// Samples `pose` every `dt` seconds across `total` and merges identical
    /// neighbours, so only real changes become steps.
    static func timeline(total: Double, dt: Double, _ pose: (Double) -> CatPose) -> [CatStep] {
        var steps: [CatStep] = []
        let count = max(Int((total / dt).rounded()), 1)
        for index in 0 ..< count {
            let sample = pose((Double(index) + 0.5) * dt)
            if var last = steps.last, last.pose == sample {
                last.duration += dt
                steps[steps.count - 1] = last
            } else {
                steps.append(CatStep(pose: sample, duration: dt))
            }
        }
        return steps
    }

    private static func quantised(_ value: Double, step: Double) -> Double {
        (value / step).rounded() * step
    }

    static func clip(for state: CatState) -> CatClip {
        switch state {
        case .sleeping: return sleeping
        case .awake: return awake
        case .working: return working
        case .waiting: return waiting
        case .done: return done
        case .music: return music
        case .peek: return peek
        case .walking: return walking
        }
    }

    // MARK: Sleeping

    private static let sleeping: CatClip = {
        // Eight steps, two breaths; the "z" drifts up once across the loop.
        let steps = timeline(total: 4.8, dt: 0.6) { t in
            let breath = [0.0, 0.5, 1, 0.5][Int(t / 0.6) % 4]
            return CatPose(
                body: .curled, eyes: .closed, lift: breath,
                prop: .zzz, propPhase: quantised(t / 4.8, step: 0.125)
            )
        }
        return CatClip(
            loop: steps,
            rest: CatPose(body: .curled, eyes: .closed),
            frameRate: CAFrameRateRange(minimum: 2, maximum: 5, preferred: 4)
        )
    }()

    // MARK: Awake

    private static func awakePose(_ t: Double) -> CatPose {
        var pose = CatPose()
        pose.tail = quantised(sin(2 * Double.pi * t / 2.6), step: 0.5)
        // Blinks, the second a double.
        if (3.2 ..< 3.34).contains(t) || (6.6 ..< 6.72).contains(t) || (6.9 ..< 7.02).contains(t) {
            pose.eyes = .blink
        }
        // A twitch of each ear, far apart.
        if (1.6 ..< 1.72).contains(t) { pose.earL = 0.6 }
        if (1.72 ..< 1.84).contains(t) { pose.earL = 1 }
        if (1.84 ..< 1.96).contains(t) { pose.earL = 0.4 }
        if (5.0 ..< 5.12).contains(t) { pose.earR = 0.6 }
        if (5.12 ..< 5.24).contains(t) { pose.earR = 1 }
        if (5.24 ..< 5.36).contains(t) { pose.earR = 0.4 }
        // A curious tilt of the head.
        if (4.0 ..< 5.6).contains(t) { pose.headTilt = 5 }
        return pose
    }

    private static let awake = CatClip(
        loop: timeline(total: 8, dt: 0.06, awakePose),
        rest: CatPose(),
        frameRate: CAFrameRateRange(minimum: 2, maximum: 8, preferred: 6)
    )

    // MARK: Working

    private static let working: CatClip = {
        let left: [Double] = [1, 0, 0, 1, 0, 1, 0, 0]
        let right: [Double] = [0, 1, 0, 0, 1, 0, 0, 1]
        let steps = timeline(total: 1.2, dt: 0.15) { t in
            let index = Int(t / 0.15) % 8
            return CatPose(
                eyes: .focus,
                headDY: index.isMultiple(of: 2) ? 0 : 1,
                laptop: true,
                tapL: left[index], tapR: right[index],
                glow: index % 4 < 2 ? 1 : 0.55
            )
        }
        return CatClip(
            loop: steps,
            rest: CatPose(eyes: .focus, laptop: true, glow: 1),
            frameRate: CAFrameRateRange(minimum: 4, maximum: 8, preferred: 7)
        )
    }()

    // MARK: Waiting

    private static let waiting: CatClip = {
        let steps = timeline(total: 2.8, dt: 0.1) { t in
            var pose = CatPose(eyes: .wide, prop: .exclaim, propPhase: Int(t / 0.7).isMultiple(of: 2) ? 0 : 1)
            // Wave for a second, then sit with a flick of the tail.
            if t < 1.2 {
                let swing = Int(t / 0.1).isMultiple(of: 2) ? -14.0 : 14.0
                pose.armR = CatArm(angle: 138 + swing, reach: 23)
            } else {
                pose.tail = quantised(sin(t * 6), step: 0.5)
            }
            if (2.4 ..< 2.52).contains(t) { pose.eyes = .blink }
            return pose
        }
        return CatClip(
            loop: steps,
            rest: CatPose(eyes: .wide, armR: CatArm(angle: 138, reach: 23), prop: .exclaim),
            frameRate: CAFrameRateRange(minimum: 4, maximum: 10, preferred: 10)
        )
    }()

    // MARK: Done

    private static let done: CatClip = {
        // Crouch, spring up with both paws raised, hang, land, settle happy.
        let intro: [CatStep] = [
            CatStep(pose: CatPose(eyes: .happy, lift: -1, smile: true), duration: 0.14),
            CatStep(pose: CatPose(eyes: .happy, armL: CatArm(angle: 150), armR: CatArm(angle: 150), lift: 0.8, smile: true, prop: .sparkle, propPhase: 0.2), duration: 0.18),
            CatStep(pose: CatPose(eyes: .happy, armL: CatArm(angle: 140), armR: CatArm(angle: 140), lift: 0.4, smile: true, prop: .sparkle, propPhase: 0.5), duration: 0.22),
            CatStep(pose: CatPose(eyes: .happy, armL: CatArm(angle: 110), armR: CatArm(angle: 110), lift: 0, smile: true, prop: .sparkle, propPhase: 0.75), duration: 0.16),
            CatStep(pose: CatPose(eyes: .happy, lift: -1, smile: true, prop: .sparkle, propPhase: 0.95), duration: 0.12),
            CatStep(pose: CatPose(eyes: .happy, lift: 0.3, smile: true), duration: 0.36),
            CatStep(pose: CatPose(eyes: .happy, smile: true), duration: 0.5),
        ]
        let hop = CatMotionTrack(
            keyPath: "transform.translation.y",
            values: [0, 0, 0.2, 0.2, 0, 0, 0],
            keyTimes: [0, 0.1, 0.24, 0.36, 0.55, 0.65, 1],
            timings: [.linear, .easeOut, .linear, .easeIn, .linear, .linear]
        )
        return CatClip(
            intro: intro,
            introMotion: [hop],
            loop: timeline(total: 8, dt: 0.06, awakePose),
            rest: CatPose(eyes: .happy, smile: true),
            frameRate: CAFrameRateRange(minimum: 4, maximum: 15, preferred: 12)
        )
    }()

    // MARK: Music

    /// 120 bpm until the player says otherwise.
    static let defaultBeat = 0.5

    private static let music: CatClip = {
        let beat = defaultBeat
        let dt = beat / 4
        let steps = timeline(total: beat * 4, dt: dt) { t in
            let slot = Int(t / dt) % 16
            let tilts: [Double] = [-6, -6, -3, 0, 0, 3, 6, 6, 6, 3, 0, 0, -3, -6, -6, -3]
            return CatPose(
                eyes: .happy,
                headTilt: tilts[slot],
                headDY: slot % 8 < 2 ? 1.5 : 0,
                tail: quantised(sin(2 * Double.pi * t / (beat * 4)), step: 0.5),
                smile: true,
                prop: .note,
                propPhase: Double(slot % 8) / 8
            )
        }
        let bob = CatMotionTrack(
            keyPath: "transform.translation.y",
            values: Array(repeating: [0.0, -0.045], count: 4).flatMap { $0 } + [0],
            keyTimes: nil
        )
        return CatClip(
            loop: steps,
            loopMotion: [bob],
            rest: CatPose(eyes: .happy, smile: true),
            frameRate: CAFrameRateRange(minimum: 6, maximum: 15, preferred: 12),
            beat: beat
        )
    }()

    // MARK: Peek

    private static let peek: CatClip = {
        let intro = timeline(total: 0.5, dt: 0.1) { _ in CatPose(body: .peek, eyes: .wide) }
        let rise = CatMotionTrack(
            keyPath: "transform.translation.y",
            values: [-0.62, 0.04, 0],
            keyTimes: [0, 0.72, 1],
            timings: [.easeOut, .easeInEaseOut]
        )
        let loop = timeline(total: 4, dt: 0.1) { t in
            var pose = CatPose(body: .peek, eyes: .open)
            if (0.6 ..< 1.3).contains(t) { pose.eyes = .glanceRight; pose.headTilt = 4 }
            if (1.9 ..< 2.7).contains(t) { pose.eyes = .glanceLeft; pose.headTilt = -4 }
            if (3.1 ..< 3.2).contains(t) { pose.eyes = .blink }
            if (3.5 ..< 3.6).contains(t) { pose.earR = 0.8 }
            return pose
        }
        return CatClip(
            intro: intro,
            introMotion: [rise],
            loop: loop,
            rest: CatPose(body: .peek, eyes: .open),
            frameRate: CAFrameRateRange(minimum: 4, maximum: 15, preferred: 12),
            clipsToBounds: true
        )
    }()

    // MARK: Walking

    private static let walking: CatClip = {
        let steps = timeline(total: 0.64, dt: 0.16) { t in
            let phase = Int(t / 0.16) % 4
            return CatPose(
                body: .walk, eyes: .open,
                headDY: phase % 2 == 0 ? 0 : 1,
                tail: [0, 0.5, 1, 0.5][phase],
                legPhase: phase
            )
        }
        return CatClip(
            loop: steps,
            rest: CatPose(body: .walk, eyes: .open, legPhase: 0),
            frameRate: CAFrameRateRange(minimum: 4, maximum: 8, preferred: 6)
        )
    }()
}
