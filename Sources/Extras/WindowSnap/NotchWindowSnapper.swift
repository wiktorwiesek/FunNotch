//
//  NotchWindowSnapper.swift
//  FunNotch
//
//  Throw a window at the notch and let go over a zone to tile it.
//
//  There is no API that says "a window is being dragged", so it is inferred:
//  a click lands in the top strip of a window, and then the window's frame
//  starts following the pointer. A drag that only scrolls or selects inside
//  the page never moves the frame and so never shows the zones. Detection
//  reads window frames from the Core Graphics window list, which needs no
//  permission; Accessibility is only needed at the end, to move the window.
//

import AppKit
import ApplicationServices

@MainActor
final class NotchWindowSnapper {
    static let shared = NotchWindowSnapper()

    private struct Candidate {
        let target: WindowTarget
        /// Pointer position at mouse-down, CG coordinates.
        let startMouse: CGPoint
        var lastCheck: TimeInterval = 0
    }

    /// How much of a window's top counts as "its title bar": the title bar plus
    /// a unified toolbar or a browser's tab strip, which all drag the window.
    private static let grabStrip: CGFloat = 60

    private var monitors: [Any] = []
    private var candidate: Candidate?
    /// Set once the window has been seen moving with the pointer.
    private var dragged: WindowTarget?

    /// Window changes are made off the main thread: an unresponsive app would
    /// otherwise stall every Accessibility call for its full timeout.
    private let axQueue = DispatchQueue(label: "com.funnotch.windowsnap.ax", qos: .userInitiated)

    private init() {}

    var isRunning: Bool { !monitors.isEmpty }

    /// Safe to call repeatedly.
    func start() {
        guard monitors.isEmpty else { return }
        add(.leftMouseDown) { [weak self] in self?.mouseDown() }
        add(.leftMouseDragged) { [weak self] in self?.mouseDragged() }
        add(.leftMouseUp) { [weak self] in self?.mouseUp() }
        DiagnosticLog.write("windowsnap", "notch snapping on")
    }

    func stop() {
        guard !monitors.isEmpty else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        reset()
        DiagnosticLog.write("windowsnap", "notch snapping off")
    }

