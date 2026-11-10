//
//  NotificationsTabView.swift
//  FunNotch
//
//  The Powiadomienia tab: recent notifications in two columns, newest first.
//  Click one to open its app. When a source cannot be read, a line at the
//  bottom says which one and what to turn on.
//

import AppKit
import SwiftUI

struct NotificationsTabView: View {
    @ObservedObject private var center = NotifyCenter.shared
    @ObservedObject private var watcher = NotificationBannerWatcher.shared

    var body: some View {
        VStack(spacing: 6) {
            if center.items.isEmpty {
                emptyState
            } else {
                list
            }
            NotificationSourceBar(center: center, watcher: watcher)
        }
        .padding(.top, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            CatOrSymbol(systemName: "bell.slash", symbolSize: 24, symbolWeight: .light, symbolColor: .white.opacity(0.4), catSize: 42)
            Text("Brak powiadomień")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            Text(emptyHint)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Why the list is empty, said honestly: nothing arrived, or nothing can be seen.
    private var emptyHint: String {
        if watcher.state == .watching || center.databaseState == .active {
            return "Nowe powiadomienia pojawią się tutaj."
        }
        if center.captureEnabled, watcher.state == .needsAccessibility {
            return "Włącz uprawnienie Dostępność, żeby widzieć powiadomienia."
        }
        if !center.captureEnabled, !center.readsDatabase {
            return "Włącz czytanie powiadomień w Ustawieniach → Dodatki."
        }
        if center.readsDatabase, center.databaseState == .needsFullDiskAccess {
            return "Włącz Pełny dostęp do dysku, żeby zobaczyć powiadomienia z Centrum powiadomień."
        }
        return "Powiadomienia pojawią się tutaj, gdy Fun Notch zacznie je widzieć."
    }

    private var list: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                    spacing: 6
                ) {
                    ForEach(center.items) { item in
                        NotificationRow(item: item, now: timeline.date)
                    }
                }
                .padding(.bottom, 2)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

private struct NotificationRow: View {
    let item: MirroredNotification
    let now: Date

    @ObservedObject private var center = NotifyCenter.shared
    @State private var isHovering = false

    var body: some View {
        Button {
            center.openApplication(of: item)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                icon
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(item.appName)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(Self.relativeTime(item.date, now: now))
                            .font(.system(size: 8))
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(1)
                    }
                    Text(item.heading)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineLimit(1)
                    if !item.detail.isEmpty {
                        Text(item.detail)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let code = item.code {
                    Button {
                        center.copy(item)
                    } label: {
                        Text("Kopiuj")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.95))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .notchGlass(in: Capsule(), lit: true)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(NotchPressStyle())
                    .help("Skopiuj kod " + code)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .topLeading)
            .notchGlass(
                in: RoundedRectangle(cornerRadius: 12, style: .continuous),
                lit: isHovering,
                subtle: !isHovering
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(NotchPressStyle(scale: 0.98))
        .notchHoverLift(isHovering, scale: 1.015)
        .onHover { hovering in
            withAnimation(NotchGlassMotion.hover) { isHovering = hovering }
        }
        .help("Otwórz: " + item.appName)
    }

    @ViewBuilder
    private var icon: some View {
        if let image = NotifyAppDirectory.shared.icon(for: item) {
            Image(nsImage: image)
                .resizable()
                .frame(width: 26, height: 26)
        } else {
            Image(systemName: item.isMessages ? "message.fill" : "bell.fill")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 26, height: 26)
                .notchGlass(in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Polish.locale
        formatter.unitsStyle = .short
        return formatter
    }()

    static func relativeTime(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 45 { return "teraz" }
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// One line saying which sources feed the list, with the way to turn on the
/// ones that are off.
private struct NotificationSourceBar: View {
    @ObservedObject var center: NotifyCenter
    @ObservedObject var watcher: NotificationBannerWatcher

    var body: some View {
        HStack(spacing: 10) {
            sourceLabel(
                symbol: bannerSymbol, tint: bannerTint, text: bannerText,
                fix: watcher.state == .needsAccessibility ? ("Włącz", { center.openAccessibilitySettings() }) : nil
            )
            sourceLabel(
                symbol: databaseSymbol, tint: databaseTint, text: databaseText,
                fix: center.databaseState == .needsFullDiskAccess ? ("Włącz", { center.openFullDiskAccessSettings() }) : nil
            )
            Spacer(minLength: 0)
            if !center.items.isEmpty {
                Button("Wyczyść") { center.clear() }
                    .buttonStyle(NotchPressStyle())
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .notchControl(in: Capsule(), resting: true)
            }
        }
        .frame(height: 16)
    }

    private func sourceLabel(symbol: String, tint: Color, text: String, fix: (String, () -> Void)?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
            if let fix {
                Button(fix.0, action: fix.1)
                    .buttonStyle(NotchPressStyle())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .notchControl(in: Capsule(), resting: true)
            }
        }
    }

    // MARK: Banners

    private var bannerText: String {
        if !center.captureEnabled { return "Na żywo: wyłączone" }
        switch watcher.state {
        case .watching: return "Na żywo: działa"
        case .needsAccessibility: return "Na żywo: brak Dostępności"
        case .waitingForNotificationCenter: return "Na żywo: czekam na Centrum powiadomień"
        case .stopped: return "Na żywo: wyłączone"
        }
    }

    private var bannerSymbol: String {
        center.captureEnabled && watcher.state == .watching ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
    }

    private var bannerTint: Color {
        center.captureEnabled && watcher.state == .watching ? .green : .orange
    }

    // MARK: Database

    private var databaseText: String {
        switch center.databaseState {
        case .off: return "Baza: wyłączona"
        case .checking: return "Baza: sprawdzam"
        case .active: return "Baza: odczyt działa"
        case .needsFullDiskAccess: return "Baza: brak Pełnego dostępu do dysku"
        case .missing: return "Baza: nie znaleziono"
        case .failed: return "Baza: błąd odczytu"
        }
    }

    private var databaseSymbol: String {
        switch center.databaseState {
        case .active: return "checkmark.circle.fill"
        case .off, .checking: return "circle.dashed"
        default: return "exclamationmark.circle.fill"
        }
    }

    private var databaseTint: Color {
        switch center.databaseState {
        case .active: return .green
        case .off, .checking: return .gray
        default: return .orange
        }
    }
}
