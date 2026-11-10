//
//  AgentSessionsTile.swift
//  FunNotch
//
//  Every Claude Code and Codex session on this Mac, what each one is doing,
//  and a click to jump to it.
//

import SwiftUI

struct AgentSessionsTile: View {
    /// The strip along the bottom has room for one session; the main row for
    /// a short list.
    var compact = false

    @ObservedObject private var agents = AgentSessionsManager.shared

    /// Enough to fill the main row without clipping the last one.
    private let maxRows = 3

    var body: some View {
        Group {
            if compact {
                compactBody
            } else {
                fullBody
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: agents.sessions.map(\.id))
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: agents.sessions.map(\.status))
    }

    // MARK: Main row

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if agents.sessions.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(agents.sessions.prefix(maxRows)) { session in
                        AgentRow(session: session)
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .opacity
                            ))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text("AGENCI")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .tracking(0.7)
                .foregroundStyle(.white.opacity(0.35))
            Spacer(minLength: 0)
            summaryBadge
        }
        .padding(.horizontal, 6)
    }

    @ViewBuilder
    private var summaryBadge: some View {
        let hidden = max(agents.sessions.count - maxRows, 0)
        HStack(spacing: 4) {
            if agents.waitingCount > 0 {
                Circle().fill(AgentPalette.waiting).frame(width: 5, height: 5)
                Text("\(agents.waitingCount) \(agents.waitingCount == 1 ? "czeka" : "czekają") na Ciebie")
                    .foregroundStyle(AgentPalette.waiting)
            } else if agents.workingCount > 0 {
                AgentWorkingGlyph(agent: agents.headline?.agent ?? .claude, size: 8)
                Text("\(agents.workingCount) \(agents.workingCount == 1 ? "pracuje" : "pracują")")
                    .foregroundStyle(AgentPalette.claude)
            } else if !agents.sessions.isEmpty {
                Text("Wszystko spokojnie")
                    .foregroundStyle(.white.opacity(0.35))
            }
            if hidden > 0 {
                Text("+\(hidden)")
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .font(.system(size: 9, weight: .semibold))
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            CatOrSymbol(
                systemName: "sparkles", symbolSize: 15, symbolColor: AgentPalette.claude.opacity(0.75),
                catSize: 34, tint: AgentPalette.claude
            )
            Text("Brak uruchomionych agentów")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            Text("Sesje Claude Code i omp pojawią się tutaj")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.35))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Strip

    @ViewBuilder
    private var compactBody: some View {
        if let session = agents.headline {
            Button {
                agents.bringForward(session)
            } label: {
                HStack(spacing: 6) {
                    AgentStatusIcon(session: session, size: 13)
                        .frame(width: 16, height: 16)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(session.name)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.95))
                            .lineLimit(1)
                        Text(compactDetail(for: session))
                            .font(.system(size: 9))
                            .foregroundStyle(AgentRow.detailColor(for: session))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    AgentRowTime(session: session)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(NotchPressStyle(scale: 0.97))
            .notchControl(in: RoundedRectangle(cornerRadius: 6, style: .continuous), lift: 1.02)
            .help("Pokaż: \(session.name)")
        } else {
            HStack(spacing: 6) {
                CatOrSymbol(
                    systemName: "sparkles", symbolSize: 11, symbolColor: AgentPalette.claude.opacity(0.7),
                    catSize: 18, tint: AgentPalette.claude
                )
                Text("Brak uruchomionych agentów")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer(minLength: 0)
            }
        }
    }

    private func compactDetail(for session: AgentSessionsManager.Session) -> String {
        let others = agents.sessions.count - 1
        let base = AgentRow.detail(for: session)
        guard others > 0 else { return base }
        let busyOthers = agents.activeCount - (session.status.isActive ? 1 : 0)
        return busyOthers > 0
            ? "\(base) · jeszcze \(busyOthers) \(Polish.plural(busyOthers, "aktywna", "aktywne", "aktywnych"))"
            : "\(base) · jeszcze \(others)"
    }
}

// MARK: - Rows

private struct AgentRow: View {
    let session: AgentSessionsManager.Session

