//
//  WindowSnapOverlay.swift
//  FunNotch
//
//  The drop zones that appear under the notch while a window is being dragged
//  toward it. The panel never takes mouse events — the drag belongs to the
//  window being moved — so which zone is hot is worked out from the pointer's
//  position, and the same cell rectangles drive both the drawing and the
//  hit-testing so the two can never disagree.
//

import AppKit
import SwiftUI

// MARK: - Zones

enum WindowSnapZone: String, CaseIterable, Identifiable {
    case leftHalf, full, rightHalf
    case leftThird, centerThird, rightThird
    case topLeft, topRight, bottomLeft, bottomRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leftHalf: return "Lewa połowa"
        case .rightHalf: return "Prawa połowa"
        case .full: return "Pełny ekran"
        case .leftThird: return "Lewa trzecia"
        case .centerThird: return "Środkowa trzecia"
        case .rightThird: return "Prawa trzecia"
        case .topLeft: return "Lewa górna"
        case .topRight: return "Prawa górna"
        case .bottomLeft: return "Lewa dolna"
        case .bottomRight: return "Prawa dolna"
        }
    }

    /// The part of the screen's usable area the window takes, as fractions with
    /// the origin at the top-left.
    var fraction: CGRect {
        let third = 1.0 / 3.0
        switch self {
        case .leftHalf: return CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case .rightHalf: return CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .full: return CGRect(x: 0, y: 0, width: 1, height: 1)
        case .leftThird: return CGRect(x: 0, y: 0, width: third, height: 1)
        case .centerThird: return CGRect(x: third, y: 0, width: third, height: 1)
        case .rightThird: return CGRect(x: 2 * third, y: 0, width: third, height: 1)
        case .topLeft: return CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        case .topRight: return CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        case .bottomLeft: return CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
        case .bottomRight: return CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        }
    }

    /// The window frame for this zone inside `usable` (CG coordinates). Edges
    /// are rounded, not sizes, so neighbouring zones meet without a gap or an
    /// overlap.
    func frame(in usable: CGRect) -> CGRect {
        let f = fraction
        let minX = (usable.minX + f.minX * usable.width).rounded()
        let maxX = (usable.minX + f.maxX * usable.width).rounded()
        let minY = (usable.minY + f.minY * usable.height).rounded()
        let maxY = (usable.minY + f.maxY * usable.height).rounded()
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

// MARK: - Layout

enum WindowSnapLayout {
    static let padding: CGFloat = 10
    static let gap: CGFloat = 6
    static let rowHeight: CGFloat = 46
    // Wide enough for "Prawa górna" in the quarter row, whose four cells are the narrowest.
    static let width: CGFloat = 540

    /// Rows of cells: halves and full, thirds, quarters.
    private static let rows: [[WindowSnapZone]] = [
        [.leftHalf, .full, .rightHalf],
        [.leftThird, .centerThird, .rightThird],
        [.topLeft, .topRight, .bottomLeft, .bottomRight],
    ]

    static var size: CGSize {
        let count = CGFloat(rows.count)
        return CGSize(width: width, height: padding * 2 + rowHeight * count + gap * (count - 1))
    }

    /// Cell rectangles in panel coordinates, origin top-left.
    static let cells: [(zone: WindowSnapZone, rect: CGRect)] = {
        var result: [(zone: WindowSnapZone, rect: CGRect)] = []
        let contentWidth = width - padding * 2
        for (rowIndex, row) in rows.enumerated() {
            let columns = CGFloat(row.count)
            let cellWidth = (contentWidth - gap * (columns - 1)) / columns
            let y = padding + CGFloat(rowIndex) * (rowHeight + gap)
            for (column, zone) in row.enumerated() {
                let x = padding + CGFloat(column) * (cellWidth + gap)
                result.append((zone, CGRect(x: x, y: y, width: cellWidth, height: rowHeight)))
            }
        }
        return result
    }()

    /// The zone at `point` (panel coordinates). Cells grow by half the gap so
    /// there is no dead strip between them to drop on by accident.
    static func zone(at point: CGPoint) -> WindowSnapZone? {
        cells.first { $0.rect.insetBy(dx: -gap / 2, dy: -gap / 2).contains(point) }?.zone
    }
}

// MARK: - View

@MainActor
final class WindowSnapOverlayModel: ObservableObject {
    @Published var hovered: WindowSnapZone?
}

struct WindowSnapOverlayView: View {
    @ObservedObject var model: WindowSnapOverlayModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.black.opacity(0.9))
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            ForEach(WindowSnapLayout.cells, id: \.zone.id) { cell in
                ZoneCell(zone: cell.zone, isHot: model.hovered == cell.zone)
                    .frame(width: cell.rect.width, height: cell.rect.height)
                    .offset(x: cell.rect.minX, y: cell.rect.minY)
            }
        }
        .frame(width: WindowSnapLayout.size.width, height: WindowSnapLayout.size.height)
        .animation(.easeOut(duration: 0.1), value: model.hovered)
    }
}

