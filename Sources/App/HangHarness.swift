//
//  HangHarness.swift
//  FunNotch
//
//  Development aid: `FunNotch --hang-harness` hosts the real open notch (the
//  same `ContentView` the panel shows, in an `NSHostingView` configured as the
//  panel's) in an offscreen window and measures what the main thread does
//  while nothing, or only a little, changes. A healthy tree goes quiet; a
//  layout/state feedback loop shows up as run-loop turns that never end and
//  main-thread CPU that never drops.
//
//  Refuses to run unless it is a copy of the app with another bundle
//  identifier and `CFFIXED_USER_HOME` points somewhere else, because it
//  injects fake state and drives the managers.
//
//    FUNNOTCH_HARNESS_SCENARIOS=idle,lyrics,...   run only those (names below)
//

import AppKit
import Combine
import SwiftUI

@MainActor
enum HangHarness {
    static var isRequested: Bool { CommandLine.arguments.contains("--hang-harness") }

    // MARK: Measurement

    /// Time the main run loop spends awake, turn by turn. A turn is the span
    /// between waking up and going back to sleep; SwiftUI's own flush runs
    /// inside it, so a transaction that takes seconds is a turn that does.
    private final class TurnMeter {
        private(set) var turns = 0
        private(set) var busyNanos: UInt64 = 0
        private(set) var worstNanos: UInt64 = 0
        private(set) var slowTurns = 0
        private var started: UInt64 = 0
        private var observers: [CFRunLoopObserver] = []

        func install() {
            let wake = CFRunLoopObserverCreateWithHandler(
                nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min
            ) { [weak self] _, _ in
                self?.started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            }
            let sleep = CFRunLoopObserverCreateWithHandler(
                nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max
            ) { [weak self] _, _ in
                guard let self, started != 0 else { return }
                let elapsed = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - started
                started = 0
                turns += 1
                busyNanos += elapsed
                worstNanos = max(worstNanos, elapsed)
                if elapsed > 50_000_000 { slowTurns += 1 }
            }
            for observer in [wake, sleep].compactMap({ $0 }) {
                CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
                observers.append(observer)
            }
        }

        struct Reading {
            var turns = 0, slowTurns = 0
            var busyMs = 0.0, worstMs = 0.0
        }

        private var baseTurns = 0, baseSlow = 0
        private var baseBusy: UInt64 = 0

        func mark() {
            baseTurns = turns
            baseSlow = slowTurns
            baseBusy = busyNanos
            worstNanos = 0
        }

        func reading() -> Reading {
            Reading(
                turns: turns - baseTurns,
                slowTurns: slowTurns - baseSlow,
                busyMs: Double(busyNanos - baseBusy) / 1e6,
                worstMs: Double(worstNanos) / 1e6
            )
        }
    }

    /// `layout()` calls on the hosting view.
    private final class CountingHostingView: NSHostingView<AnyView> {
        var layouts = 0
        override func layout() {
            layouts += 1
            super.layout()
        }
    }

