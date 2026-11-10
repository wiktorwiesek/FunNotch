//
//  CatPreviewScenes.swift
//  FunNotch
//
//  Preview scenes for the cat, rendered by `FunNotch --render-preview`:
//  every integration point with the cat on (and a few with it off, to show the
//  old glyphs are back), plus a contact sheet that draws every still of every
//  animation, because Core Animation does not run in an offscreen capture.
//
//  Everything here writes the cat's two settings, so a run that stops after
//  only some of the `cat-` scenes leaves them changed; run it in a copy with
//  its own bundle id and `CFFIXED_USER_HOME`, as every preview run should be.
//

import AppKit
import SwiftUI

extension PreviewRenderer {
    private static func catTrack(playing: Bool) -> TrackInfo {
        var track = TrackInfo()
        track.title = "Tamagotchi"
        track.artist = "Taco Hemingway"
        track.album = "Jarmark"
        track.duration = 201
        track.elapsed = 84
        track.isPlaying = playing
        track.bundleIdentifier = "com.sertacozercan.Kaset"
        return track
    }

    private static func catSet(enabled: Bool = true, resident: Bool = true) {
        DecorStore.shared.catEnabled = enabled
        DecorStore.shared.catResident = resident
    }

    /// Clock on the left, battery and processor on the right, nothing else.
    private static func catWidgetsOnly(_ viewModel: NotchViewModel) {
        let settings = Settings.shared
        settings.idleWidgetsEnabled = true
        settings.idleLeftWidgets = [.clock]
        settings.idleRightWidgets = [.battery, .cpu]
        MusicManager.shared.clearPreviewTrack()
        viewModel.setPreviewMusicActivity(false)
        AgentSessionsManager.shared.injectPreviewSessions([])
        viewModel.setPreviewAgentActivity(AgentActivity())
        CatPresence.shared.injectPreview(away: false)
    }

