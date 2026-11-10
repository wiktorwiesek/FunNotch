//
//  LockScreenWindow.swift
//  FunNotch
//
//  A transparent panel that sits above the macOS lock screen.
//
//  Ordinary windows are hidden while the screen is locked: the lock screen
//  lives in its own window-server space at a very high level. The only way to
//  draw above it is to put a window into a space of our own with a higher
//  level, which needs SkyLight, a private framework (the technique of the
//  open-source SkyLightWindow project). None of it is documented, so every
//  symbol is resolved with `dlsym` and checked: if the framework or any one
//  function is missing the feature reports itself unavailable and does
//  nothing, rather than crashing after a system update.
//
//  The space is created once and reused. Nothing here exists while the screen
//  is unlocked: the controller creates a `LockScreenWindow` on lock and drops
//  it on unlock.
//

import AppKit
import SwiftUI

// MARK: - SkyLight

/// The handful of SkyLight calls needed to own a space above the lock screen.
@MainActor
final class SkyLightSpace {
    static let shared = SkyLightSpace()

    // Declared by hand, since there is no header. Space identifiers are
    // 64-bit in the window server but small in practice; they are passed as
    // `UInt64` (a wider register is harmless for a narrower parameter) and
    // read back as `UInt32` (the low half is all a small identifier uses, and
    // a narrower return value cannot leave garbage in it).
    private typealias MainConnectionFunction = @convention(c) () -> Int32
    private typealias SpaceCreateFunction = @convention(c) (Int32, UInt64, UInt64) -> UInt32
    private typealias SetLevelFunction = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias ShowSpacesFunction = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindowsFunction = @convention(c) (Int32, UInt64, CFArray, Int32) -> Int32

    /// Above the lock screen. SkyLightWindow uses the same value.
    private static let level: Int32 = 400
    /// The option mask SkyLightWindow passes when moving a window across.
    private static let moveOptions: Int32 = 7

    private let mainConnection: MainConnectionFunction?
    private let createSpace: SpaceCreateFunction?
    private let setLevel: SetLevelFunction?
    private let showSpaces: ShowSpacesFunction?
    private let addWindows: AddWindowsFunction?

    /// The one space, created on first use.
    private var space: UInt64?

    /// True when every symbol resolved. Resolving costs nothing: AppKit has
    /// SkyLight loaded in every process already.
    let isAvailable: Bool

    private init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let handle, let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }
        let connection = symbol("SLSMainConnectionID", as: MainConnectionFunction.self)
        let create = symbol("SLSSpaceCreate", as: SpaceCreateFunction.self)
        let level = symbol("SLSSpaceSetAbsoluteLevel", as: SetLevelFunction.self)
        let show = symbol("SLSShowSpaces", as: ShowSpacesFunction.self)
        let add = symbol("SLSSpaceAddWindowsAndRemoveFromSpaces", as: AddWindowsFunction.self)

        mainConnection = connection
        createSpace = create
        setLevel = level
        showSpaces = show
        addWindows = add
        isAvailable = connection != nil && create != nil && level != nil && show != nil && add != nil
        if !isAvailable {
            DiagnosticLog.write("lockscreen", "SkyLight symbols missing, lock-screen widgets unavailable")
        }
    }

    /// Moves a window into the space above the lock screen. Returns false, and
    /// leaves the window where it is, if any call is unavailable or failed.
    func move(windowNumber: Int) -> Bool {
        guard isAvailable, windowNumber > 0,
              let mainConnection, let createSpace, let setLevel, let showSpaces, let addWindows
        else { return false }

        let connection = mainConnection()

        if space == nil {
            let created = createSpace(connection, 1, 0)
            guard created != 0 else {
                DiagnosticLog.write("lockscreen", "could not create a space")
                return false
            }
            let identifier = UInt64(created)
            _ = setLevel(connection, identifier, Self.level)
            _ = showSpaces(connection, [NSNumber(value: identifier)] as CFArray)
            space = identifier
        }
        guard let space else { return false }

        _ = addWindows(connection, space, [NSNumber(value: windowNumber)] as CFArray, Self.moveOptions)
        return true
    }
}

// MARK: - Panel

/// Never key, never main: it must not take focus from the lock screen's
/// password field, and clicks on its buttons must still work.
private final class LockScreenPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A click on a button in a window that is not key would otherwise only
/// "activate" the window and be swallowed.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class LockScreenWindow {
    /// Widest the stack of cards gets.
    static let width: CGFloat = 380
    /// Where the stack's vertical centre sits, as a fraction of the screen's
    /// height measured from the top: below the clock, clear of the password
    /// field.
    private static let centreFraction: CGFloat = 0.6

    private var panel: NSPanel?
    private let screen: NSScreen

    /// Nil when SkyLight is unavailable or the window could not be moved above
    /// the lock screen; in that case nothing has been shown.
    init?(screen: NSScreen) {
        guard SkyLightSpace.shared.isAvailable else { return nil }
        self.screen = screen

        let panel = LockScreenPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)

        let root = LockScreenWidgetsView(onSize: { [weak self] size in self?.resize(to: size) })
        let hosting = FirstMouseHostingView(rootView: root)
        // The panel is sized from the content's measured size, not the other
        // way round.
        hosting.sizingOptions = []
        panel.contentView = hosting
        place(panel, size: CGSize(width: Self.width, height: 1))

        // The window must exist in the window server before it has a number
        // to move.
        panel.orderFrontRegardless()
        guard SkyLightSpace.shared.move(windowNumber: panel.windowNumber) else {
            panel.contentView = nil
            panel.orderOut(nil)
            panel.close()
            return nil
        }
        self.panel = panel
    }

    /// Closes the panel and releases the SwiftUI tree, which stops everything
    /// in it observing the managers.
    func close() {
        guard let panel else { return }
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
        self.panel = nil
    }

    private func resize(to size: CGSize) {
        guard let panel else { return }
        place(panel, size: size)
    }

    private func place(_ panel: NSPanel, size: CGSize) {
        let frame = screen.frame
        let width = min(max(size.width, 1), Self.width)
        let height = max(size.height, 1)
        let centreY = frame.maxY - frame.height * Self.centreFraction
        let rect = NSRect(
            x: frame.midX - width / 2,
            y: centreY - height / 2,
            width: width,
            height: height
        )
        if panel.frame != rect { panel.setFrame(rect, display: true) }
    }
}