    private static func threadCPU() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9
    }

    /// How many times each observed object announced a change.
    private final class ChangeCounter {
        private(set) var counts: [String: Int] = [:]
        private var cancellables = Set<AnyCancellable>()
        private var base: [String: Int] = [:]

        func watch<O: ObservableObject>(_ name: String, _ object: O) {
            counts[name] = 0
            object.objectWillChange
                .sink { [weak self] _ in self?.counts[name, default: 0] += 1 }
                .store(in: &cancellables)
        }

        func count<P: Publisher>(_ name: String, _ publisher: P) where P.Failure == Never {
            counts[name] = 0
            publisher
                .dropFirst()
                .sink { [weak self] _ in self?.counts[name, default: 0] += 1 }
                .store(in: &cancellables)
        }

        func mark() { base = counts }

        func delta() -> String {
            counts
                .map { ($0.key, $0.value - (base[$0.key] ?? 0)) }
                .filter { $0.1 > 0 }
                .sorted { $0.0 < $1.0 }
                .map { "\($0.0)=\($0.1)" }
                .joined(separator: " ")
        }
    }

    // MARK: Fixtures

    private static func artwork() -> NSImage {
        let size = CGSize(width: 300, height: 300)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(colors: [
            NSColor(srgbRed: 0.10, green: 0.45, blue: 0.62, alpha: 1),
            NSColor(srgbRed: 0.85, green: 0.30, blue: 0.40, alpha: 1),
        ])?.draw(in: CGRect(origin: .zero, size: size), angle: 35)
        image.unlockFocus()
        return image
    }

    private static func track(playing: Bool, title: String? = nil) -> TrackInfo {
        let environment = ProcessInfo.processInfo.environment
        var track = TrackInfo()
        track.title = title ?? environment["FUNNOTCH_HARNESS_TITLE"] ?? "Tamagotchi"
        track.artist = environment["FUNNOTCH_HARNESS_ARTIST"] ?? "Taco Hemingway"
        track.album = "Jarmark"
        track.duration = 201
        track.elapsed = 84
        track.isPlaying = playing
        track.isShuffled = true
        track.repeatMode = .all
        track.likeStatus = .liked
        track.bundleIdentifier = "com.sertacozercan.Kaset"
        track.artwork = artwork()
        return track
    }

    private static let lyrics: [LyricLine] = [
        LyricLine(time: 10, text: "Wstaję rano, kawa, ciągle ten sam dzień"),
        LyricLine(time: 20, text: "Znowu patrzę w ekran, a on patrzy we mnie"),
        LyricLine(time: 30, text: "Mój tamagotchi umarł, nikt nie wie, jak to jest"),
        LyricLine(time: 40, text: "Dzwoni telefon, nie odbieram, bo nie chcę"),
        LyricLine(time: 50, text: "Wszystko, co mam, mieści się w jednej kieszeni"),
        LyricLine(time: 90, text: "Dalej, dalej, dalej"),
        LyricLine(time: 100, text: "Jeszcze jedna zwrotka"),
    ]

    // MARK: Run

    private static var window: NSWindow?
    private static var hosting: CountingHostingView?
    private static var viewModel: NotchViewModel?
    private static let meter = TurnMeter()
    private static let changes = ChangeCounter()

    static func run() {
        guard Bundle.main.bundleIdentifier != "com.funnotch.FunNotch",
              let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              !home.isEmpty, home.hasPrefix("/tmp") || home.hasPrefix("/private/tmp") || home.hasPrefix("/var/folders"),
              NSHomeDirectory().hasPrefix(home) || NSHomeDirectory().hasPrefix("/private" + home)
        else {
            print("hang harness refuses to run: needs a copy with its own bundle id and CFFIXED_USER_HOME in a temp dir")
            NSApp.terminate(nil)
            return
        }
        // The preferences to run with (a property list, normally an export of
        // the real app's), registered in memory only: never written anywhere.
        if let seed = ProcessInfo.processInfo.environment["FUNNOTCH_HARNESS_SEED"],
           let data = FileManager.default.contents(atPath: seed),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            UserDefaults.standard.register(defaults: plist)
        }
        print("harness: bundle=\(Bundle.main.bundleIdentifier ?? "?") home=\(NSHomeDirectory())")
        print("harness: mediaController=\(Settings.shared.mediaController) tiles=\(Settings.shared.homeTiles.map { "\($0.kind.rawValue)\($0.span)" })")

        let environment = ProcessInfo.processInfo.environment
        let only = environment["FUNNOTCH_HARNESS_SCENARIOS"].map { Set($0.split(separator: ",").map(String.init)) }

        meter.install()
        let viewModel = NotchViewModel(screen: NSScreen.main)
        Self.viewModel = viewModel
        changes.watch("music", MusicManager.shared)
        changes.count("music.track", MusicManager.shared.$track)
        changes.count("music.artwork", MusicManager.shared.$artwork)
        changes.count("music.color", MusicManager.shared.$artworkColor)
        changes.count("music.scrubbing", MusicManager.shared.$isScrubbing)
        changes.watch("playhead", MusicManager.shared.playback)
        changes.watch("lyrics", LyricsManager.shared)
        changes.watch("settings", Settings.shared)
        changes.watch("viewModel", viewModel)
        changes.watch("calendar", CalendarManager.shared)
        changes.watch("agents", AgentSessionsManager.shared)
        changes.watch("battery", BatteryManager.shared)
        changes.watch("decor", DecorStore.shared)
        changes.watch("output", AudioOutputManager.shared)

        let root = AnyView(
            ContentView()
                .environmentObject(viewModel)
                .environmentObject(Settings.shared)
        )
        let hosting = CountingHostingView(rootView: root)
        // As the panel: nothing to tell Auto Layout.
        hosting.sizingOptions = []
        // The very panel and container the notch lives in, parked far off screen.
        let panel = NotchPanel(
            contentRect: CGRect(origin: CGPoint(x: -9000, y: -9000), size: windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .popUpMenu
        panel.acceptsMouseMovedEvents = true
        let container = PassthroughContentView(frame: CGRect(origin: .zero, size: windowSize))
        container.autoresizingMask = [.width, .height]
        container.activeRect = { CGRect(origin: .zero, size: windowSize) }
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        panel.orderFrontRegardless()
        let window: NSWindow = panel
        Self.window = window
        Self.hosting = hosting

        Task { @MainActor in
            await scenarios(only: only)
            NSApp.terminate(nil)
        }
    }

    private static func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
    }

    /// Runs `body` (which may await) and reports the main thread's work over
    /// at least `seconds`.
    private static func measure(_ name: String, seconds: Double, _ body: () async -> Void = {}) async {
        await sleep(0.05)
        meter.mark()
        changes.mark()
        let layoutsBefore = hosting?.layouts ?? 0
        let cpuBefore = threadCPU()
        let wallBefore = Date()
        await body()
        let remaining = seconds - Date().timeIntervalSince(wallBefore)
        if remaining > 0 { await sleep(remaining) }
        let wall = Date().timeIntervalSince(wallBefore)
        let cpu = threadCPU() - cpuBefore
        let reading = meter.reading()
        let line = String(
            format: "%-22@ wall %5.2fs  mainCPU %5.2fs (%3.0f%%)  turns %4d  busy %7.1fms  worst %7.1fms  slow(>50ms) %3d  layouts %4d",
            name as NSString, wall, cpu, cpu / wall * 100, reading.turns, reading.busyMs, reading.worstMs,
            reading.slowTurns, (hosting?.layouts ?? 0) - layoutsBefore
        )
        print(line)
        let published = changes.delta()
        if !published.isEmpty { print("    published: \(published)") }
        fflush(stdout)
    }

    // MARK: Synthetic input

    /// `point` is top-left based, in the window; events want bottom-left.
    private static func windowPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: windowSize.height - point.y)
    }

    private static func send(_ type: NSEvent.EventType, at point: CGPoint, click: Int = 0, flipped: Bool = true) {
        guard let window,
              let event = NSEvent.mouseEvent(
                  with: type, location: flipped ? windowPoint(point) : point, modifierFlags: [],
                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                  context: nil, eventNumber: 0, clickCount: click, pressure: type == .leftMouseUp ? 0 : 1
              )
        else { return }
        window.sendEvent(event)
    }

    /// Puts the (virtual) pointer at `point` (window points from the top-left):
    /// enter and move events handed straight to the hosting view, which is
    /// what its tracking area would have received from the window server.
    private static func hover(at point: CGPoint) {
        guard let window, let hosting else { return }
        let location = windowPoint(point)
        let stamp = ProcessInfo.processInfo.systemUptime
        if let entered = NSEvent.enterExitEvent(
            with: .mouseEntered, location: location, modifierFlags: [], timestamp: stamp,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
        ) {
            hosting.mouseEntered(with: entered)
        }
        if let moved = NSEvent.mouseEvent(
            with: .mouseMoved, location: location, modifierFlags: [], timestamp: stamp,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
        ) {
            hosting.mouseMoved(with: moved)
            window.sendEvent(moved)
        }
    }

    /// Every button the accessibility tree exposes, as (label, frame in
    /// window coordinates, bottom-left origin).
    private static func buttons() -> [(label: String, rect: CGRect)] {
        guard let hosting, let window = hosting.window else { return [] }
        var found: [(String, CGRect)] = []
        func walk(_ element: AnyObject, depth: Int) {
            guard depth < 40, let accessible = element as? NSAccessibilityProtocol else { return }
            if accessible.accessibilityRole() == .button || accessible.accessibilityRole() == .menuButton {
                let screen = accessible.accessibilityFrame()
                let inWindow = window.convertFromScreen(screen)
                let label = accessible.accessibilityLabel() ?? accessible.accessibilityTitle() ?? "?"
                found.append((label, inWindow))
            }
            for child in accessible.accessibilityChildren() ?? [] {
                walk(child as AnyObject, depth: depth + 1)
            }
        }
        walk(hosting, depth: 0)
        return found
    }

    // MARK: Scenarios

    private static func scenarios(only: Set<String>?) async {
        guard let viewModel else { return }
        func wanted(_ name: String) -> Bool { only?.contains(name) ?? true }

        // The collapsed notch first, then open it the way a hover does.
        MusicManager.shared.injectPreviewTrack(track(playing: false))
        LyricsManager.shared.start()
        await sleep(0.4)
        LyricsManager.shared.injectPreview(lines: lyrics, currentIndex: 2)
        // FUNNOTCH_HARNESS_AGENTS="abd" picks sample sessions by their ids.
        let agentIDs = ProcessInfo.processInfo.environment["FUNNOTCH_HARNESS_AGENTS"]
        AgentSessionsManager.shared.injectPreviewSessions(
            PreviewRenderer.sampleSessions().filter { agentIDs?.contains($0.id) ?? true }
        )
        // FUNNOTCH_HARNESS_CAL=0 leaves the calendar without events.
        if ProcessInfo.processInfo.environment["FUNNOTCH_HARNESS_CAL"] != "0" {
            func event(_ id: String, _ title: String, in minutes: Double, meeting: Bool = false) -> AgendaItem {
                AgendaItem(
                    id: id, title: title, start: Date().addingTimeInterval(minutes * 60),
                    end: Date().addingTimeInterval((minutes + 45) * 60), isAllDay: false, calendarColor: .green,
                    calendarTitle: "Praca", kind: .event, location: "Biuro", externalIdentifier: nil,
                    meetingURL: meeting ? URL(string: "https://meet.example.com/abc") : nil
                )
            }
            CalendarManager.shared.injectPreviewItems([
                event("h1", "Spotkanie z dostawcą hurtowni", in: 25, meeting: true),
                event("h2", "Przegląd kampanii Allegro Ads", in: 95),
                event("h3", "Wysyłka paczek, odbiór kuriera", in: 180),
                event("h4", "Rozmowa z księgową o KSeF", in: 260, meeting: true),
            ])
        }
        BatteryManager.shared.start()
        viewModel.setPreviewMusicActivity(true)
        viewModel.setPreviewAgentActivity(AgentActivity(active: 2, waiting: true))

        print("---- closed")
        await measure("closed settle", seconds: 1)

        if wanted("open") {
            await measure("open (animated)", seconds: 3) { viewModel.open() }
        } else {
            viewModel.previewOpen()
        }
        let idle = ProcessInfo.processInfo.environment["FUNNOTCH_HARNESS_IDLE"].flatMap(Double.init) ?? 5
        // FUNNOTCH_HARNESS_TIMER=1 runs a real countdown and stopwatch during
        // the idle window: both publish their time many times a second, so a
        // view that observes them too broadly shows up as constant layout.
        let withTimer = ProcessInfo.processInfo.environment["FUNNOTCH_HARNESS_TIMER"] == "1"
        if withTimer {
            TimerManager.shared.start(seconds: 600)
            TimerManager.shared.startStopwatch()
        }
        await measure("open idle \(Int(idle))s\(withTimer ? " (timer running)" : "")", seconds: idle)
        if withTimer {
            TimerManager.shared.resetCountdown()
            TimerManager.shared.resetStopwatch()
        }
        if let path = ProcessInfo.processInfo.environment["FUNNOTCH_HARNESS_SHOT"], let hosting,
           let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: representation)
            try? representation.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }

        if wanted("buttons") {
            let list = buttons()
            print("accessibility buttons: \(list.map { "\($0.label)@\(Int($0.rect.midX)),\(Int($0.rect.midY))" }.joined(separator: " | "))")
        }

        if wanted("lyrics") {
            await measure("lyric line change x6", seconds: 3) {
                for index in [3, 4, 3, 4, 3, 4] {
                    LyricsManager.shared.injectPreview(lines: lyrics, currentIndex: index)
                    await sleep(0.4)
                }
            }
        }

        if wanted("play") {
            await measure("start playing", seconds: 1) {
                MusicManager.shared.injectPreviewTrack(track(playing: true))
            }
            await measure("playing 5s", seconds: 5)
            await measure("pause", seconds: 1) {
                MusicManager.shared.injectPreviewTrack(track(playing: false))
            }
        }

        if wanted("hover") {
            await measure("pointer sweep", seconds: 4) {
                for pass in 0 ..< 3 {
                    var x = 40.0
                    while x < windowSize.width - 40 {
                        send(.mouseMoved, at: CGPoint(x: x, y: 70 + Double(pass) * 40))
                        x += 18
                        await sleep(0.01)
                    }
                }
            }
        }

        if wanted("click") {
            // FUNNOTCH_HARNESS_CLICKS="name:x,y;name:x,y", window points from the top-left.
            let targets: [(label: String, point: CGPoint)] = (ProcessInfo.processInfo.environment["FUNNOTCH_HARNESS_CLICKS"] ?? "")
                .split(separator: ";").compactMap { item in
                    let parts = item.split(separator: ":")
                    guard parts.count == 2 else { return nil }
                    let xy = parts[1].split(separator: ",").compactMap { Double($0) }
                    return xy.count == 2 ? (String(parts[0]), CGPoint(x: xy[0], y: xy[1])) : nil
                }
            print("click targets: \(targets.map(\.label))")
            for target in targets {
                await measure("click \(target.label)", seconds: 1.5) {
                    send(.mouseMoved, at: target.point)
                    await sleep(0.05)
                    send(.leftMouseDown, at: target.point, click: 1)
                    send(.leftMouseUp, at: target.point, click: 1)
                }
            }
        }

        if wanted("tabs") {
            await measure("tab shelf", seconds: 1.5) { viewModel.currentTab = .shelf }
            await measure("tab home", seconds: 1.5) { viewModel.currentTab = .home }
        }

        if wanted("hoverat") {
            // FUNNOTCH_HARNESS_HOVER="name:x,y;..." — rest the pointer there for a while.
            let spots = (ProcessInfo.processInfo.environment["FUNNOTCH_HARNESS_HOVER"] ?? "")
                .split(separator: ";").compactMap { item -> (String, CGPoint)? in
                    let parts = item.split(separator: ":")
                    guard parts.count == 2 else { return nil }
                    let xy = parts[1].split(separator: ",").compactMap { Double($0) }
                    return xy.count == 2 ? (String(parts[0]), CGPoint(x: xy[0], y: xy[1])) : nil
                }
            for spot in spots {
                await measure("hover \(spot.0)", seconds: 3) {
                    hover(at: spot.1)
                    await sleep(0.3)
                    hover(at: CGPoint(x: spot.1.x + 1, y: spot.1.y))
                }
            }
        }

        if wanted("hoverchurn") {
            // The pointer rests on FUNNOTCH_HARNESS_REST ("x,y") while the player's track keeps changing.
            let rest = (ProcessInfo.processInfo.environment["FUNNOTCH_HARNESS_REST"] ?? "224,138")
                .split(separator: ",").compactMap { Double($0) }
            let point = CGPoint(x: rest.first ?? 224, y: rest.last ?? 138)
            if ProcessInfo.processInfo.environment["FUNNOTCH_HARNESS_KEY"] == "1" { window?.makeKey() }
            hover(at: point)
            await sleep(0.5)
            if let path = ProcessInfo.processInfo.environment["FUNNOTCH_HARNESS_SHOT2"], let hosting,
               let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: representation)
                try? representation.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            await measure("hover rest + churn 10s", seconds: 10) {
                for index in 0 ..< 8 {
                    MusicManager.shared.injectPreviewTrack(track(playing: index % 2 == 0))
                    hover(at: point)
                    await sleep(1.2)
                }
            }
        }

        if wanted("overlay") {
            await measure("overlay lyrics open", seconds: 3) {
                withAnimation(.notchContent) { MediaOverlayState.shared.mode = .lyrics }
            }
            await measure("overlay line change x4", seconds: 3) {
                for index in [3, 4, 3, 4] {
                    LyricsManager.shared.injectPreview(lines: lyrics, currentIndex: index)
                    await sleep(0.5)
                }
            }
            await measure("overlay dismiss", seconds: 2) { MediaOverlayState.shared.dismiss() }
        }

        if wanted("agentchurn") {
            // Agents that are working rewrite their registry entry every few
            // hundred milliseconds (the tool they run, tokens spent), and each
            // rewrite is a new `sessions` value.
            let tools = [
                "Czyta plik Sources/Views/OpenNotchView.swift", "Edytuje HomeGridView.swift", "bash: swift build",
                "Szuka w repozytorium", "Uruchamia testy", "Pisze podsumowanie",
            ]
            await measure("agent churn 12s", seconds: 12) {
                for step in 0 ..< 48 {
                    var list = PreviewRenderer.sampleSessions()
                    for index in list.indices where list[index].status.isActive {
                        list[index].activity = tools[(step + index) % tools.count]
                        list[index].usage = AgentSessionsManager.Usage(
                            tokens: 1_000_000 + step * 1234, cost: 0,
                            contextTokens: 40000 + step * 100, contextWindow: 200_000
                        )
                    }
                    AgentSessionsManager.shared.injectPreviewSessions(list)
                    await sleep(0.25)
                }
            }
        }

        if wanted("churn") {
            // A new track report every 1.2 s, as fast as a backend that changes something each poll.
            await measure("track churn 14s", seconds: 14) {
                for index in 0 ..< 11 {
                    MusicManager.shared.injectPreviewTrack(track(playing: index % 2 == 0))
                    await sleep(1.2)
                }
            }
        }

        if wanted("toggle") {
            // What the play/pause button does, without a backend behind it.
            for index in 0 ..< 3 {
                await measure("togglePlayPause #\(index)", seconds: 1.5) { MusicManager.shared.togglePlayPause() }
            }
        }

        if wanted("tabidle") {
            for tab in [NotchTab.shelf, .notes, .home] {
                viewModel.currentTab = tab
                await measure("idle on tab \(tab)", seconds: 4)
            }
            viewModel.close()
            await measure("closed idle 4s", seconds: 4)
            viewModel.open()
            await sleep(1)
        }

        if wanted("close") {
            await measure("close (animated)", seconds: 2) { viewModel.close() }
            await measure("reopen (animated)", seconds: 3) { viewModel.open() }
        }

        print("harness done")
        fflush(stdout)
    }
}
