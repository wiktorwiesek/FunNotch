//
//  DecorHUD.swift
//  FunNotch
//
//  Two other places to show volume, brightness and keyboard backlight besides
//  the notch: a thin bar pinned to the right edge of the screen, and a round
//  gauge hanging under the notch. Each lives in its own transparent panel that
//  never takes focus and lets every click through.
//
//  `HUDManager` still does the work of catching the keys and changing the
//  level; it only asks `present` whether the level was drawn here, and falls
//  back to the notch banner when it was not.
//

import AppKit
import SwiftUI

@MainActor
final class DecorHUDModel: ObservableObject {
    @Published var kind: HUDManager.Kind = .volume
    @Published var level: Double = 0
    @Published var muted = false
    @Published var visible = false
    @Published var style: DecorHUDStyle = .edgeBar
    @Published var scale: Double = 1
}

@MainActor
final class DecorHUDOverlay {
    static let shared = DecorHUDOverlay()

    private let model = DecorHUDModel()
    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?
    private var orderOutWorkItem: DispatchWorkItem?

    private init() {}

    // MARK: - Metrics

    static func size(for style: DecorHUDStyle, scale: Double) -> CGSize {
        let s = CGFloat(scale)
        switch style {
        case .edgeBar, .notch: return CGSize(width: 34 * s, height: 190 * s)
        case .ring: return CGSize(width: 84 * s, height: 84 * s)
        }
    }

    // MARK: - Presenting

    /// Draws the level in the chosen alternative style. Returns false, having
    /// drawn nothing, when the style is the notch banner.
    @discardableResult
    func present(
        kind: HUDManager.Kind, value: Float, muted: Bool, duration: TimeInterval = 1.4,
        style override: DecorHUDStyle? = nil
    ) -> Bool {
        let store = DecorStore.shared
        let style = override ?? store.hudStyle
        guard style != .notch else { return false }

        model.kind = kind
        model.level = Double(min(max(muted && kind == .volume ? 0 : value, 0), 1))
        model.muted = muted && kind == .volume
        model.style = style
        model.scale = store.hudScale

        let size = Self.size(for: style, scale: store.hudScale)
        let panel = ensurePanel()
        // present() runs inside the media-key event tap; display: true would
        // force a synchronous redraw there. The window redraws on its own.
        panel.setFrame(frame(for: style, size: size), display: false)
        panel.contentView?.frame = NSRect(origin: .zero, size: size)
        panel.orderFrontRegardless()

        orderOutWorkItem?.cancel()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) { model.visible = true }

        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.hide() }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
        return true
    }

    private func hide() {
        withAnimation(.easeIn(duration: 0.22)) { model.visible = false }
        // Leave the panel up until the fade has finished.
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.panel?.orderOut(nil) }
        }
        orderOutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Builds the panel ahead of the first key press, so the event tap never
    /// pays for creating the window and its hosting view.
    func prepare() {
        _ = ensurePanel()
    }

    // MARK: - Panel

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 60, height: 190),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let host = NSHostingView(rootView: DecorHUDView(model: model))
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        self.panel = panel
        return panel
    }

    /// The screen the user is working on: the one under the pointer.
    private var targetScreen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    private func frame(for style: DecorHUDStyle, size: CGSize) -> NSRect {
        guard let screen = targetScreen else { return NSRect(origin: .zero, size: size) }
        switch style {
        case .ring:
            // Just below the notch, or below the menu bar on a screen without
            // one.
            let barHeight = max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY)
            return NSRect(
                x: screen.frame.midX - size.width / 2,
                y: screen.frame.maxY - barHeight - 10 - size.height,
                width: size.width,
                height: size.height
            )
        case .edgeBar, .notch:
            return NSRect(
                x: screen.frame.maxX - size.width - 8,
                y: screen.visibleFrame.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        }
    }
}

// MARK: - Views

private struct DecorHUDView: View {
    @ObservedObject var model: DecorHUDModel

    var body: some View {
        let size = DecorHUDOverlay.size(for: model.style, scale: model.scale)
        Group {
            switch model.style {
            case .ring:
                DecorHUDRing(model: model)
            default:
                DecorHUDBar(model: model)
            }
        }
        .frame(width: size.width, height: size.height)
        .opacity(model.visible ? 1 : 0)
        .scaleEffect(model.visible ? 1 : 0.9)
        .offset(x: model.style == .ring || model.visible ? 0 : 14, y: model.style == .ring && !model.visible ? -8 : 0)
    }
}

private extension DecorHUDModel {
    var tint: Color {
        switch kind {
        case .volume: return .white
        case .brightness: return Color(red: 1.0, green: 0.84, blue: 0.42)
        case .keyboardBacklight: return Color(red: 0.62, green: 0.84, blue: 1.0)
        }
    }

    var glyph: String {
        switch kind {
        case .volume: return muted || level < 0.005 ? "speaker.slash.fill" : "speaker.wave.3.fill"
        case .brightness: return level < 0.35 ? "sun.min.fill" : "sun.max.fill"
        case .keyboardBacklight: return "keyboard.fill"
        }
    }
}

/// A pill on the screen edge: the glyph on top, a vertical level under it.
private struct DecorHUDBar: View {
    @ObservedObject var model: DecorHUDModel

    var body: some View {
        let s = CGFloat(model.scale)
        VStack(spacing: 9 * s) {
            Image(systemName: model.glyph, variableValue: model.level)
                .font(.system(size: 13 * s, weight: .semibold))
                .foregroundStyle(model.tint)
                .frame(height: 16 * s)

            GeometryReader { proxy in
                ZStack(alignment: .bottom) {
                    Capsule().fill(.white.opacity(0.16))
                    Capsule()
                        .fill(model.tint)
                        .frame(height: max(proxy.size.height * model.level, model.level > 0 ? 4 * s : 0))
                        .shadow(color: model.tint.opacity(0.5), radius: 3 * s)
                }
            }
            .frame(width: 5 * s)
        }
        .padding(.vertical, 11 * s)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Capsule().fill(.black.opacity(0.82)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: model.level)
    }
}

/// A circular gauge: the ring fills clockwise from the top.
private struct DecorHUDRing: View {
    @ObservedObject var model: DecorHUDModel

    var body: some View {
        let s = CGFloat(model.scale)
        ZStack {
            Circle().fill(.black.opacity(0.82))
            Circle().strokeBorder(.white.opacity(0.1), lineWidth: 0.5)

            Circle()
                .stroke(.white.opacity(0.16), lineWidth: 6 * s)
                .padding(9 * s)
            Circle()
                .trim(from: 0, to: max(model.level, model.level > 0 ? 0.01 : 0))
                .stroke(model.tint, style: StrokeStyle(lineWidth: 6 * s, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(9 * s)
                .shadow(color: model.tint.opacity(0.45), radius: 3 * s)

            VStack(spacing: 1 * s) {
                Image(systemName: model.glyph, variableValue: model.level)
                    .font(.system(size: 14 * s, weight: .semibold))
                    .foregroundStyle(model.tint)
                Text(model.muted ? "Cisza" : "\(Int((model.level * 100).rounded()))")
                    .font(.system(size: 10 * s, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: model.level)
    }
}
