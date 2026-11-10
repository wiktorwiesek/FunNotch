//
//  HomeStripView.swift
//  FunNotch
//
//  The row along the bottom of the home tab.
//
//  Which panels appear, and in what order, is up to the user: what is worth a
//  glance here is entirely personal, and the strip is small enough that
//  guessing wrong wastes the only row there is. Panels declare a rough weight
//  so the width divides sensibly — a row of buttons needs more room than a
//  battery percentage.
//

import Combine
import SwiftUI

/// Dispatches a compact tile to its panel. The grid owns placement now; these
/// are just the contents.
struct HomeStripPanel: View {
    let tile: HomeTile

    var body: some View {
        switch tile.kind {
        case .quickActions: QuickActionsPanel()
        case .systemStats:  SystemStatsPanel()
        case .battery:      BatteryPanel()
        case .devices:      DevicesPanel()
        case .focusStreak:  FocusStreakPanel()
        case .recentShelf:  RecentShelfPanel()
        case .clipboard:    ClipboardPanel()
        case .wifi:         WiFiPanel()
        case .openApp:      OpenAppPanel(path: tile.appPath)
        case .mediaScrubber: MediaScrubberPanel()
        case .nextEvent:    NextEventPanel()
        case .diskSpace:    DiskSpacePanel()
        default:            EmptyView()
        }
    }
}

/// Every panel sits in the same box, so the strip reads as one row rather than
/// a pile of unrelated widgets.
struct HomePanelChrome<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 6)
            .notchCard(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Shared pieces

/// The caption of a tile or a panel: the body face a step smaller, in
/// sentence case. It used to be 7-point monospaced capitals with their
/// letters spread apart, which says "label" in the voice of a template and
/// was too small to read.
struct PanelLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white.opacity(0.5))
            .lineLimit(1)
    }
}

/// A rolling graph drawn on the same coarse grid as the weather, so the strip
/// and the panel above it look like the same app.
struct PixelSparkline: View {
    let samples: [Double]
    let tint: Color
    private let cell: CGFloat = 2

    var body: some View {
        Canvas { ctx, size in
            // One sample is still worth a bar. Requiring two left the graph
            // blank for the first few seconds after the notch opened.
            guard !samples.isEmpty else { return }
            let columns = max(Int(size.width / cell), 1)
            // Show the most recent `columns` samples, one per grid column.
            let slice = samples.suffix(columns)
            let start = columns - slice.count

            for (i, value) in slice.enumerated() {
                let x = CGFloat(start + i) * cell
                let height = max(CGFloat(value) * size.height, cell)
                var y = size.height - height
                // Snap the top of the bar, then fill down in whole cells.
                y = (y / cell).rounded() * cell
                var run = y
                while run < size.height {
                    // The tip of each bar is brighter than its body, which
                    // gives the graph a readable edge at two pixels wide.
                    let head = run < y + cell
                    ctx.fill(
                        Path(CGRect(x: x, y: run, width: cell, height: cell)),
                        with: .color(tint.opacity(head ? 0.85 : 0.28))
                    )
                    run += cell
                }
            }
        }
    }
}

// MARK: - Quick actions

/// Buttons for the things you would otherwise leave the notch to do.
private struct QuickActionsPanel: View {
    @EnvironmentObject private var viewModel: NotchViewModel
    @ObservedObject private var settings = Settings.shared
    // Focus and the timer publish their remaining time many times a second;
    // observing them would rebuild the whole strip at that rate. Only whether
    // they are running matters here.
    @State private var focusActive = FocusManager.shared.isActive
    @State private var timerActive = TimerManager.shared.isActive
    @ObservedObject private var keepAwake = KeepAwakeManager.shared
    @ObservedObject private var mic = MicMuteManager.shared
    @ObservedObject private var output = AudioOutputManager.shared
    @AppStorage("extras.system.quickActions.keepAwake") private var showKeepAwake = true
    @AppStorage("extras.system.quickActions.mic") private var showMic = true
    @AppStorage("extras.system.quickActions.output") private var showOutput = true

