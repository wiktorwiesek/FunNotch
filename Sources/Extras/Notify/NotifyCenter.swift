//
//  NotifyCenter.swift
//  FunNotch
//
//  The two notification features share one manager:
//    - Wiadomości w notchu: every banner the watcher catches becomes an island
//      (sender and text), with a "Kopiuj kod" button when it holds a code. The
//      cat is in its wing, in the clip that suits the app the news is from.
//    - Lustro powiadomień: the same banners, plus whatever the usernoted
//      database holds when Full Disk Access allows reading it, listed in the
//      Powiadomienia tab.
//

import AppKit
import ApplicationServices
import SwiftUI

/// Called once at startup by the app.
@MainActor
enum NotifyExtras {
    static func start() {
        NotifyCenter.shared.start()
    }
}

@MainActor
final class NotifyCenter: ObservableObject {
    static let shared = NotifyCenter()

    enum IslandScope: String, CaseIterable, Identifiable {
        case messages
        case all

        var id: String { rawValue }

        var title: String {
            switch self {
            case .messages: return "Tylko Wiadomości"
            case .all: return "Wszystkie aplikacje"
            }
        }
    }

    enum DatabaseState: Equatable {
        case off
        case checking
        case active
        case needsFullDiskAccess
        case missing
        case failed(String)
    }

    // MARK: - Settings

    private static let prefix = "extras.notify."
    private let defaults = UserDefaults.standard

    /// Watches banners at all. Off means no islands and an empty mirror source.
    @Published var captureEnabled: Bool { didSet { store(captureEnabled, "capture"); applyCapture() } }
    @Published var islandsEnabled: Bool { didSet { store(islandsEnabled, "islands") } }
    /// Keep the system's own banner off the screen while the notch shows the
    /// notification, so it is not announced twice.
    @Published var hidesBanners: Bool {
        didSet {
            store(hidesBanners, "hideBanners")
            if !hidesBanners { NotificationBannerWatcher.shared.releaseBanners() }
        }
    }
    @Published var islandScope: IslandScope { didSet { store(islandScope.rawValue, "scope") } }
    /// Offer "Kopiuj kod" when a notification holds a verification code.
    @Published var codeDetection: Bool { didSet { store(codeDetection, "codes") } }
    /// Show the text in the island. Off shows only who it is from.
    @Published var showPreview: Bool { didSet { store(showPreview, "preview") } }
    @Published var showsTab: Bool { didSet { store(showsTab, "tab") } }
    @Published var readsDatabase: Bool { didSet { store(readsDatabase, "database"); applyDatabase() } }

    // MARK: - State

    /// Newest first, at most `limit`.
    @Published private(set) var items: [MirroredNotification] = []
    @Published private(set) var databaseState: DatabaseState = .checking

    static let limit = 50

    private var bannerItems: [MirroredNotification] = []
    private var databaseItems: [MirroredNotification] = []
    /// Database rows the user cleared from the tab; usernoted still has them.
    private var hiddenDatabaseIDs = Set<String>()
    /// Banners still on screen, by the id of the item made from them, so an
    /// island's button can press the right one.
    private var liveBanners: [String: CapturedBanner] = [:]

    private let reader = NotificationDatabaseReader()
    private let readerQueue = DispatchQueue(label: "funnotch.notify.database", qos: .utility)
    private var databaseTimer: Timer?
    private var started = false