    static func appendCatScenes(to scenes: inout [QAScene]) {
        let saved = (DecorStore.shared.catEnabled, DecorStore.shared.catResident)
        CatPresence.shared.injectPreview(away: false)

        // The cat that lives beside the cutout: alone, beside the widgets
        // (awake, asleep, standing in for the agent light), and switched off.
        scenes.append(("cat-closed-idle", { viewModel in
            catSet()
            Settings.shared.idleWidgetsEnabled = false
            MusicManager.shared.clearPreviewTrack()
            viewModel.setPreviewMusicActivity(false)
            AgentSessionsManager.shared.injectPreviewSessions([])
            viewModel.setPreviewAgentActivity(AgentActivity())
        }))

        scenes.append(("cat-closed-resident-widgets", { viewModel in
            catSet()
            catWidgetsOnly(viewModel)
        }))

        scenes.append(("cat-closed-resident-asleep", { viewModel in
            catSet()
            catWidgetsOnly(viewModel)
            CatPresence.shared.injectPreview(away: true)
        }))

        scenes.append(("cat-closed-resident-agents-working", { viewModel in
            catSet()
            catWidgetsOnly(viewModel)
            let sessions = Self.sampleSessions()
            AgentSessionsManager.shared.injectPreviewSessions([sessions[0], sessions[3]])
            viewModel.setPreviewAgentActivity(AgentActivity(active: 2, waiting: false))
        }))

        scenes.append(("cat-closed-resident-agent-waiting", { viewModel in
            catSet()
            catWidgetsOnly(viewModel)
            AgentSessionsManager.shared.injectPreviewSessions([Self.sampleSessions()[1]])
            viewModel.setPreviewAgentActivity(AgentActivity(active: 1, waiting: true))
        }))

        scenes.append(("cat-closed-resident-focus", { viewModel in
            catSet()
            catWidgetsOnly(viewModel)
            DecorStore.shared.mascot = .rocket
            FocusManager.shared.injectPreviewSession(minutes: 25, elapsedFraction: 0.35)
            viewModel.refreshPreviewFocusActivity()
        }))

        scenes.append(("cat-closed-resident-off", { viewModel in
            catSet(resident: false)
            catWidgetsOnly(viewModel)
            FocusManager.shared.clearPreviewSession()
            viewModel.setPreviewFocusActivity(false)
        }))

        // A notification of each kind: the cat reads, chats, holds the letter
        // or listens to the bell, by the app the news is from.
        let notifications: [(name: String, app: String, bundle: String, title: String, body: String)] = [
            ("sms", "Wiadomości", "com.apple.MobileSMS", "Anna", "Będę za dziesięć minut"),
            ("chat", "Slack", "com.tinyspeck.slackmacgap", "Marta", "Wrzuciłam nowe zdjęcia do kanału"),
            ("mail", "Mail", "com.apple.mail", "Hurtownia", "Potwierdzenie zamówienia"),
            ("other", "Kalendarz sprzątania", "com.example.other", "Przypomnienie", "Podlej kwiaty"),
        ]
        for sample in notifications {
            scenes.append(("cat-closed-notify-\(sample.name)", { viewModel in
                catSet()
                let item = MirroredNotification(
                    id: sample.name, bundleIdentifier: sample.bundle, appName: sample.app,
                    title: sample.title, subtitle: "", body: sample.body, date: Date(), source: .banner, code: nil
                )
                let style = NotifyCenter.style(for: item)
                IslandCenter.shared.post(Island(
                    symbol: style.symbol, tint: style.tint, title: item.heading, detail: item.detail,
                    action: IslandAction(title: "Otwórz") {}, cat: style.cat
                ))
                viewModel.expandingView = SneakPeek(show: true, type: .island, value: 0, icon: style.symbol)
            }))
        }

        scenes.append(("cat-closed-music", { viewModel in
            catSet()
            MusicManager.shared.injectPreviewTrack(catTrack(playing: true))
            viewModel.refreshPreviewMusicActivity()
        }))

        scenes.append(("cat-closed-music-paused", { viewModel in
            catSet()
            MusicManager.shared.injectPreviewTrack(catTrack(playing: false))
            viewModel.refreshPreviewMusicActivity()
        }))

        scenes.append(("cat-closed-peek-music", { viewModel in
            catSet()
            MusicManager.shared.injectPreviewTrack(catTrack(playing: true))
            viewModel.refreshPreviewMusicActivity()
            viewModel.sneakPeek = SneakPeek(show: true, type: .music)
        }))

        scenes.append(("cat-closed-agent-wings", { viewModel in
            catSet()
            Settings.shared.idleWidgetsEnabled = false
            AgentSessionsManager.shared.injectPreviewSessions([Self.sampleSessions()[0]])
            viewModel.setPreviewAgentActivity(AgentActivity(active: 1, waiting: false))
        }))

        scenes.append(("cat-closed-agent-wings-waiting", { viewModel in
            catSet()
            Settings.shared.idleWidgetsEnabled = false
            AgentSessionsManager.shared.injectPreviewSessions([Self.sampleSessions()[0]])
            viewModel.setPreviewAgentActivity(AgentActivity(active: 1, waiting: true))
        }))

        scenes.append(("cat-closed-agent-light", { viewModel in
            catSet()
            let settings = Settings.shared
            settings.idleWidgetsEnabled = true
            settings.idleLeftWidgets = [.clock]
            settings.idleRightWidgets = [.battery]
            AgentSessionsManager.shared.injectPreviewSessions(Array(Self.sampleSessions().prefix(1)) + [Self.sampleSessions()[3]])
            viewModel.setPreviewAgentActivity(AgentActivity(active: 2, waiting: false))
        }))

        scenes.append(("cat-closed-agent-finished", { viewModel in
            catSet()
            AgentSessionsManager.shared.injectPreview(.finished(194), broadcast: false)
            viewModel.expandingView = SneakPeek(show: true, type: .agent)
        }))

        scenes.append(("cat-closed-agent-needs", { viewModel in
            catSet()
            AgentSessionsManager.shared.injectPreview(.needsInput("permission prompt"), broadcast: false)
            viewModel.expandingView = SneakPeek(show: true, type: .agent)
        }))

        scenes.append(("cat-closed-agent-started", { viewModel in
            catSet()
            AgentSessionsManager.shared.injectPreview(.started, broadcast: false)
            viewModel.expandingView = SneakPeek(show: true, type: .agent)
        }))

        scenes.append(("cat-closed-screenshot", { viewModel in
            catSet()
            ScreenshotWatcher.shared.injectPreviewCatch("Screenshot 2026-08-01 at 10.24.11.png")
            viewModel.expandingView = SneakPeek(show: true, type: .screenshot, value: 1, icon: "camera.viewfinder")
        }))

        scenes.append(("cat-closed-download", { viewModel in
            catSet()
            viewModel.expandingView = SneakPeek(show: true, type: .download, value: 1, icon: "arrow.down.circle.fill")
        }))

        scenes.append(("cat-closed-focus", { viewModel in
            catSet()
            DecorStore.shared.mascot = .cat
            MusicManager.shared.clearPreviewTrack()
            viewModel.setPreviewMusicActivity(false)
            AgentSessionsManager.shared.injectPreviewSessions([])
            viewModel.setPreviewAgentActivity(AgentActivity())
            FocusManager.shared.injectPreviewSession(minutes: 25, elapsedFraction: 0.35)
            viewModel.refreshPreviewFocusActivity()
        }))

        scenes.append(("cat-closed-focus-banner-done", { viewModel in
            catSet()
            FocusManager.shared.injectPreviewSession(minutes: 25, elapsedFraction: 1)
            viewModel.expandingView = SneakPeek(show: true, type: .focus, value: 1, icon: "checkmark.circle.fill")
        }))

        scenes.append(("cat-open-home-music", { viewModel in
            catSet()
            FocusManager.shared.clearPreviewSession()
            viewModel.setPreviewFocusActivity(false)
            MusicManager.shared.injectPreviewTrack(catTrack(playing: true))
            viewModel.refreshPreviewMusicActivity()
            AgentSessionsManager.shared.injectPreviewSessions(Self.sampleSessions())
            viewModel.previewOpen()
            viewModel.currentTab = .home
        }))

        scenes.append(("cat-open-home-empty", { viewModel in
            catSet()
            MusicManager.shared.clearPreviewTrack()
            viewModel.setPreviewMusicActivity(false)
            AgentSessionsManager.shared.injectPreviewSessions([])
            viewModel.previewOpen()
            viewModel.currentTab = .home
        }))

        scenes.append(("cat-open-shelf-empty", { viewModel in
            catSet()
            ShelfManager.shared.injectPreviewItems([String]())
            viewModel.previewOpen()
            viewModel.currentTab = .shelf
        }))

        // The same places with the cat off: the old glyphs, exactly.
        scenes.append(("cat-off-closed-music", { viewModel in
            catSet(enabled: false)
            MusicManager.shared.injectPreviewTrack(catTrack(playing: true))
            viewModel.refreshPreviewMusicActivity()
        }))

        scenes.append(("cat-off-closed-agent-wings", { viewModel in
            catSet(enabled: false)
            Settings.shared.idleWidgetsEnabled = false
            AgentSessionsManager.shared.injectPreviewSessions([Self.sampleSessions()[0]])
            viewModel.setPreviewAgentActivity(AgentActivity(active: 1, waiting: false))
        }))

        scenes.append(("cat-off-closed-agent-finished", { viewModel in
            catSet(enabled: false)
            AgentSessionsManager.shared.injectPreview(.finished(194), broadcast: false)
            viewModel.expandingView = SneakPeek(show: true, type: .agent)
        }))

        scenes.append(("cat-off-open-home-empty", { viewModel in
            catSet(enabled: false)
            MusicManager.shared.clearPreviewTrack()
            viewModel.setPreviewMusicActivity(false)
            AgentSessionsManager.shared.injectPreviewSessions([])
            viewModel.previewOpen()
            viewModel.currentTab = .home
        }))

        catEmptyScenes(&scenes)

        scenes.append(("cat-zz-restore", { _ in
            catSet(enabled: saved.0, resident: saved.1)
        }))
    }