    private static var timerActivity: AnyPublisher<Bool, Never> {
        let timer = TimerManager.shared
        let countdown = Publishers.CombineLatest3(
            timer.$isCountdownRunning,
            timer.$remaining.map { $0 > 0 }.removeDuplicates(),
            timer.$finished
        ).map { $0 || $1 || $2 }
        let stopwatch = Publishers.CombineLatest(
            timer.$isStopwatchRunning,
            timer.$elapsed.map { $0 > 0 }.removeDuplicates()
        ).map { $0 || $1 }
        return Publishers.CombineLatest(countdown, stopwatch)
            .map { $0 || $1 }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    var body: some View {
        QuickActionStrip(items: items)
            .padding(4)
            .onAppear { SystemExtras.start() }
            .onReceive(FocusManager.shared.$isActive.removeDuplicates()) { focusActive = $0 }
            .onReceive(Self.timerActivity) { timerActive = $0 }
    }

    private var items: [QuickActionItem] {
        var list: [QuickActionItem] = [
            QuickActionItem(
                id: "focus",
                symbol: focusActive ? "stop.fill" : "cup.and.saucer.fill",
                label: focusActive ? "Zakończ skupienie" : "Skupienie",
                activeTint: focusActive ? .orange : nil,
                help: focusActive ? "Zakończ skupienie" : "Rozpocznij \(settings.focusDefaultMinutes)-minutowe skupienie",
                menu: focusActive ? [] : [15, 25, 45, 60].map { minutes in
                    PointerMenu.Item(title: "\(minutes) min", isChecked: minutes == settings.focusDefaultMinutes) {
                        FocusManager.shared.start(minutes: minutes)
                    }
                }
            ) {
                if FocusManager.shared.isActive {
                    FocusManager.shared.stop()
                } else {
                    FocusManager.shared.start(minutes: settings.focusDefaultMinutes)
                }
            },
            QuickActionItem(id: "note", symbol: "note.text", label: "Notatka", help: "Otwórz notatki") {
                viewModel.currentTab = .notes
            },
            QuickActionItem(id: "shot", symbol: "camera.viewfinder", label: "Zrzut ekranu", help: "Zaznacz obszar do zrzutu") {
                // The interactive capture, the same one ⌘⇧4 runs. It lands in
                // the shelf on its own, because the screenshot watcher is
                // already looking for it.
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                task.arguments = ["-i", "-c"]
                try? task.run()
            },
            QuickActionItem(
                id: "timer", symbol: "timer", label: "Minutnik",
                activeTint: timerActive ? .green : nil, help: "Otwórz minutnik"
            ) {
                FocusTabState.shared.mode = .timer
                viewModel.currentTab = .focus
            },
        ]
        if showKeepAwake {
            var menu = KeepAwakeManager.durationChoices.map { choice in
                PointerMenu.Item(title: choice.title) { KeepAwakeManager.shared.activate(minutes: choice.minutes) }
            }
            if keepAwake.isActive {
                menu.append(PointerMenu.Item(title: "Wyłącz") { KeepAwakeManager.shared.deactivate() })
            }
            list.append(QuickActionItem(
                id: "awake",
                symbol: keepAwake.isActive ? KeepAwakeManager.activeSymbol : KeepAwakeManager.symbol,
                label: keepAwake.isActive ? "Nie usypia, \(keepAwake.remainingText())" : "Nie usypiaj",
                activeTint: keepAwake.isActive ? .yellow : nil,
                help: keepAwake.helpText(),
                menu: menu
            ) { KeepAwakeManager.shared.toggle() })
        }
        if showMic {
            list.append(QuickActionItem(
                id: "mic",
                symbol: mic.isMuted ? "mic.slash.fill" : "mic.fill",
                label: mic.isMuted ? "Mikrofon wyciszony" : "Wycisz mikrofon",
                activeTint: mic.isMuted ? Color(red: 1, green: 0.35, blue: 0.32) : nil,
                help: mic.isMuted ? "Mikrofon wyciszony. Kliknij, aby włączyć." : "Wycisz mikrofon"
            ) { MicMuteManager.shared.toggle() })
        }
        if showOutput {
            list.append(QuickActionItem(
                id: "output",
                symbol: output.current?.symbol ?? "speaker.wave.2",
                label: output.current?.name ?? "Wyjście dźwięku",
                help: output.helpText,
                menu: output.outputs.map { device in
                    PointerMenu.Item(title: device.name, symbol: device.symbol, isChecked: device.id == output.current?.id) {
                        AudioOutputManager.shared.select(device)
                    }
                }
            ) { AudioOutputManager.shared.showMenu() })
        }
        return list
    }
}

// MARK: - System stats

private struct SystemStatsPanel: View {
    @ObservedObject private var stats = SystemStatsManager.shared

