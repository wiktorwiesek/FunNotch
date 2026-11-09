//
//  NotificationBannerWatcher.swift
//  FunNotch
//
//  Reads notification banners as they appear. macOS has no API for seeing
//  other apps' notifications, but the banner is a window of the
//  `NotificationCenter` process and Accessibility can read its text, so an
//  AXObserver on that process tells us when something shows up.
//
//  What the banner tree looks like was learnt from other tools that read it
//  (PingPlace, UI-scripting threads), not from documentation, so everything is
//  read defensively: texts are found by the identifiers the system gives them
//  ("header", "title", "subtitle", "body") and, failing that, by order.
//    - one banner: an element with subrole AXNotificationCenterAlert
//    - several at once: they collapse into AXNotificationCenterAlertStack
//    - banners appended to a visible window fire AXLayoutChanged, not
//      AXWindowCreated, so that one is observed too
//    - the Notification Center panel and desktop widgets live in windows of
//      the same process and must not be mistaken for banners
//

import AppKit
import ApplicationServices

/// A banner caught on screen.
struct CapturedBanner {
    var appName: String?
    var title: String
    var subtitle: String
    var body: String
    /// The banner element, to press or reply to while it is still visible.
    var element: AXUIElement
    var identifier: String?
    var actions: [String]

    var text: String { [title, subtitle, body].filter { !$0.isEmpty }.joined(separator: " ") }
}

@MainActor
final class NotificationBannerWatcher: ObservableObject {
    static let shared = NotificationBannerWatcher()

    enum State: Equatable {
        case stopped
        case needsAccessibility
        case waitingForNotificationCenter
        case watching
    }

    @Published private(set) var state: State = .stopped

    /// Called for every banner that was not on screen at the previous scan.
    var onBanner: ((CapturedBanner) -> Void)?

    private static let bundleIdentifier = "com.apple.notificationcenterui"
    private static let panelMarker = "widget-editor-button"
    private static let widgetPrefix = "widget-local:"
    private static let itemSubroles: Set<String> = [
        "AXNotificationCenterAlert", "AXNotificationCenterBanner", "AXNotificationCenterNotification",
    ]
    private static let stackSubrole = "AXNotificationCenterAlertStack"
    private static let maxNodes = 600
    private static let maxDepth = 14

    /// A messaging timeout set on one element covers only that element, so
    /// every element the scan touches gets its own, and the whole scan has a
    /// deadline: a Notification Center that hangs mid-scan (after sleep, on
    /// the lock screen) must not freeze the notch for many default timeouts.
    private static var scanDeadline = Date.distantFuture

    private static func reachable(_ element: AXUIElement) -> Bool {
        guard Date() < scanDeadline else { return false }
        AXUIElementSetMessagingTimeout(element, 0.5)
        return true
    }

    private var running = false
    private var timer: Timer?
    private var observer: AXObserver?
    private var applicationElement: AXUIElement?
    private var observedWindows = Set<AXUIElement>()
    private var scanWork: DispatchWorkItem?
    private var firstPendingEvent: Date?
    /// Keys of banners already delivered, with the moment they may count as
    /// new again. A banner with a system identifier is remembered for minutes,
    /// one without only for as long as it plausibly stays on screen.
    private var delivered: [String: Date] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []

    private init() {}

    // MARK: - Lifecycle

