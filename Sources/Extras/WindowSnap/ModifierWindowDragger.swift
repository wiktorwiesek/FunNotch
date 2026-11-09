//
//  ModifierWindowDragger.swift
//  FunNotch
//
//  Easy Move+Resize style: hold a modifier combination and drag anywhere in a
//  window to move it, or drag with the right button to resize it from the
//  nearest corner.
//
//  That needs an event tap that can swallow the click (otherwise the window
//  underneath would also receive it), and an active tap needs Accessibility.
//  The tap runs on the main run loop, so it must never wait on another app:
//  the window's frame is changed on a worker queue that only ever applies the
//  newest pending frame, and slow apps simply skip intermediate ones.
//

import AppKit
import ApplicationServices
import CoreGraphics

enum WindowDragModifier: String, CaseIterable, Identifiable {
    case controlOption
    case controlShift
    case optionCommand
    case controlOptionCommand

    var id: String { rawValue }

    var title: String {
        switch self {
        case .controlOption: return "⌃⌥ Control + Option"
        case .controlShift: return "⌃⇧ Control + Shift"
        case .optionCommand: return "⌥⌘ Option + Command"
        case .controlOptionCommand: return "⌃⌥⌘ Control + Option + Command"
        }
    }

    var flags: CGEventFlags {
        switch self {
        case .controlOption: return [.maskControl, .maskAlternate]
        case .controlShift: return [.maskControl, .maskShift]
        case .optionCommand: return [.maskAlternate, .maskCommand]
        case .controlOptionCommand: return [.maskControl, .maskAlternate, .maskCommand]
        }
    }

    /// Short form for sentences: "⌃⌥".
    var glyphs: String { String(title.prefix { !$0.isWhitespace }) }
}

@MainActor
final class ModifierWindowDragger: ObservableObject {
    static let shared = ModifierWindowDragger()

    /// True while the tap is live.
    @Published private(set) var isActive = false
    @Published private(set) var lastError: String?

    private static let relevantFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
    private static let minimumSize = CGSize(width: 160, height: 100)

    private enum Mode {
        case move
        /// Which edges follow the pointer: the ones on the side the grab was on.
        case resize(left: Bool, top: Bool)
    }

    private struct Gesture {
        let mode: Mode
        let button: CGEventType
        let window: AXUIElement
        let startMouse: CGPoint
        let startFrame: CGRect
    }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var modifier: WindowDragModifier = .controlOption
    private var gesture: Gesture?
    private let applier = FrameApplier()

    private init() {}

    /// Safe to call repeatedly; a changed modifier restarts the tap.
    func start(modifier: WindowDragModifier) {
        if tap != nil {
            guard self.modifier != modifier else { return }
            stop()
        }
        self.modifier = modifier
        guard WindowAccess.isTrusted else {
            lastError = "Brak uprawnienia Dostępność"
            return
        }

        let types: [CGEventType] = [
            .leftMouseDown, .leftMouseDragged, .leftMouseUp,
            .rightMouseDown, .rightMouseDragged, .rightMouseUp,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, _ in
            MainActor.assumeIsolated {
                ModifierWindowDragger.shared.handle(type: type, event: event)
            }
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: nil
        ) else {
            // Retried every few seconds by the coordinator; log the first refusal only.
            if lastError == nil { DiagnosticLog.write("windowsnap", "modifier drag: event tap refused") }
            lastError = "macOS odrzucił przechwytywanie zdarzeń myszy"
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        isActive = true
        lastError = nil
        DiagnosticLog.write("windowsnap", "modifier drag on (\(modifier.rawValue))")
    }

    func stop() {
        gesture = nil
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            DiagnosticLog.write("windowsnap", "modifier drag off")
        }
        tap = nil
        source = nil
        isActive = false
        lastError = nil
    }

    // MARK: - Events

    /// Returns the event to pass along, or nil to swallow it.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system turns a tap off when it is too slow; turn it back on
            // and drop any gesture that was in flight, since events were missed.
            gesture = nil
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            DiagnosticLog.write("windowsnap", "modifier drag: tap was disabled by the system, re-enabled")
            return passThrough

        case .leftMouseDown, .rightMouseDown:
            guard gesture == nil,
                  event.flags.intersection(Self.relevantFlags) == modifier.flags
            else { return passThrough }
            return begin(type: type, event: event) ? nil : passThrough

        case .leftMouseDragged, .rightMouseDragged:
            guard let gesture, gesture.button == Self.downType(of: type) else { return passThrough }
            update(gesture, to: event.location)
            return nil

        case .leftMouseUp, .rightMouseUp:
            guard let current = gesture, current.button == Self.downType(of: type) else { return passThrough }
            update(current, to: event.location)
            gesture = nil
            return nil

        default:
            return passThrough
        }
    }

    private static func downType(of type: CGEventType) -> CGEventType {
        switch type {
        case .leftMouseDragged, .leftMouseUp: return .leftMouseDown
        default: return .rightMouseDown
        }
    }

    private func begin(type: CGEventType, event: CGEvent) -> Bool {
        let point = event.location
        guard let target = WindowLocator.windowUnder(cgPoint: point),
              let window = WindowLocator.axWindow(pid: target.pid, matching: target.bounds),
              let frame = WindowFrame.read(window)
        else { return false }

        let mode: Mode = type == .leftMouseDown
            ? .move
            : .resize(left: point.x < frame.midX, top: point.y < frame.midY)

        WindowFrame.raise(window, pid: target.pid)
        gesture = Gesture(mode: mode, button: type, window: window, startMouse: point, startFrame: frame)
        return true
    }

    private func update(_ gesture: Gesture, to point: CGPoint) {
        let dx = point.x - gesture.startMouse.x
        let dy = point.y - gesture.startMouse.y
        let start = gesture.startFrame

        switch gesture.mode {
        case .move:
            applier.submit(window: gesture.window, origin: CGPoint(x: start.minX + dx, y: start.minY + dy), size: nil)

        case let .resize(left, top):
            let minimum = Self.minimumSize
            let width = max(minimum.width, left ? start.width - dx : start.width + dx)
            let height = max(minimum.height, top ? start.height - dy : start.height + dy)
            // The edge that is not being dragged stays where it was.
            let x = left ? start.maxX - width : start.minX
            let y = top ? start.maxY - height : start.minY
            applier.submit(
                window: gesture.window,
                origin: (left || top) ? CGPoint(x: x, y: y) : nil,
                size: CGSize(width: width, height: height)
            )
        }
    }
}

// MARK: - Applying frames off the main thread

/// Keeps only the newest requested frame and applies it on a worker queue.
/// During a drag the pointer produces events faster than most apps can lay out
/// a window; applying each one in order would make the window trail the
/// pointer by seconds.
private final class FrameApplier: @unchecked Sendable {
    private struct Request {
        let window: AXUIElement
        let origin: CGPoint?
        let size: CGSize?
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.funnotch.windowsnap.drag", qos: .userInteractive)
    private var pending: Request?
    private var working = false

    func submit(window: AXUIElement, origin: CGPoint?, size: CGSize?) {
        lock.lock()
        pending = Request(window: window, origin: origin, size: size)
        let needsWorker = !working
        working = true
        lock.unlock()
        if needsWorker { queue.async { [self] in drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let request = pending else {
                working = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()

            // Size first, then position: shrinking from the left would
            // otherwise push the old, larger window off the screen edge for
            // an instant and have the system clamp the position.
            if let size = request.size { WindowFrame.setSize(request.window, size) }
            if let origin = request.origin { WindowFrame.setPosition(request.window, origin) }
        }
    }
}