    var body: some View {
        HStack(spacing: 8) {
            graph("CPU", stats.cpuHistory, stats.cpuUsage, .cyan)
            graph("RAM", stats.memoryHistory, stats.memoryUsage, .purple)
        }
        .padding(.vertical, 6)
        .onAppear { stats.addSubscriber() }
        .onDisappear { stats.removeSubscriber() }
    }

    private func graph(_ name: String, _ history: [Double], _ now: Double, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                PanelLabel(text: name)
                Spacer(minLength: 0)
                Text("\(Int(now * 100))%")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tint.opacity(0.9))
            }
            PixelSparkline(samples: history, tint: tint)
        }
    }
}

// MARK: - Battery

/// Battery as a pixel cell meter.
///
/// Colour carries the state, because at this size a percentage alone is
/// something you have to read rather than notice: green when healthy, amber
/// low, red critical, yellow in Low Power Mode, and a filling sweep while it
/// charges.
private enum BatteryState {
    case charging, charged, low, critical, lowPower, normal

    var tint: Color {
        switch self {
        case .charging: return Color(red: 0.35, green: 0.90, blue: 0.45)
        case .charged:  return Color(red: 0.45, green: 0.85, blue: 0.55)
        case .low:      return Color(red: 1.00, green: 0.68, blue: 0.20)
        case .critical: return Color(red: 1.00, green: 0.35, blue: 0.32)
        case .lowPower: return Color(red: 1.00, green: 0.84, blue: 0.25)
        case .normal:   return Color(red: 0.82, green: 0.86, blue: 0.92)
        }
    }
}

private struct BatteryPanel: View {
    @ObservedObject private var battery = BatteryManager.shared

    private var state: BatteryState {
        if battery.isCharged { return .charged }
        if battery.isCharging { return .charging }
        if battery.isLowPowerMode { return .lowPower }
        if battery.level <= 0.10 { return .critical }
        if battery.level <= 0.20 { return .low }
        return .normal
    }

    private var detail: String {
        if battery.isCharging {
            // The real draw beats the adapter's rating: a 96 W brick topping up
            // a nearly full battery delivers a couple of watts.
            if let watts = battery.chargeWatts, watts >= 0.5 {
                return String(format: "Ładuje %.0f W", watts)
            }
            if let minutes = battery.timeRemaining, minutes > 0 {
                return minutes >= 60
                    ? String(format: "%d:%02d do pełna", minutes / 60, minutes % 60)
                    : "\(minutes) min do pełna"
            }
            return "Ładowanie"
        }
        if battery.isCharged {
            return battery.adapterWatts.map { "Naładowana, \($0) W" } ?? "Naładowana"
        }
        if battery.isLowPowerMode { return "Oszczędzanie" }
        if let minutes = battery.timeRemaining, minutes > 0 {
            let hours = minutes / 60
            return hours > 0 ? String(format: "Zostało %d:%02d", hours, minutes % 60) : "Zostało \(minutes) min"
        }
        return battery.isPluggedIn ? "Na zasilaniu" : "Na baterii"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                PanelLabel(text: "Bateria")
                Spacer(minLength: 0)
                Text("\(Int(battery.level * 100))%")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(state.tint)
            }

            BatteryMeter(level: Double(battery.level), state: state,
                         isCharging: battery.isCharging)
                .frame(height: 15)

            Text(detail)
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A smooth battery indicator.
///
/// Drawn with real curves rather than the pixel grid used elsewhere: this is
/// the one panel read at a glance for a number, and chunky cells made it look
/// like a readout from something broken rather than a status.
///
/// Deliberately built from small subviews with explicit sizes. Expressed as one
/// nested chain the Swift type checker took minutes and then gave up.
private struct BatteryMeter: View {
    let level: Double
    let state: BatteryState
    let isCharging: Bool

    var body: some View {
        GeometryReader { geo in
            content(in: geo.size)
        }
    }