    private func add(_ mask: NSEvent.EventTypeMask, _ handler: @escaping @MainActor () -> Void) {
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { _ in
            MainActor.assumeIsolated { handler() }
        }) {
            monitors.append(monitor)
        }
    }

    private func reset() {
        candidate = nil
        dragged = nil
        WindowSnapOverlay.shared.hide()
    }

    // MARK: - Events

    private func mouseDown() {
        reset()
        let mouse = NSEvent.mouseLocation
        let point = DesktopGeometry.cgPoint(fromAppKit: mouse)
        guard let target = WindowLocator.windowUnder(cgPoint: point),
              point.y - target.bounds.minY <= Self.grabStrip
        else { return }
        candidate = Candidate(target: target, startMouse: point)
    }

    private func mouseDragged() {
        // A button released outside every event we see (a screen lock, a
        // Space switch) must not leave the zones up.
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            reset()
            return
        }

        if dragged == nil, var pending = candidate {
            // Reading the window list on every one of ~100 drag events a second
            // is wasteful; the window cannot have visibly moved in 30 ms.
            let now = ProcessInfo.processInfo.systemUptime
            guard now - pending.lastCheck >= 0.03 else { return }
            pending.lastCheck = now
            candidate = pending
            guard windowFollowsPointer(pending) else { return }
            dragged = pending.target
            candidate = nil
        }

        guard dragged != nil else { return }
        updateOverlay(at: NSEvent.mouseLocation)
    }

    private func mouseUp() {
        defer { reset() }
        guard let target = dragged else { return }

        let mouse = NSEvent.mouseLocation
        let overlay = WindowSnapOverlay.shared
        guard let zone = overlay.zone(at: mouse), let screen = overlay.screen else { return }

        // The window's own drag loop is still winding down at this moment, and
        // a move made now can be undone by its last frame. Moving it a beat
        // later lets the drop win.
        let usable = DesktopGeometry.cgRect(fromAppKit: screen.visibleFrame)
        let frame = zone.frame(in: usable)
        let zoneTitle = zone.title.lowercased()
        axQueue.asyncAfter(deadline: .now() + 0.07) {
            let problem = Self.snap(target, to: frame, within: usable)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { Self.report(problem, for: target, zone: zoneTitle) }
            }
        }
    }

    // MARK: - Detection

    /// True once the window has moved by about as much as the pointer did and
    /// kept its size, which tells a title-bar drag from a resize or a drag
    /// inside the window.
    private func windowFollowsPointer(_ candidate: Candidate) -> Bool {
        guard let now = WindowLocator.currentBounds(of: candidate.target.windowNumber) else { return false }
        let start = candidate.target.bounds
        let mouse = DesktopGeometry.cgPoint(fromAppKit: NSEvent.mouseLocation)

        let windowMove = CGVector(dx: now.minX - start.minX, dy: now.minY - start.minY)
        let mouseMove = CGVector(dx: mouse.x - candidate.startMouse.x, dy: mouse.y - candidate.startMouse.y)

        let moved = abs(windowMove.dx) > 4 || abs(windowMove.dy) > 4
        let sameSize = abs(now.width - start.width) < 2 && abs(now.height - start.height) < 2
        // A window lags the pointer a little, and a menu bar can stop it
        // short at the top of the screen.
        let follows = abs(windowMove.dx - mouseMove.dx) < 40 && abs(windowMove.dy - mouseMove.dy) < 90
        return moved && sameSize && follows
    }

    private func updateOverlay(at mouse: CGPoint) {
        let overlay = WindowSnapOverlay.shared

        if overlay.isVisible {
            guard overlay.keepsOpen(for: mouse) else {
                overlay.hide()
                return
            }
        } else if let screen = DesktopGeometry.screen(containing: mouse),
                  WindowSnapOverlay.triggerRect(on: screen).contains(mouse) {
            overlay.show(on: screen)
        }
        overlay.updateHover(at: mouse)
    }

    // MARK: - Moving

    private enum Problem {
        case noWindow
        case cannotMove
        case cannotResize
    }

    /// Runs on `axQueue`. `usable` is the screen's usable area, so a window that
    /// cannot get as small as the zone can be kept inside it.
    private nonisolated static func snap(_ target: WindowTarget, to frame: CGRect, within usable: CGRect) -> Problem? {
        let current = WindowLocator.currentBounds(of: target.windowNumber) ?? target.bounds
        guard let window = WindowLocator.axWindow(pid: target.pid, matching: current) else { return .noWindow }

        let error = WindowFrame.apply(frame, to: window)
        guard var result = WindowFrame.read(window) else {
            return error == .success ? nil : .cannotMove
        }

        // A window with a minimum size larger than the zone keeps the zone's
        // top-left corner and grows past the screen edge (a right third of a
        // window that needs 700 pt ends up 200 pt off screen). Slide it back
        // so the whole window stays reachable.
        if result.width > frame.width + 1 || result.height > frame.height + 1 {
            let origin = WindowFrame.origin(keeping: result, inside: usable)
            if abs(origin.x - result.minX) > 1 || abs(origin.y - result.minY) > 1 {
                WindowFrame.setPosition(window, origin)
                result = WindowFrame.read(window) ?? result
            }
        }

        // Size is judged first: after the slide above the position differs from
        // the zone's by design, and that is a size problem, not a move problem.
        if abs(result.width - frame.width) > 6 || abs(result.height - frame.height) > 6 { return .cannotResize }
        if abs(result.minX - frame.minX) > 6 || abs(result.minY - frame.minY) > 6 { return .cannotMove }
        return nil
    }

    private static func report(_ problem: Problem?, for target: WindowTarget, zone: String) {
        let name = NSRunningApplication(processIdentifier: target.pid)?.localizedName ?? "Okno"
        guard let problem else {
            DiagnosticLog.write("windowsnap", "\(name) snapped: \(zone)")
            return
        }

        let detail: String
        switch problem {
        case .noWindow: detail = "nie udało się uzyskać dostępu do okna"
        case .cannotMove: detail = "okno nie pozwala się przesunąć"
        case .cannotResize: detail = "okno nie pozwala zmienić rozmiaru"
        }
        DiagnosticLog.write("windowsnap", "\(name) not snapped (\(zone)): \(detail)")
        IslandCenter.shared.post(Island(
            symbol: "exclamationmark.triangle.fill",
            tint: .orange,
            title: name,
            detail: detail,
            duration: 3.5
        ))
    }
}