    private static func catEmptyScenes(_ scenes: inout [QAScene]) {
        scenes.append(("cat-open-clipboard-empty", { viewModel in
            catSet()
            ClipboardManager.shared.injectPreviewEntries([(ClipboardEntry.Payload, String?)]())
            viewModel.previewOpen()
            viewModel.currentTab = .clipboard
        }))

        scenes.append(("cat-open-notifications-empty", { viewModel in
            catSet()
            viewModel.previewOpen()
            viewModel.currentTab = .notifications
        }))
    }

    static func appendCatJobs(to jobs: inout [(name: String, size: CGSize, dark: Bool, make: () -> AnyView)]) {
        let sheet = CatContactSheet.size
        // Off first, so a run leaves the cat on, which is its default.
        for enabled in [false, true] {
            jobs.append(("cat-tile-agents-empty\(enabled ? "" : "-off")", CGSize(width: 300, height: 128), true, {
                catSet(enabled: enabled)
                AgentSessionsManager.shared.injectPreviewSessions([])
                return AnyView(
                    AgentSessionsTile()
                        .frame(width: 270, height: 100)
                        .padding(14)
                        .background(Color.black)
                )
            }))
            jobs.append(("cat-tile-agents-compact-empty\(enabled ? "" : "-off")", CGSize(width: 270, height: 74), true, {
                catSet(enabled: enabled)
                AgentSessionsManager.shared.injectPreviewSessions([])
                return AnyView(
                    AgentSessionsTile(compact: true)
                        .frame(width: 240, height: 44)
                        .padding(15)
                        .background(Color.black)
                )
            }))
            jobs.append(("cat-tile-agents-rows\(enabled ? "" : "-off")", CGSize(width: 300, height: 128), true, {
                catSet(enabled: enabled)
                AgentSessionsManager.shared.injectPreviewSessions(Self.sampleSessions())
                return AnyView(
                    AgentSessionsTile()
                        .frame(width: 270, height: 100)
                        .padding(14)
                        .background(Color.black)
                )
            }))
        }
        jobs.append(("cat-sheet", sheet, true, { AnyView(CatContactSheet()) }))
        jobs.append(("cat-sheet-actual", CGSize(width: 640, height: 280), true, { AnyView(CatActualSizeSheet()) }))
    }
}