    private func content(in size: CGSize) -> some View {
        let h: CGFloat = size.height
        let nub: CGFloat = max(h * 0.16, 2)
        let bodyW: CGFloat = size.width - nub - 2
        let radius: CGFloat = h * 0.34
        let inset: CGFloat = 1.8
        let innerH: CGFloat = h - inset * 2
        let maxW: CGFloat = bodyW - inset * 2
        // Never narrower than it is tall: a sliver of colour at 3% is harder to
        // read than a small rounded block, and reads as empty.
        let innerW: CGFloat = max(maxW * CGFloat(level), innerH)

        return ZStack(alignment: .leading) {
            shell(width: bodyW, height: h, radius: radius)
            terminal(nub: nub, height: h, offset: bodyW + 1)
            fill(width: innerW, height: innerH, radius: radius - inset, inset: inset)
            bolt(height: h, x: boltX(innerW: innerW, bodyW: bodyW, height: h, inset: inset))
        }
        .frame(width: size.width, height: h, alignment: .leading)
    }

    private func shell(width: CGFloat, height: CGFloat, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(Color.white.opacity(0.24), lineWidth: 1.3)
            .frame(width: width, height: height)
    }

    private func terminal(nub: CGFloat, height: CGFloat, offset: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: nub * 0.45, style: .continuous)
            .fill(Color.white.opacity(0.24))
            .frame(width: nub, height: height * 0.38)
            .offset(x: offset)
    }

    private func fill(width: CGFloat, height: CGFloat, radius: CGFloat, inset: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: max(radius, 1), style: .continuous)
        let gradient = LinearGradient(
            colors: [state.tint, state.tint.opacity(0.78)],
            startPoint: .top,
            endPoint: .bottom
        )
        return shape
            .fill(gradient)
            .frame(width: width, height: height)
            .overlay { sheen(width: width, height: height, radius: radius) }
            .clipShape(shape)
            .offset(x: inset)
            .animation(.easeInOut(duration: 0.5), value: level)
    }

    @ViewBuilder
    private func sheen(width: CGFloat, height: CGFloat, radius: CGFloat) -> some View {
        if isCharging {
            ChargingSheen(width: width, height: height)
        } else if state == .critical {
            CriticalPulse(tint: state.tint)
        }
    }

    /// The bolt rides the charge front rather than sitting in the middle of the
    /// shell. Centred, it floats unattached in the empty half at low charge and
    /// reads as decoration; on the front it reads as the place energy is going
    /// in. Clamped so it stays inside the shell at both extremes.
    private func boltX(innerW: CGFloat, bodyW: CGFloat, height: CGFloat, inset: CGFloat) -> CGFloat {
        let size = height * 0.52
        let ideal = inset + innerW - size * 0.72
        return min(max(ideal, inset + 1), bodyW - size - inset - 1)
    }

    @ViewBuilder
    private func bolt(height: CGFloat, x: CGFloat) -> some View {
        if isCharging {
            Image(systemName: "bolt.fill")
                .font(.system(size: height * 0.52, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.55), radius: 1.5)
                .offset(x: x)
        }
    }
}

/// A highlight sweeping along the charge, then a beat of stillness. A shimmer
/// that never stops reads as a loading bar rather than a battery filling.
///
/// Played by Core Animation in the render server. As a 30 fps `TimelineView`
/// it made the notch re-lay-out its whole window about sixty times a second
/// for as long as the notch was open on a charging Mac.
private struct ChargingSheen: NSViewRepresentable {
    let width: CGFloat
    let height: CGFloat

    func makeNSView(context: Context) -> SheenLayerView { SheenLayerView() }

    func updateNSView(_ view: SheenLayerView, context: Context) {
        view.configure(width: width, height: height)
    }
}

private final class SheenLayerView: NSView {
    private let band = CAGradientLayer()
    private var width: CGFloat = 0
    private var height: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        band.colors = [
            NSColor.white.withAlphaComponent(0).cgColor,
            NSColor.white.withAlphaComponent(0.5).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor,
        ]
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.addSublayer(band)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(width: CGFloat, height: CGFloat) {
        guard width != self.width || height != self.height else { return }
        self.width = width
        self.height = height

        let bandWidth = max(width * 0.4, 12)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        band.frame = CGRect(x: 0, y: 0, width: bandWidth, height: height)
        CATransaction.commit()

        // 1.25 s across, from just off the left edge to just off the right,
        // then still until the 2.2 s cycle is up.
        let sweep = CAKeyframeAnimation(keyPath: "transform.translation.x")
        sweep.values = [-bandWidth, width, width]
        sweep.keyTimes = [0, NSNumber(value: 1.25 / 2.2), 1]
        sweep.duration = 2.2
        sweep.repeatCount = .infinity
        sweep.isRemovedOnCompletion = false
        sweep.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        band.removeAllAnimations()
        band.add(sweep, forKey: "sweep")
    }
}

