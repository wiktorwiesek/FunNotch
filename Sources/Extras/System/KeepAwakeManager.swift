//
//  KeepAwakeManager.swift
//  FunNotch
//
//  "Nie usypiaj": holds power assertions so the Mac does not go to sleep on
//  idle — the same mechanism `caffeinate -di` uses. It can run without limit,
//  for a set time, or until a clock time. The assertions belong to this
//  process, so quitting the app (or it crashing) releases them: keeping awake
//  never outlives the app.
//

import AppKit
import Foundation
import IOKit.pwr_mgt
import SwiftUI

@MainActor
final class KeepAwakeManager: ObservableObject {
    static let shared = KeepAwakeManager()

    static let keepDisplayKey = "extras.system.keepAwake.keepDisplay"
    /// Minutes the toggle uses when switched on without a choice. 0 = no limit.
    static let defaultMinutesKey = "extras.system.keepAwake.defaultMinutes"
    static let announceKey = "extras.system.keepAwake.announce"

    /// Not the cup: that is the Focus timer's icon, shown in the same row.
    nonisolated static let symbol = "bolt.horizontal.circle"
    nonisolated static let activeSymbol = "bolt.horizontal.circle.fill"

    @Published private(set) var isActive = false
    /// When keeping awake ends; nil while active means "until switched off".
    @Published private(set) var endDate: Date?

    private var systemAssertion = IOPMAssertionID(0)
    private var displayAssertion = IOPMAssertionID(0)
    private var expiry: Timer?
    private var wakeObserver: NSObjectProtocol?

    private init() {
        UserDefaults.standard.register(defaults: [
            Self.keepDisplayKey: true,
            Self.defaultMinutesKey: 0,
            Self.announceKey: true,
        ])
    }

    /// Safe to call repeatedly: the wake observer is added once.
    func start() {
        guard wakeObserver == nil else { return }
        // A run-loop timer only counts time the Mac is awake, so a sleep in the
        // middle of a session would push the end later. On wake, end it if it is
        // due, otherwise set the timer again against the wall clock.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWake() }
        }
    }

    // MARK: Control

    /// Switches on with the length chosen in settings.
    func activateWithDefault() {
        let minutes = UserDefaults.standard.integer(forKey: Self.defaultMinutesKey)
        activate(minutes: minutes > 0 ? minutes : nil)
    }

    /// `nil` keeps the Mac awake until it is switched off.
    func activate(minutes: Int?) {
        activate(until: minutes.map { Date().addingTimeInterval(TimeInterval($0 * 60)) })
    }

    /// Keeps awake until the next time the clock shows `hour:minute`.
    func activate(untilHour hour: Int, minute: Int) {
        let calendar = Calendar.current
        let target = calendar.nextDate(
            after: Date(),
            matching: DateComponents(hour: hour, minute: minute, second: 0),
            matchingPolicy: .nextTime
        )
        activate(until: target)
    }

    func activate(until date: Date?) {
        releaseAssertions()
        expiry?.invalidate()
        expiry = nil

        let keepDisplay = UserDefaults.standard.bool(forKey: Self.keepDisplayKey)
        guard createAssertions(keepDisplay: keepDisplay) else {
            isActive = false
            endDate = nil
            DiagnosticLog.write("keepawake", "could not create power assertion")
            post(symbol: Self.symbol, detail: " · nie udało się włączyć", tint: .orange)
            return
        }

        isActive = true
        endDate = date
        scheduleExpiry(at: date)
        post(symbol: Self.activeSymbol, detail: Self.summary(until: date), tint: .orange)
    }

    func deactivate() {
        finish(detail: " · wyłączone")
    }

    func toggle() {
        if isActive { deactivate() } else { activateWithDefault() }
    }

    private func scheduleExpiry(at date: Date?) {
        expiry?.invalidate()
        expiry = nil
        guard let date else { return }
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.expireIfDue() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        expiry = timer
    }

    private func handleWake() {
        guard isActive, let endDate else { return }
        if Date() >= endDate {
            expireIfDue()
        } else {
            scheduleExpiry(at: endDate)
        }
    }

    private func expireIfDue() {
        guard isActive, let endDate, Date() >= endDate else { return }
        finish(detail: " · czas minął")
    }

    private func finish(detail: String) {
        guard isActive else { return }
        expiry?.invalidate()
        expiry = nil
        releaseAssertions()
        isActive = false
        endDate = nil
        post(symbol: Self.symbol, detail: detail, tint: .white)
    }

    // MARK: Assertions

    private func createAssertions(keepDisplay: Bool) -> Bool {
        let reason = "Fun Notch: Nie usypiaj" as CFString
        let on = IOPMAssertionLevel(kIOPMAssertionLevelOn)
        guard IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, on, reason, &systemAssertion
        ) == kIOReturnSuccess else { return false }

        if keepDisplay,
           IOPMAssertionCreateWithName(
               kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, on, reason, &displayAssertion
           ) != kIOReturnSuccess {
            IOPMAssertionRelease(systemAssertion)
            systemAssertion = 0
            displayAssertion = 0
            return false
        }
        return true
    }

    private func releaseAssertions() {
        if systemAssertion != 0 { IOPMAssertionRelease(systemAssertion) }
        if displayAssertion != 0 { IOPMAssertionRelease(displayAssertion) }
        systemAssertion = 0
        displayAssertion = 0
    }

    // MARK: Text

    private func post(symbol: String, detail: String, tint: Color) {
        guard UserDefaults.standard.bool(forKey: Self.announceKey) else { return }
        IslandCenter.shared.post(Island(symbol: symbol, tint: tint, title: "Nie usypiaj", detail: detail, duration: 2.5))
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Polish.locale
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    /// " · do 18:30" or " · bez limitu".
    static func summary(until date: Date?) -> String {
        guard let date else { return " · bez limitu" }
        if Calendar.current.isDateInToday(date) { return " · do \(clock.string(from: date))" }
        return " · do jutra \(clock.string(from: date))"
    }

    /// What the closed-notch widget shows: "1:23" over an hour, "45 min",
    /// "<1 min", or "∞" with no limit.
    func remainingText(at now: Date = Date()) -> String {
        guard let endDate else { return "∞" }
        let seconds = Int(endDate.timeIntervalSince(now).rounded(.up))
        if seconds <= 0 { return "0 min" }
        if seconds < 60 { return "<1 min" }
        let minutes = (seconds + 59) / 60
        if minutes >= 60 { return String(format: "%d:%02d", minutes / 60, minutes % 60) }
        return "\(minutes) min"
    }

    /// Longer form for tooltips: "do 18:30 (zostało 1:23)".
    func helpText(at now: Date = Date()) -> String {
        guard isActive else { return "Nie usypiaj: wyłączone — kliknij, aby włączyć" }
        guard let endDate else { return "Mac nie zaśnie, dopóki tego nie wyłączysz — kliknij, aby wyłączyć" }
        let remaining = remainingText(at: now)
        return "Mac nie zaśnie do \(Self.clock.string(from: endDate)) (zostało \(remaining)) — kliknij, aby wyłączyć"
    }

    /// The choices offered on right-click and in the palette.
    static let durationChoices: [(title: String, minutes: Int?)] = [
        ("Bez limitu", nil),
        ("15 minut", 15),
        ("1 godzina", 60),
        ("2 godziny", 120),
    ]
}