private struct ZoneCell: View {
    let zone: WindowSnapZone
    let isHot: Bool

    private let glyphSize = CGSize(width: 26, height: 17)

    var body: some View {
        HStack(spacing: 6) {
            glyph
            Text(zone.title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .foregroundStyle(Color.white.opacity(isHot ? 1 : 0.75))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHot ? Color.accentColor : Color.white.opacity(0.08))
        )
    }

    /// A tiny screen with the zone filled in.
    private var glyph: some View {
        let f = zone.fraction
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color.white.opacity(isHot ? 0.9 : 0.5), lineWidth: 1)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.white.opacity(isHot ? 1 : 0.7))
                .frame(width: glyphSize.width * f.width - 3, height: glyphSize.height * f.height - 3)
                .offset(x: glyphSize.width * f.minX + 1.5, y: glyphSize.height * f.minY + 1.5)
        }
        .frame(width: glyphSize.width, height: glyphSize.height)
    }
}

// MARK: - Panel

@MainActor
final class WindowSnapOverlay {
    static let shared = WindowSnapOverlay()

    private let model = WindowSnapOverlayModel()
    private var panel: NSPanel?
    private var hideGeneration = 0

    /// Where the panel is on screen right now (AppKit coordinates), nil when hidden.
    private(set) var panelFrame: CGRect?
    private(set) var screen: NSScreen?

    private init() {}

    var isVisible: Bool { panelFrame != nil }

    /// The strip around the notch that summons the zones: the middle of the
    /// top edge only. Keeping it narrow is what lets this coexist with an
    /// edge-snapping tool such as Rectangle, which owns the sides and corners.
    static func triggerRect(on screen: NSScreen) -> CGRect {
        let frame = screen.frame
        let halfWidth = measureClosedNotch(for: screen).width / 2 + 120
        let depth: CGFloat = 96
        return CGRect(x: frame.midX - halfWidth, y: frame.maxY - depth, width: halfWidth * 2, height: depth)
    }

    /// Once shown, the zones stay until the pointer clearly leaves them.
    func keepsOpen(for point: CGPoint) -> Bool {
        guard let panelFrame, let screen else { return false }
        return panelFrame.insetBy(dx: -28, dy: -28).contains(point)
            || Self.triggerRect(on: screen).contains(point)
    }

    func show(on screen: NSScreen) {
        guard self.screen !== screen || panelFrame == nil else { return }
        hideGeneration += 1

        let size = WindowSnapLayout.size
        // Hang the panel below the notch, or the menu bar if that is taller.
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        let inset = max(menuBar, measureClosedNotch(for: screen).height) + 8
        let frame = CGRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - inset - size.height,
            width: size.width,
            height: size.height
        )

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(frame, display: false)
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        self.screen = screen
        panelFrame = frame
        DiagnosticLog.write("windowsnap", "zones shown on \(screen.localizedName)")
    }

    func hide() {
        guard let panel, panelFrame != nil else { return }
        panelFrame = nil
        screen = nil
        model.hovered = nil
        hideGeneration += 1
        let generation = hideGeneration
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A new show() during the fade owns the panel again.
                guard let self, self.hideGeneration == generation else { return }
                panel.orderOut(nil)
            }
        })
    }

    func updateHover(at point: CGPoint) {
        let zone = zone(at: point)
        if model.hovered != zone { model.hovered = zone }
    }

    /// The zone under `point` (AppKit coordinates), if the panel is up and the
    /// pointer is on one of its cells.
    func zone(at point: CGPoint) -> WindowSnapZone? {
        guard let panelFrame, panelFrame.contains(point) else { return nil }
        return WindowSnapLayout.zone(at: CGPoint(x: point.x - panelFrame.minX, y: panelFrame.maxY - point.y))
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: WindowSnapLayout.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        // One above the notch's own panels, so the zones stay visible if the
        // notch opens under a pointer that is dragging past it.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let host = NSHostingView(rootView: WindowSnapOverlayView(model: model))
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }
}