    private init() {
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            UserDefaults.standard.object(forKey: Self.prefix + key) as? Bool ?? fallback
        }
        captureEnabled = bool("capture", true)
        islandsEnabled = bool("islands", true)
        hidesBanners = bool("hideBanners", true)
        islandScope = UserDefaults.standard.string(forKey: Self.prefix + "scope").flatMap(IslandScope.init) ?? .all
        codeDetection = bool("codes", true)
        showPreview = bool("preview", true)
        showsTab = bool("tab", true)
        // Reading the usernoted database needs Full Disk Access and copies a
        // file on every change, so it stays opt-in.
        readsDatabase = bool("database", false)
    }

    private func store(_ value: Any, _ key: String) {
        defaults.set(value, forKey: Self.prefix + key)
    }

    // MARK: - Lifecycle

    /// Safe to call repeatedly: the watcher, the timer and the palette
    /// command are each set up once.
    func start() {
        guard !started else { return }
        started = true

        NotifyAppDirectory.shared.prefetch()
        NotificationBannerWatcher.shared.onBanner = { [weak self] banner in
            self?.ingest(banner) ?? false
        }
        NotificationBannerWatcher.shared.mayHide = { [weak self] in
            self?.canTakeBannersOver ?? false
        }
        applyCapture()
        applyDatabase()
        announceMissingAccess()

        PaletteCommandRegistry.shared.register(PaletteCommand(
            id: "notify.show",
            title: "Pokaż powiadomienia",
            subtitle: "Lista ostatnich powiadomień w notchu",
            symbol: "bell.fill",
            keywords: ["powiadomienia", "notification", "wiadomości", "kod", "lustro"],
            perform: { NotifyCenter.shared.showTab() }
        ))
    }

    /// Capture is on by default and does nothing without Accessibility, so a
    /// launch without it says so: macOS asks, when it has no answer on record,
    /// and an island offers the repair for when it has a stale one.
    private func announceMissingAccess() {
        guard captureEnabled, NotificationBannerWatcher.shared.state == .needsAccessibility else { return }
        NotificationBannerWatcher.shared.requestAccess()
        // After the notch windows are up and the launch has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            MainActor.assumeIsolated {
                guard NotificationBannerWatcher.shared.state == .needsAccessibility else { return }
                IslandCenter.shared.post(Island(
                    symbol: "bell.slash.fill", tint: .orange,
                    title: "Powiadomienia nie działają",
                    detail: " · brak zgody Dostępność",
                    action: IslandAction(title: "Napraw") { NotifyCenter.shared.openAccessibilitySettings() },
                    duration: 10
                ))
            }
        }
    }

    private func applyCapture() {
        guard started else { return }
        if captureEnabled {
            NotificationBannerWatcher.shared.start()
        } else {
            NotificationBannerWatcher.shared.stop()
        }
    }

    private func applyDatabase() {
        guard started else { return }
        guard readsDatabase else {
            databaseTimer?.invalidate()
            databaseTimer = nil
            databaseItems = []
            databaseState = .off
            // The reader skips files it saw unchanged; without this, switching
            // the source back on would show nothing until the next notification.
            let reader = reader
            readerQueue.async { reader.forget() }
            rebuild()
            return
        }
        guard databaseTimer == nil else { return }
        let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollDatabase() }
        }
        timer.tolerance = 1.5
        RunLoop.main.add(timer, forMode: .common)
        databaseTimer = timer
        pollDatabase()
    }

    /// Opens the notch on the display under the pointer, on the notifications.
    func showTab() {
        let mouse = NSEvent.mouseLocation
        // Not NSMouseInRect: it leaves out the top edge, which is exactly where
        // the pointer sits when the notch is opened by flinging it upwards.
        let target = DesktopGeometry.screen(containing: mouse)?.displayIdentifier
        let models = NotchWindowManager.shared.viewModels
        let chosen = models.filter { $0.screenIdentifier == target }
        for model in chosen.isEmpty ? models : chosen {
            model.open()
            withAnimation(.notchContent) { model.currentTab = .notifications }
        }
    }

    // MARK: - Banners

    /// The notch can stand in for a banner: islands are on, and some notch is
    /// closed and on screen to show one.
    private var canTakeBannersOver: Bool {
        hidesBanners && islandsEnabled
            && NotchWindowManager.shared.viewModels.contains { $0.notchState == .closed && !$0.hiddenForFullscreen }
    }

    /// Records the banner and announces it. True when the notch is showing it,
    /// so the system's copy need not be on screen as well.
    private func ingest(_ banner: CapturedBanner) -> Bool {
        var appName = banner.appName ?? ""
        var bundleIdentifier: String?
        if !appName.isEmpty, let app = NotifyAppDirectory.shared.resolve(name: appName) {
            appName = app.name
            bundleIdentifier = app.bundleIdentifier
        }
        if appName.isEmpty { appName = "Powiadomienie" }

        // FunNotch's own notifications are not news to the person using it.
        let isOwn = bundleIdentifier != nil
            && bundleIdentifier?.lowercased() == Bundle.main.bundleIdentifier?.lowercased()

        var item = MirroredNotification(
            id: UUID().uuidString,
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            title: banner.title,
            subtitle: banner.subtitle,
            body: banner.body,
            date: Date(),
            source: .banner,
            code: nil
        )
        if codeDetection { item.code = OneTimeCode.find(in: banner.text) }

        bannerItems.insert(item, at: 0)
        if bannerItems.count > Self.limit { bannerItems.removeLast(bannerItems.count - Self.limit) }
        liveBanners[item.id] = banner
        if liveBanners.count > 10 {
            let keep = Set(bannerItems.prefix(10).map(\.id))
            liveBanners = liveBanners.filter { keep.contains($0.key) }
        }
        rebuild()

        guard islandsEnabled, !isOwn else { return false }
        if islandScope == .messages, !item.isMessages { return false }
        let takesOver = canTakeBannersOver
        postIsland(for: item)
        return takesOver
    }

    private func postIsland(for item: MirroredNotification) {
        let style = Self.style(for: item)
        let banner = liveBanners[item.id]

        var island: Island
        if let code = item.code, codeDetection {
            island = Island(
                symbol: "key.fill", tint: .yellow,
                title: "Kod " + code,
                detail: " · " + item.appName,
                action: IslandAction(title: "Kopiuj kod") { NotifyCenter.shared.copyCode(code) },
                duration: 8
            )
        } else {
            let heading = item.heading
            let text = Self.oneLine(item.detail, limit: 90)
            island = Island(
                symbol: style.symbol, tint: style.tint,
                title: showPreview ? heading : item.appName,
                detail: showPreview
                    ? (text.isEmpty ? "" : " · " + text)
                    : (item.isMessages ? " · nowa wiadomość" : " · nowe powiadomienie"),
                duration: 5,
                cat: style.cat
            )
            // Replying through the banner's own field is only offered when the
            // banner says it can; everything else opens the app.
            if let banner, let reply = Self.replyAction(of: banner) {
                island.action = IslandAction(title: "Odpowiedz") {
                    NotifyCenter.shared.reply(to: banner, with: reply, item: item)
                }
            } else {
                island.action = IslandAction(title: "Otwórz") {
                    NotifyCenter.shared.open(item, banner: banner)
                }
            }
        }
        // The island stands in for the banner, so a click on it does what a
        // click on the banner does.
        island.onTap = { NotifyCenter.shared.open(item, banner: banner) }
        IslandCenter.shared.post(island)
    }

    private static func replyAction(of banner: CapturedBanner) -> String? {
        banner.actions.first { action in
            let lowered = action.lowercased()
            return lowered.contains("reply") || lowered.contains("odpowiedz")
        }
    }

    /// The symbol, colour and cat of an island, by the app the news is from:
    /// a text message, a chat, mail, and a bell for everything else.
    static func style(for item: MirroredNotification) -> (symbol: String, tint: Color, cat: CatState) {
        switch item.bundleIdentifier?.lowercased() {
        case "com.apple.mobilesms": return ("message.fill", .green, .texting)
        case "com.apple.mail", "com.microsoft.outlook", "com.readdle.smartemail-mac", "com.superhuman.electron":
            return ("envelope.fill", .cyan, .mail)
        case "com.apple.ical": return ("calendar", .red, .ringing)
        case "com.apple.reminders": return ("checklist", .orange, .ringing)
        case "com.tinyspeck.slackmacgap", "dev.vencord.vesktop", "com.hnc.discord", "com.microsoft.teams2":
            return ("bubble.left.fill", .purple, .chatting)
        case "net.whatsapp.whatsapp": return ("phone.bubble.fill", .green, .chatting)
        case "ru.keepcoder.telegram", "org.whispersystems.signal-desktop", "com.facebook.archon":
            return ("paperplane.fill", .cyan, .chatting)
        default:
            return item.isMessages ? ("message.fill", .green, .texting) : ("bell.fill", .white, .ringing)
        }
    }

    private static func oneLine(_ text: String, limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit - 1)) + "…"
    }

    // MARK: - Actions

    /// Puts the code on the pasteboard marked as concealed, so the clipboard
    /// history (here and in other managers) does not keep it.
    func copyCode(_ code: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        IslandCenter.shared.post(Island(
            symbol: "checkmark.circle.fill", tint: .green,
            title: "Skopiowano kod", detail: " · " + code, duration: 2
        ))
    }

    /// Goes to the app a notification is from. While its banner is still up
    /// the banner is pressed, which is what a click on it does and takes the
    /// app to the conversation (it works on a banner kept off the screen
    /// too); once it is gone, the app is simply opened.
    func open(_ item: MirroredNotification, banner: CapturedBanner? = nil) {
        if let banner = banner ?? liveBanners[item.id],
           banner.actions.contains(kAXPressAction as String),
           AXUIElementPerformAction(banner.element, kAXPressAction as CFString) == .success
        {
            return
        }
        openApplication(of: item)
    }

    /// Opens the banner's reply field; when it will not open (the banner has
    /// left, the app's reply works differently), opens the app instead.
    private func reply(to banner: CapturedBanner, with action: String, item: MirroredNotification) {
        NotificationBannerWatcher.shared.reply(to: banner, action: action) { opened in
            if !opened { NotifyCenter.shared.open(item, banner: banner) }
        }
    }

    /// Opens the app a notification came from. Used by the tab, where the
    /// banner is long gone.
    func openApplication(of item: MirroredNotification) {
        guard let url = NotifyAppDirectory.shared.application(for: item) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func copy(_ item: MirroredNotification) {
        guard let code = item.code else { return }
        copyCode(code)
    }

    func clear() {
        hiddenDatabaseIDs.formUnion(databaseItems.map(\.id))
        bannerItems = []
        liveBanners = [:]
        rebuild()
    }

    // MARK: - Database

    private func pollDatabase() {
        let reader = reader
        readerQueue.async { [weak self] in
            let snapshot = reader.read(limit: Self.limit)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(snapshot) }
            }
        }
    }

    private func apply(_ snapshot: DatabaseSnapshot) {
        guard readsDatabase else { return }
        // Assigning a @Published property republishes even for an equal value,
        // so every write below is guarded: the 4 s poll must not redraw the tab.
        func setState(_ state: DatabaseState) {
            if databaseState != state { databaseState = state }
        }
        switch snapshot.access {
        case .readable:
            setState(.active)
        case .needsFullDiskAccess:
            setState(.needsFullDiskAccess)
            if !databaseItems.isEmpty {
                databaseItems = []
                rebuild()
            }
            return
        case .missing:
            setState(.missing)
            if !databaseItems.isEmpty {
                databaseItems = []
                rebuild()
            }
            return
        case let .failed(message):
            setState(.failed(message))
            return
        }

        guard let records = snapshot.records else { return }
        databaseItems = records.map { record in
            let directory = NotifyAppDirectory.shared
            var item = MirroredNotification(
                id: record.uuid,
                bundleIdentifier: record.bundleIdentifier,
                appName: directory.displayName(bundleIdentifier: record.bundleIdentifier),
                title: record.title,
                subtitle: record.subtitle,
                body: record.body,
                date: record.date,
                source: .database,
                code: nil
            )
            if codeDetection { item.code = OneTimeCode.find(in: [record.title, record.subtitle, record.body].joined(separator: " ")) }
            return item
        }
        rebuild()
    }

    /// Fills the list with invented notifications for the preview renderer.
    func injectPreviewItems(_ items: [MirroredNotification]) {
        bannerItems = items
        rebuild()
    }

    /// Banners and database rows together, without the same notification twice.
    private func rebuild() {
        let visibleDatabase = databaseItems.filter { !hiddenDatabaseIDs.contains($0.id) }
        var merged = visibleDatabase
        for banner in bannerItems {
            let duplicate = visibleDatabase.contains { row in
                row.fingerprint == banner.fingerprint
                    && abs(row.date.timeIntervalSince(banner.date)) < 90
                    && (banner.bundleIdentifier == nil
                        || banner.bundleIdentifier?.lowercased() == row.bundleIdentifier?.lowercased())
            }
            if !duplicate { merged.append(banner) }
        }
        merged.sort { $0.date > $1.date }
        let next = Array(merged.prefix(Self.limit))
        if items != next { items = next }
    }

    // MARK: - Permission shortcuts

    /// Asks for Accessibility and opens its pane. A record left by an earlier
    /// signature of the app keeps the switch there on and the access off, and
    /// stops macOS from asking again; while the app is not trusted nothing is
    /// lost by dropping the record first, so the question can be put afresh.
    func openAccessibilitySettings() {
        if !AXIsProcessTrusted(), let identifier = Bundle.main.bundleIdentifier {
            let reset = Process()
            reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            reset.arguments = ["reset", "Accessibility", identifier]
            if (try? reset.run()) != nil {
                reset.waitUntilExit()
                DiagnosticLog.write("notify", "reset the Accessibility record (\(reset.terminationStatus))")
            }
        }
        NotificationBannerWatcher.shared.requestAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