// MARK: - Contact sheets

/// Every distinct still of every state, large, one row per state.
struct CatContactSheet: View {
    private static let columns = 12
    private static let cell: CGFloat = 64

    private static func stills(of state: CatState) -> [CatPose] {
        let clip = CatClips.clip(for: state)
        var seen: [CatPose] = []
        for step in clip.intro + clip.loop where !seen.contains(step.pose) { seen.append(step.pose) }
        return seen
    }

    static var size: CGSize {
        var height: CGFloat = 24
        for state in CatState.allCases {
            let rows = (stills(of: state).count + columns - 1) / columns
            height += 26 + CGFloat(rows) * (cell + 6) + 10
        }
        return CGSize(width: CGFloat(columns) * (cell + 6) + 36, height: height)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(CatState.allCases) { state in
                let poses = Self.stills(of: state)
                let clip = CatClips.clip(for: state)
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(state.rawValue) — \(poses.count) stills, intro \(clip.intro.count) steps / loop \(clip.loop.count) steps, loop \(String(format: "%.2f", clip.loopDuration)) s")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(height: 20)
                    let rows = stride(from: 0, to: poses.count, by: Self.columns).map {
                        Array(poses[$0 ..< min($0 + Self.columns, poses.count)])
                    }
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 6) {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, pose in
                                CatStillImage(pose: pose, size: Self.cell - 8, tint: CatStatesPreview.tint(for: state))
                                    .frame(width: Self.cell, height: Self.cell)
                                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(Color.black)
    }
}

/// The resting pose of every state at the sizes the notch uses, 1:1 and 3×
/// zoomed, on notch black: what 12–20 pt of cat really looks like.
struct CatActualSizeSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach([13.0, 16.0, 20.0, 26.0], id: \.self) { size in
                HStack(spacing: 14) {
                    Text("\(Int(size)) pt").font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.5)).frame(width: 36)
                    ForEach(CatState.allCases) { state in
                        CatStillImage(pose: CatClips.clip(for: state).rest, size: size, tint: CatStatesPreview.tint(for: state))
                            .frame(width: 40, height: 28)
                    }
                }
            }
            HStack(spacing: 14) {
                Text("56 pt").font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.5)).frame(width: 36)
                ForEach(CatState.allCases) { state in
                    CatStillImage(pose: CatClips.clip(for: state).rest, size: 56, tint: CatStatesPreview.tint(for: state))
                        .frame(width: 56, height: 56)
                }
            }
        }
        .padding(16)
        .frame(width: 640, height: 280, alignment: .topLeading)
        .background(Color.black)
    }
}