    /// Safe to call repeatedly: only one timer and one observer ever exist.
    func start() {
        guard !running else { return }
        running = true

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == Self.bundleIdentifier else { return }
                MainActor.assumeIsolated {
                    // A new Notification Center process has new elements; the
                    // old observer is dead either way.
                    self?.detach()
                    self?.attach()
                }
            }
            workspaceObservers.append(token)
        }

        // Accessibility can be granted after launch, and revoked at any time,
        // so this keeps checking instead of deciding once.
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        attach()
    }

    func stop() {
        guard running else { return }
        running = false
        timer?.invalidate()
        timer = nil
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        detach()
        state = .stopped
    }

    /// Asks macOS for Accessibility access, showing its own prompt.
    func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        attach()
    }

    private func tick() {
        guard running else { return }
        if observer != nil {
            if !AXIsProcessTrusted() {
                DiagnosticLog.write("notify", "Accessibility access was revoked")
                detach()
                state = .needsAccessibility
            }
            return
        }
        attach()
    }

    private func attach() {
        guard running, observer == nil else { return }
        guard AXIsProcessTrusted() else {
            if state != .needsAccessibility { DiagnosticLog.write("notify", "waiting for Accessibility access") }
            state = .needsAccessibility
            return
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).first else {
            state = .waitingForNotificationCenter
            return
        }

        var created: AXObserver?
        guard AXObserverCreate(app.processIdentifier, { _, _, notification, _ in
            let name = notification as String
            MainActor.assumeIsolated { NotificationBannerWatcher.shared.handle(name) }
        }, &created) == .success, let created else {
            state = .waitingForNotificationCenter
            return
        }

        let element = AXUIElementCreateApplication(app.processIdentifier)
        // A hung Notification Center must not hang the notch with it.
        AXUIElementSetMessagingTimeout(element, 1.5)

        // Without this one nothing can be seen at all; the others only make the
        // watcher quicker or catch banners stacked into a visible window.
        let windowCreated = AXObserverAddNotification(created, element, kAXWindowCreatedNotification as CFString, nil)
        guard windowCreated == .success || windowCreated == .notificationAlreadyRegistered else {
            DiagnosticLog.write("notify", "could not observe Notification Center (\(windowCreated.rawValue))")
            state = .waitingForNotificationCenter
            return
        }
        for name in [kAXCreatedNotification, "AXChildrenChanged", "AXLayoutChanged"] {
            _ = AXObserverAddNotification(created, element, name as CFString, nil)
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
        applicationElement = element
        observedWindows.removeAll()
        state = .watching
        DiagnosticLog.write("notify", "watching Notification Center (pid \(app.processIdentifier))")
        registerWindows()
        scheduleScan()
    }

    private func detach() {
        scanWork?.cancel()
        scanWork = nil
        firstPendingEvent = nil
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        applicationElement = nil
        observedWindows.removeAll()
    }

    // MARK: - Events

    private func handle(_ notification: String) {
        guard observer != nil else { return }
        registerWindows()
        scheduleScan()
    }

    /// Windows that appear later get their own subscriptions, because child
    /// and layout changes are reported on the window, not on the application.
    private func registerWindows() {
        guard let observer, let applicationElement else { return }
        let windows = Self.attribute(applicationElement, kAXWindowsAttribute) as? [AXUIElement] ?? []
        observedWindows.formIntersection(windows)
        for window in windows where observedWindows.insert(window).inserted {
            for name in [kAXCreatedNotification, "AXChildrenChanged", "AXLayoutChanged"] {
                _ = AXObserverAddNotification(observer, window, name as CFString, nil)
            }
        }
    }

    /// A banner animates in and its text can arrive a moment after the window,
    /// so scanning waits for the burst of events to settle, but never longer
    /// than a second after the first one.
    private func scheduleScan() {
        let now = Date()
        let first = firstPendingEvent ?? now
        firstPendingEvent = first
        let delay = max(0.05, min(0.3, 1.0 - now.timeIntervalSince(first)))
        scanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.firstPendingEvent = nil
                self?.scan()
            }
        }
        scanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Scanning

    private func scan() {
        guard let applicationElement, observer != nil else { return }
        Self.scanDeadline = Date().addingTimeInterval(1)
        defer { Self.scanDeadline = .distantFuture }
        let windows = Self.attribute(applicationElement, kAXWindowsAttribute) as? [AXUIElement] ?? []
        var banners: [CapturedBanner] = []
        for window in windows {
            banners += Self.banners(in: window)
        }

        let now = Date()
        delivered = delivered.filter { $0.value > now }
        for banner in banners {
            guard !banner.text.isEmpty else { continue }
            let content = [banner.appName ?? "", banner.title, banner.subtitle, banner.body].joined(separator: "\u{1F}")
            let key = (banner.identifier ?? "") + "|" + content
            let lifetime: TimeInterval = banner.identifier == nil ? 15 : 600
            // A banner still on screen stays "delivered": its lifetime restarts on
            // every scan that sees it. Otherwise an alert left up for longer than
            // the lifetime would be announced a second time as soon as any other
            // banner triggered a scan.
            if delivered[key] != nil {
                delivered[key] = now.addingTimeInterval(lifetime)
                continue
            }
            delivered[key] = now.addingTimeInterval(lifetime)
            onBanner?(banner)
        }
    }

    /// One AX element's attributes, fetched in a single round trip to the
    /// Notification Center process.
    private struct Node {
        let element: AXUIElement
        var role = ""
        var subrole = ""
        var identifier: String?
        var text: String?
        var description: String?
        var title: String?
        var children: [AXUIElement] = []
    }

    private static let nodeAttributes: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute, kAXValueAttribute,
        kAXDescriptionAttribute, kAXTitleAttribute, kAXChildrenAttribute,
    ]

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        guard reachable(element) else { return nil }
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func node(_ element: AXUIElement) -> Node {
        var node = Node(element: element)
        guard reachable(element) else { return node }
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, nodeAttributes as CFArray, [], &values) == .success,
              let list = values as? [CFTypeRef], list.count == nodeAttributes.count
        else { return node }

        /// Attributes an element lacks come back as an AXValue of type error.
        func usable(_ value: CFTypeRef) -> CFTypeRef? {
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { return nil }
            return value
        }
        func string(_ index: Int) -> String? {
            guard let value = usable(list[index]) else { return nil }
            if let text = value as? String { return text.isEmpty ? nil : text }
            if let attributed = value as? NSAttributedString { return attributed.string.isEmpty ? nil : attributed.string }
            return nil
        }
        node.role = string(0) ?? ""
        node.subrole = string(1) ?? ""
        node.identifier = string(2)
        node.text = string(3)
        node.description = string(4)
        node.title = string(5)
        if let value = usable(list[6]), let children = value as? [AXUIElement] { node.children = children }
        return node
    }

    private struct TextPiece {
        let identifier: String?
        let value: String
    }

    /// Banners in one Notification Center window, or none when the window is
    /// the Notification Center panel or a desktop widget.
    private static func banners(in window: AXUIElement) -> [CapturedBanner] {
        var budget = maxNodes
        var isPanel = false
        var hasWidget = false

        func visit(_ node: Node, depth: Int) -> [Node] {
            budget -= 1
            if let identifier = node.identifier {
                if identifier == panelMarker { isPanel = true }
                if identifier.hasPrefix(widgetPrefix) { hasWidget = true }
            }
            if itemSubroles.contains(node.subrole) { return [node] }
            var found: [Node] = []
            if depth < maxDepth {
                for child in node.children where budget > 0 {
                    found += visit(Self.node(child), depth: depth + 1)
                }
            }
            if node.subrole == stackSubrole, found.isEmpty { return [node] }
            return found
        }

        let root = node(window)
        var items = visit(root, depth: 0)
        guard !isPanel, !hasWidget else { return [] }
        // A newer macOS may name the banner differently. A window that holds
        // nothing but identified title/body texts is still a banner.
        if items.isEmpty, !texts(in: root).filter({ ["title", "body"].contains($0.identifier ?? "") }).isEmpty {
            items = [root]
        }

        return items.flatMap { item -> [CapturedBanner] in
            let actions = actionNames(of: item.element)
            // The collapsed stack is always called "AXNotificationListItems": it
            // says nothing about which notification is on top, so it must not
            // make two identical messages look like one for ten minutes.
            let identifier = item.subrole == stackSubrole ? nil : item.identifier
            let groups = split(texts(in: item))
            if groups.isEmpty {
                // No readable texts: the banner's own description holds
                // "title, subtitle, body" as one string.
                guard let combined = item.description ?? item.title ?? firstDescription(in: item) else { return [] }
                let parts = combined.components(separatedBy: ", ")
                let title = parts.first ?? combined
                let body = parts.dropFirst().joined(separator: ", ")
                return [CapturedBanner(
                    appName: nil, title: title, subtitle: "", body: body,
                    element: item.element, identifier: identifier, actions: actions
                )]
            }
            return groups.map { group in
                CapturedBanner(
                    appName: group.app, title: group.title, subtitle: group.subtitle, body: group.body,
                    element: item.element, identifier: identifier, actions: actions
                )
            }
        }
    }

    private static func actionNames(of element: AXUIElement) -> [String] {
        guard reachable(element) else { return [] }
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    /// The description of the first descendant that has one.
    private static func firstDescription(in item: Node) -> String? {
        var budget = 80
        func search(_ node: Node, depth: Int) -> String? {
            budget -= 1
            if node.role == kAXStaticTextRole, let text = node.text ?? node.description { return text }
            if depth > 0, let description = node.description { return description }
            guard depth < 8 else { return nil }
            for child in node.children where budget > 0 {
                if let found = search(Self.node(child), depth: depth + 1) { return found }
            }
            return nil
        }
        return search(item, depth: 0)
    }

    /// Every text inside a banner, in reading order, with the identifier the
    /// system gave it where there is one.
    private static func texts(in root: Node) -> [TextPiece] {
        var pieces: [TextPiece] = []
        var budget = 120
        let known: Set<String> = ["header", "title", "subtitle", "body"]

        func walk(_ node: Node, depth: Int) {
            budget -= 1
            let identified = node.identifier.map(known.contains) ?? false
            if identified || node.role == kAXStaticTextRole,
               let value = node.text ?? node.description ?? node.title
            {
                pieces.append(TextPiece(identifier: identified ? node.identifier : nil, value: value))
            }
            guard depth < 10 else { return }
            for child in node.children where budget > 0 {
                walk(Self.node(child), depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        return pieces
    }

    private struct TextGroup {
        var app: String?
        var title = ""
        var subtitle = ""
        var body = ""
        var isEmpty: Bool { title.isEmpty && subtitle.isEmpty && body.isEmpty }
    }

    /// Cuts the texts into one group per notification: a stack holds several,
    /// and each starts with its own header or title.
    private static func split(_ pieces: [TextPiece]) -> [TextGroup] {
        guard !pieces.isEmpty else { return [] }
        var groups: [TextGroup] = []
        var current = TextGroup()

        if pieces.contains(where: { $0.identifier == "title" || $0.identifier == "body" }) {
            for piece in pieces {
                switch piece.identifier {
                case "header":
                    if !current.isEmpty { groups.append(current) }
                    current = TextGroup(app: piece.value)
                case "title":
                    if !current.title.isEmpty { groups.append(current); current = TextGroup(app: current.app) }
                    current.title = piece.value
                case "subtitle":
                    current.subtitle = piece.value
                case "body":
                    current.body = current.body.isEmpty ? piece.value : current.body + " " + piece.value
                default:
                    break
                }
            }
            if !current.isEmpty { groups.append(current) }
            return groups
        }

        // No identifiers: the first text is the title and the rest the message.
        // The relative time a banner can carry ("teraz") is not part of it.
        let words = Set(["teraz", "now"])
        let values = pieces.map(\.value).filter { !words.contains($0.lowercased()) }
        guard let first = values.first else { return [] }
        current.title = first
        current.body = values.dropFirst().joined(separator: " ")
        return [current]
    }
}