    var body: some View {
        Button {
            AgentSessionsManager.shared.bringForward(session)
        } label: {
            HStack(spacing: 6) {
                AgentStatusIcon(session: session, size: 12)
                    .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(session.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(session.status.isActive ? 0.95 : 0.7))
                        .lineLimit(1)
                    Text(Self.detail(for: session))
                        .font(.system(size: 9))
                        .foregroundStyle(Self.detailColor(for: session))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                AgentRowTime(session: session)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(NotchPressStyle(scale: 0.97))
        .notchControl(in: RoundedRectangle(cornerRadius: 6, style: .continuous), lift: 1.01)
        .help("\(session.agent.rawValue), projekt \(session.project) — kliknij, aby pokazać")
    }

    static func detail(for session: AgentSessionsManager.Session) -> String {
        let status: String
        switch session.status {
        case .working:
            if let activity = session.activity {
                status = activity
            } else if session.backgroundAgents > 0 {
                // The lead has yielded; only its subagents are still at work.
                status = "W tle: " + Polish.count(session.backgroundAgents, "agent", "agenty", "agentów")
            } else {
                status = session.name == session.project ? "Pracuje" : "Pracuje · \(session.project)"
            }
        case let .waiting(reason):
            status = AgentSessionsManager.waitingText(reason)
        case .idle:
            if let duration = session.lastTurnDuration {
                status = "Zakończono w \(AgentSessionsManager.duration(duration))"
            } else {
                status = session.name == session.project ? "Bezczynny" : "Bezczynny · \(session.project)"
            }
        }
        guard let usage = session.usage else { return status }
        return "\(status) · \(usage.summary)"
    }

    static func detailColor(for session: AgentSessionsManager.Session) -> Color {
        switch session.status {
        case .working: return AgentPalette.claude.opacity(0.9)
        case .waiting: return AgentPalette.waiting
        case .idle:
            return session.lastTurnDuration != nil
                ? AgentPalette.done.opacity(0.85)
                : .white.opacity(0.35)
        }
    }
}

/// A running clock while the session works, how long ago it stopped after.
private struct AgentRowTime: View {
    let session: AgentSessionsManager.Session

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(label(now: context.date))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(color)
        }
    }

    private func label(now: Date) -> String {
        if session.status.isActive {
            let since = session.turnStartedAt ?? session.statusSince
            return AgentSessionsManager.clock(now.timeIntervalSince(since))
        }
        return AgentSessionsManager.ago(session.statusSince, now: now)
    }

    private var color: Color {
        switch session.status {
        case .working: return AgentPalette.claude
        case .waiting: return AgentPalette.waiting
        case .idle: return .white.opacity(0.35)
        }
    }
}

/// Spinner, waving hand, check, or a quiet dot.
struct AgentStatusIcon: View {
    let session: AgentSessionsManager.Session
    var size: CGFloat = 12

    @ObservedObject private var decor = DecorStore.shared

    var body: some View {
        Group {
            switch session.status {
            case .working:
                AgentWorkingGlyph(agent: session.agent, size: size)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            case .waiting:
                AgentWaitingGlyph(size: size)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            case .idle:
                if session.lastTurnDuration != nil {
                    // Only a finish that has just happened plays; one from
                    // earlier is simply there when the notch opens.
                    if Date().timeIntervalSince(session.statusSince) < 6 {
                        if decor.catEnabled {
                            AgentDoneGlyph(time: 60, size: size + 1)
                        } else {
                            IntroTimeline(duration: 1.2) { time in
                                CheckmarkBurst(time: time, size: size + 1)
                            }
                        }
                    } else {
                        AgentDoneGlyph(time: 60, size: size + 1, fresh: false)
                    }
                } else if decor.catEnabled {
                    // Nothing has run yet: the cat dozes.
                    CatView(state: .sleeping, size: size * 1.4, tint: .white.opacity(0.7))
                } else {
                    Circle()
                        .fill(Color.white.opacity(0.24))
                        .frame(width: 5, height: 5)
                }
            }
        }
        .id(statusKey)
    }

    private var statusKey: String {
        switch session.status {
        case .working: return "working"
        case .waiting: return "waiting"
        case .idle: return session.lastTurnDuration == nil ? "idle" : "done"
        }
    }
}