/// Slow breathing on a critical charge. Urgent without strobing. Also played
/// by Core Animation (see `ChargingSheen`).
private struct CriticalPulse: NSViewRepresentable {
    let tint: Color

    func makeNSView(context: Context) -> PulseLayerView { PulseLayerView() }

    func updateNSView(_ view: PulseLayerView, context: Context) {}
}

private final class PulseLayerView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.opacity = 0.10

        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 0.10
        breathe.toValue = 0.38
        // sin(2.6 t) has a period of about 2.4 s: 1.2 s up, 1.2 s down.
        breathe.duration = 1.2
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        breathe.isRemovedOnCompletion = false
        breathe.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 20, preferred: 20)
        layer?.add(breathe, forKey: "breathe")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Bluetooth device batteries

private struct DevicesPanel: View {
    @ObservedObject private var bluetooth = BluetoothMonitor.shared

    private var withBattery: [BluetoothDeviceState] {
        bluetooth.devices.filter { $0.battery != nil }.prefix(3).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            PanelLabel(text: "Urządzenia")
            if withBattery.isEmpty {
                Text(bluetooth.devices.isEmpty ? "Brak połączonych" : "Brak danych o baterii")
                    .font(.system(size: 8))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            } else {
                ForEach(withBattery, id: \.name) { device in
                    HStack(spacing: 4) {
                        Text(device.name)
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        Text("\(Int((device.battery ?? 0) * 100))%")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle((device.battery ?? 1) < 0.2 ? .orange : .white.opacity(0.85))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Focus streak

private struct FocusStreakPanel: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var focus = FocusManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            PanelLabel(text: "Seria skupienia")
            HStack(spacing: 2) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(focus.streak > 0 ? Color.orange : .white.opacity(0.4))
                Text("\(focus.streak)")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.95))
                Text(Polish.plural(focus.streak, "dzień", "dni", "dni"))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Text("Dziś \(FocusManager.duration(focus.todaySeconds))")
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Recent shelf items

private struct RecentShelfPanel: View {
    @ObservedObject private var shelf = ShelfManager.shared
    @EnvironmentObject private var viewModel: NotchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            PanelLabel(text: "Ostatnie")
            if shelf.items.isEmpty {
                Text("Półka jest pusta")
                    .font(.system(size: 8))
                    .foregroundStyle(.white.opacity(0.4))
            } else {
                HStack(spacing: 4) {
                    ForEach(shelf.items.prefix(4)) { item in
                        Button {
                            shelf.open(item)
                        } label: {
                            Group {
                                if let thumb = item.thumbnail {
                                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    Image(systemName: "doc")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.white.opacity(0.7))
                                }
                            }
                            .frame(width: 22, height: 22)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }
                        .buttonStyle(NotchPressStyle(scale: 0.9))
                        .notchControl(in: RoundedRectangle(cornerRadius: 6, style: .continuous), lift: 1.08)
                        .help(item.name)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Last copied

private struct ClipboardPanel: View {
    @ObservedObject private var clipboard = ClipboardManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            PanelLabel(text: "Skopiowane")
            if let entry = clipboard.entries.first {
                Button {
                    clipboard.copyBack(entry)
                } label: {
                    Text(entry.preview)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(NotchPressStyle(scale: 0.97))
                .notchControl(in: RoundedRectangle(cornerRadius: 6, style: .continuous), lift: 1.02)
                .help("Kliknij, aby skopiować ponownie")
            } else {
                Text("Jeszcze nic")
                    .font(.system(size: 8))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Note

private struct NotesPanel: View {
    @ObservedObject private var notes = NotesManager.shared
    @EnvironmentObject private var viewModel: NotchViewModel

    private var firstLines: String {
        notes.text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .prefix(2)
            .joined(separator: "\n")
    }

    var body: some View {
        Button {
            viewModel.currentTab = .notes
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                PanelLabel(text: "Notatka")
                Text(notes.isEmpty ? "Nic nie napisano" : firstLines)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(notes.isEmpty ? 0.4 : 0.8))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(NotchPressStyle(scale: 0.97))
        .notchControl(in: RoundedRectangle(cornerRadius: 6, style: .continuous), lift: 1.02)
        .help("Otwórz kartę Notatki")
    }
}

// MARK: - Wi-Fi

private struct WiFiPanel: View {
    @ObservedObject private var wifi = WiFiMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            PanelLabel(text: "Wi-Fi")
            HStack(spacing: 4) {
                Image(systemName: wifi.isConnected ? "wifi" : "wifi.slash")
                    .font(.system(size: 11))
                    .foregroundStyle(wifi.isConnected ? .white.opacity(0.85) : .white.opacity(0.4))
                Text(wifi.network ?? (wifi.isConnected ? "Połączono" : "Wyłączone"))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            // macOS hides the network name behind location access, so say so
            // rather than looking broken when it is simply not permitted.
            if wifi.isConnected, wifi.network == nil, !wifi.isLocationAuthorized {
                Text("Nazwa wymaga lokalizacji")
                    .font(.system(size: 7))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Its own light monitor: no weather manager, no location prompt.
        .onAppear { wifi.addSubscriber() }
        .onDisappear { wifi.removeSubscriber() }
    }
}

// MARK: - Open app

/// A launcher for one chosen application. Several can sit in the strip, each
/// pointing somewhere different, which is why panels carry a payload.
private struct OpenAppPanel: View {
    let path: String?

    private var url: URL? { path.map { URL(fileURLWithPath: $0) } }

    private var icon: NSImage? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private var name: String {
        url?.deletingPathExtension().lastPathComponent ?? "Wybierz…"
    }

    var body: some View {
        Button {
            guard let url else { return }
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        } label: {
            VStack(spacing: 2) {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 20, height: 20)
                } else {
                    // Set in Settings but since moved or uninstalled, or never
                    // set at all. Either way, say so rather than showing a
                    // button that does nothing.
                    Image(systemName: "questionmark.app.dashed")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.4))
                }
                Text(name)
                    .font(.system(size: 8))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(NotchPressStyle(scale: 0.95))
        .notchControl(in: RoundedRectangle(cornerRadius: 6, style: .continuous), lift: 1.04)
        .disabled(icon == nil)
        .help(icon == nil ? "Wybierz aplikację w Ustawieniach" : "Otwórz: \(name)")
    }
}

// MARK: - Media scrubber

/// Now playing reduced to a title and a progress line. Useful as a tile that
/// only appears while something is playing.
struct MediaScrubberPanel: View {
    @ObservedObject private var music = MusicManager.shared
    @ObservedObject private var playback = MusicManager.shared.playback
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if music.track.isEmpty {
                PanelLabel(text: "Nic nie gra")
            } else {
                Text(music.track.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                Text(music.track.artist)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)

                GeometryReader { geo in
                    let fraction = music.track.duration > 0
                        ? min(max(playback.elapsed / music.track.duration, 0), 1)
                        : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.16))
                        Capsule()
                            .fill(settings.accentColor)
                            .frame(width: geo.size.width * fraction)
                    }
                }
                .frame(height: 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Next event

struct NextEventPanel: View {
    @ObservedObject private var calendar = CalendarManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            PanelLabel(text: "Następne")
            if let item = calendar.nextItem, !item.isSample {
                Text(item.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                if let start = item.start {
                    Text(start.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Polish.locale)))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }
            } else {
                Text("Nic w planach")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Disk space

struct DiskSpacePanel: View {
    @ObservedObject private var stats = SystemStatsManager.shared

    private var freeText: String {
        let gb = Double(stats.diskFreeBytes) / 1_000_000_000
        return gb >= 100 ? String(format: "%.0f GB", gb) : String(format: "%.1f GB", gb)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            PanelLabel(text: "Wolne miejsce")
            Text(freeText)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.95))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule()
                        .fill(stats.diskUsage > 0.9 ? Color.orange : Color.white.opacity(0.7))
                        .frame(width: geo.size.width * stats.diskUsage)
                }
            }
            .frame(height: 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { stats.addSubscriber() }
        .onDisappear { stats.removeSubscriber() }
    }
}
