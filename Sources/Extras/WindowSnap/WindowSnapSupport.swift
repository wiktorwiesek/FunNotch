//
//  WindowSnapSupport.swift
//  FunNotch
//
//  Shared plumbing for the two window features: Accessibility trust, finding
//  the window under the pointer, and reading and writing a window's frame.
//
//  Two coordinate systems meet here and they must never be mixed up:
//  AppKit (NSScreen, NSEvent) has its origin at the bottom-left of the primary
//  display with y growing up; Accessibility and Core Graphics window lists have
//  it at the top-left of the primary display with y growing down. Everything
//  that talks to a window is in the second one, everything that talks to a
//  screen in the first, and `DesktopGeometry` is the only place that converts.
//

import AppKit
import ApplicationServices

// MARK: - Accessibility trust

enum WindowAccess {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system's own "wants to control this computer" dialog. It does
    /// nothing at all once macOS has remembered an answer, which is why the
    /// settings button also opens the pane.
    static func requestPrompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func openPrivacyPane() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Coordinates

enum DesktopGeometry {
    /// The primary display is always first, and it is the one both coordinate
    /// systems flip around.
    private static var flipLine: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    static func cgPoint(fromAppKit point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: flipLine - point.y)
    }

    static func appKitPoint(fromCG point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: flipLine - point.y)
    }

    static func cgRect(fromAppKit rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: flipLine - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The display holding `point` (AppKit coordinates). `NSMouseInRect` is
    /// avoided on purpose: it leaves out the top edge, and the top edge is
    /// exactly where the pointer ends up when a window is thrown at the notch.
    static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { screen in
            let frame = screen.frame
            return point.x >= frame.minX && point.x <= frame.maxX
                && point.y >= frame.minY && point.y <= frame.maxY
        }
    }
}

// MARK: - Window lookup

struct WindowTarget {
    let windowNumber: CGWindowID
    let pid: pid_t
    /// Core Graphics coordinates.
    let bounds: CGRect
}

enum WindowLocator {
    /// The ordinary window under `point` (CG coordinates), front to back, or nil
    /// when something that is not an ordinary window is on top: the menu bar,
    /// the Dock, a menu, one of our own panels' title bars. Windows with no
    /// opacity are skipped, since several utilities keep invisible full-screen
    /// overlays around.
    static func windowUnder(cgPoint point: CGPoint) -> WindowTarget? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier

        for info in list {
            guard let bounds = bounds(of: info), bounds.contains(point) else { continue }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha < 0.05 { continue }
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32 else { continue }
            let layer = info[kCGWindowLayer as String] as? Int ?? 0

            if pid == ownPID {
                // The notch panels are big and mostly transparent; only a real
                // window of ours (Settings) should count as "something on top".
                if layer == 0 { return nil }
                continue
            }
            guard layer == 0, let number = info[kCGWindowNumber as String] as? UInt32 else { return nil }
            return WindowTarget(windowNumber: number, pid: pid, bounds: bounds)
        }
        return nil
    }

    /// Where the window is now, in CG coordinates. Cheap enough to call on
    /// every drag event, and needs no Accessibility access.
    static func currentBounds(of windowNumber: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowNumber) as? [[String: Any]],
              let info = list.first(where: { ($0[kCGWindowNumber as String] as? UInt32) == windowNumber })
        else { return nil }
        return bounds(of: info)
    }

    private static func bounds(of info: [String: Any]) -> CGRect? {
        guard let dictionary = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
    }

    /// The Accessibility element of the window whose frame is closest to
    /// `bounds`. Matching by frame is what ties a Core Graphics window to its
    /// element without private API; the focused window is the fallback for
    /// apps that report frames a few points off.
    static func axWindow(pid: pid_t, matching bounds: CGRect) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        // A hung app must not hang us: the default wait is six seconds.
        AXUIElementSetMessagingTimeout(app, 0.4)

        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
           let windows = value as? [AXUIElement] {
            let scored = windows.compactMap { window -> (AXUIElement, CGFloat)? in
                // A timeout set on the app element does not cover its windows; this
                // runs inside the event tap, so each element needs its own bound.
                AXUIElementSetMessagingTimeout(window, 0.4)
                guard let frame = WindowFrame.read(window) else { return nil }
                return (window, frame.distance(to: bounds))
            }
            if let best = scored.min(by: { $0.1 < $1.1 }), best.1 < 8 { return best.0 }
        }

        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
           let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
            let element = focused as! AXUIElement // type checked on the line above
            AXUIElementSetMessagingTimeout(element, 0.4)
            if let frame = WindowFrame.read(element), frame.distance(to: bounds) < 40 { return element }
        }
        return nil
    }
}

private extension CGRect {
    /// Sum of how far each edge is from the other rectangle's.
    func distance(to other: CGRect) -> CGFloat {
        abs(minX - other.minX) + abs(minY - other.minY) + abs(width - other.width) + abs(height - other.height)
    }
}

// MARK: - Window frame via Accessibility

enum WindowFrame {
    static func read(_ window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin), // type checked above
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    @discardableResult
    static func setPosition(_ window: AXUIElement, _ origin: CGPoint) -> AXError {
        var origin = origin
        guard let value = AXValueCreate(.cgPoint, &origin) else { return .failure }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    }

    @discardableResult
    static func setSize(_ window: AXUIElement, _ size: CGSize) -> AXError {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return .failure }
        return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    }

    /// Windows clamp what they accept depending on where they currently are, so
    /// the size is set, then the position, then the size once more: a window
    /// moved to a different display only takes its final size after it arrives.
    /// Returns the first error that left the window unable to reach `frame`.
    @discardableResult
    static func apply(_ frame: CGRect, to window: AXUIElement) -> AXError {
        let sizeError = setSize(window, frame.size)
        let positionError = setPosition(window, frame.origin)
        let finalSizeError = setSize(window, frame.size)
        if positionError != .success { return positionError }
        if sizeError != .success { return sizeError }
        return finalSizeError
    }

    /// Brings the window and its app to the front. Raising the window alone
    /// leaves the app's menu bar behind the previous app's.
    static func raise(_ window: AXUIElement, pid: pid_t) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        // A fresh app element has the default six second wait; raise() also
        // runs inside the event tap.
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }
}
