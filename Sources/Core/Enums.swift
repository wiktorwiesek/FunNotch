//
//  Enums.swift
//  FunNotch
//
//  Shared enumerations describing notch state, content types and user options.
//

import SwiftUI

/// Whether the notch panel is collapsed to the hardware notch or expanded.
enum NotchState {
    case closed
    case open
}

/// What the notch is currently reporting in its "live activity" area.
enum SneakContentType {
    case music
    case battery
    case download
    case focus
    case screenshot
    case bluetooth
    /// Volume, brightness or keyboard backlight, replacing the system panel.
    case hud
    /// A Claude Code or Codex session starting, finishing or waiting for you.
    case agent
    case none
}

/// Top level sections available inside the expanded notch.
enum NotchTab: String, CaseIterable, Identifiable {
    case home = "Home"
    case shelf = "Shelf"
    case clipboard = "Clipboard"
    /// Focus sessions, the countdown timer and the stopwatch, together.
    case focus = "Focus"
    case notes = "Notes"
    case game = "Game"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .shelf: return "tray.fill"
        case .clipboard: return "doc.on.clipboard.fill"
        case .focus: return "timer"
        case .notes: return "note.text"
        case .game: return "gamecontroller.fill"
        }
    }

    /// What the tab is called in its tooltip, where there is room to say it.
    var title: String {
        switch self {
        case .home: return "Start"
        case .shelf: return "Półka"
        case .clipboard: return "Schowek"
        case .focus: return "Skupienie i minutnik"
        case .notes: return "Notatki"
        case .game: return "Gry"
        }
    }
}

/// How the collapsed notch height is derived on a given display.
enum WindowHeightMode: String, CaseIterable, Identifiable {
    case matchMenuBar = "Match menubar height"
    case matchRealNotchSize = "Match real notch size"
    case custom = "Custom height"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .matchMenuBar: return "Jak pasek menu"
        case .matchRealNotchSize: return "Jak fizyczny notch"
        case .custom: return "Własna"
        }
    }
}

enum MirrorShapeEnum: String, CaseIterable, Identifiable {
    case circle = "Circle"
    case rectangle = "Rectangle"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .circle: return "Koło"
        case .rectangle: return "Zaokrąglone"
        }
    }
}

enum SliderColorEnum: String, CaseIterable, Identifiable {
    case white = "White"
    case albumArt = "Match album art"
    case accent = "Accent color"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .white: return "Biały"
        case .albumArt: return "Okładka"
        case .accent: return "Akcent"
        }
    }
}

enum DownloadIndicatorStyle: String, CaseIterable, Identifiable {
    case progress = "Progress"
    case percentage = "Percentage"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .progress: return "Postęp"
        case .percentage: return "Procenty"
        }
    }
}

enum DownloadIconStyle: String, CaseIterable, Identifiable {
    case onlyAppIcon = "Only app icon"
    case onlyIcon = "Only download icon"
    case iconAndAppIcon = "Both"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onlyAppIcon: return "Tylko ikona aplikacji"
        case .onlyIcon: return "Tylko ikona pobierania"
        case .iconAndAppIcon: return "Obie ikony"
        }
    }
}

/// Backend used to read and control now playing information.
enum MediaControllerType: String, CaseIterable, Identifiable {
    case nowPlaying = "Now Playing"
    case appleMusic = "Apple Music"
    case spotify = "Spotify"
    case kaset = "Kaset"
    case browser = "Browser"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nowPlaying: return "Teraz odtwarzane"
        case .appleMusic: return "Muzyka"
        case .spotify: return "Spotify"
        case .kaset: return "Kaset"
        case .browser: return "Przeglądarka"
        }
    }

    var appBundleIdentifier: String? {
        switch self {
        case .appleMusic: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        case .kaset: return KasetMediaController.bundleIdentifier
        case .nowPlaying, .browser: return nil
        }
    }
}

/// Presentation used when a new track starts playing.
enum SneakPeekStyle: String, CaseIterable, Identifiable {
    case standard = "Default"
    case inline = "Inline"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Domyślny"
        case .inline: return "W linii"
        }
    }
}

/// When the notch should get out of the way of fullscreen media.
enum HideNotchOption: String, CaseIterable, Identifiable {
    case always = "Always"
    case nowPlayingOnly = "Only while playing media"
    case never = "Never"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .always: return "Zawsze"
        case .nowPlayingOnly: return "Tylko podczas odtwarzania multimediów"
        case .never: return "Nigdy"
        }
    }
}

/// Something the collapsed notch can show beside the camera cutout, either all
/// the time or only while an app is fullscreen.
enum NotchWidget: String, CaseIterable, Identifiable {
    case battery = "Battery"
    case clock = "Clock"
    case date = "Date"
    case focusTimer = "Focus timer"
    case nextEvent = "Next event"
    case nowPlaying = "Now playing"
    case cpu = "CPU"
    case memory = "Memory"
    case disk = "Disk"
    case weather = "Weather"
    case wifi = "Wi-Fi"
    case moonPhase = "Moon phase"
    case shelfCount = "Shelf count"
    case unread = "Unread"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .battery: return "Bateria"
        case .clock: return "Zegar"
        case .date: return "Data"
        case .focusTimer: return "Minutnik skupienia"
        case .nextEvent: return "Następne wydarzenie"
        case .nowPlaying: return "Teraz odtwarzane"
        case .cpu: return "CPU"
        case .memory: return "RAM"
        case .disk: return "Dysk"
        case .weather: return "Pogoda"
        case .wifi: return "Wi-Fi"
        case .moonPhase: return "Faza księżyca"
        case .shelfCount: return "Liczba elementów na Półce"
        case .unread: return "Nieprzeczytane"
        }
    }

    /// First-pass estimate. The real width is measured from the rendered
    /// content, since these vary a lot by locale and by what they are showing.
    var estimatedWidth: CGFloat {
        switch self {
        case .battery, .cpu, .memory, .disk, .weather: return 56
        case .clock, .focusTimer, .moonPhase, .shelfCount, .unread: return 54
        case .date, .wifi: return 82
        case .nextEvent, .nowPlaying: return 132
        }
    }

    var symbol: String {
        switch self {
        case .battery: return "battery.75"
        case .clock: return "clock"
        case .date: return "calendar"
        case .focusTimer: return "cup.and.saucer"
        case .nextEvent: return "calendar.badge.clock"
        case .nowPlaying: return "music.note"
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        case .weather: return "cloud.sun"
        case .wifi: return "wifi"
        case .moonPhase: return "moonphase.waxing.crescent"
        case .shelfCount: return "tray.full"
        case .unread: return "bubble.left.and.bubble.right"
        }
    }

    /// What clicking the widget should do. Nil means "just open the notch".
    var clickTarget: WidgetClickTarget? {
        switch self {
        case .battery: return .settingsPane("com.apple.Battery-Settings.extension")
        case .clock, .date: return .app("com.apple.iCal")
        case .nextEvent: return .nextMeeting
        case .nowPlaying: return .playingApp
        case .focusTimer: return .focusTab
        case .cpu, .memory: return .app("com.apple.ActivityMonitor")
        case .disk: return .app("com.apple.Finder")
        case .weather: return .app("com.apple.weather")
        case .wifi: return .locationAccess
        case .moonPhase: return nil
        case .shelfCount: return .shelfTab
        case .unread: return .unreadApp
        }
    }
}

/// The glyph the menu bar item uses.
enum MenuBarGlyph: String, CaseIterable, Identifiable {
    case notch = "Notch"
    case sparkle = "Sparkle"
    case circle = "Circle"
    case bolt = "Bolt"
    case none = "No icon"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notch: return "Notch"
        case .sparkle: return "Iskra"
        case .circle: return "Koło"
        case .bolt: return "Błyskawica"
        case .none: return "Brak ikony"
        }
    }

    var symbol: String? {
        switch self {
        case .notch: return "rectangle.topthird.inset.filled"
        case .sparkle: return "sparkles"
        case .circle: return "circle.dashed"
        case .bolt: return "bolt.horizontal.fill"
        case .none: return nil
        }
    }
}

/// What the menu bar item writes next to its glyph, if anything.
enum MenuBarReadout: String, CaseIterable, Identifiable {
    case nothing = "Nothing"
    case nowPlaying = "Now playing"
    case battery = "Battery"
    case focusTimer = "Focus countdown"
    case nextEvent = "Next event"
    case shelfCount = "Shelf items"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nothing: return "Nic"
        case .nowPlaying: return "Teraz odtwarzane"
        case .battery: return "Bateria"
        case .focusTimer: return "Odliczanie skupienia"
        case .nextEvent: return "Następne wydarzenie"
        case .shelfCount: return "Elementy na Półce"
        }
    }
}

/// Where the notch's outline takes its colour from.
enum BorderColorSource: String, CaseIterable, Identifiable {
    case white = "White"
    case accent = "Accent colour"
    case albumArt = "Match album art"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .white: return "Biały"
        case .accent: return "Akcent"
        case .albumArt: return "Okładka"
        }
    }
}

/// What the collapsed notch gives the space beside the cutout to while media is
/// playing. Widgets normally step aside for music; this decides whether they
/// have to.
enum ClosedMediaDisplay: String, CaseIterable, Identifiable {
    case mediaOnly = "Only the media"
    case mediaAndWidgets = "Media and widgets"
    case widgetsOnly = "Only widgets"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mediaOnly: return "Tylko multimedia"
        case .mediaAndWidgets: return "Multimedia i widżety"
        case .widgetsOnly: return "Tylko widżety"
        }
    }

    /// Artwork on the left, spectrum on the right.
    var showsMedia: Bool { self != .widgetsOnly }
    var showsWidgets: Bool { self != .mediaOnly }
}

/// Where a widget sends you when you click it.
enum WidgetClickTarget: Equatable {
    case settingsPane(String)
    case app(String)
    case nextMeeting
    case playingApp
    case focusTab
    case shelfTab
    /// The first chat app with something unread.
    case unreadApp
    case locationAccess
}

/// Playback repeat mode reported by the active media controller.
enum RepeatMode: String {
    case off
    case all
    case one

    var title: String {
        switch self {
        case .off: return "Nie powtarzaj"
        case .all: return "Powtarzaj wszystko"
        case .one: return "Powtarzaj utwór"
        }
    }

    // SF Symbols' own `repeat` / `repeat.1` glyphs ignore `foregroundStyle` on
    // macOS 26, so they can never show the "active" tint. `arrow.2.squarepath`
    // tints correctly, and repeat-one adds a small badge instead.
    var symbol: String { "arrow.2.squarepath" }

    /// Shown over the symbol when only the current track repeats.
    var badge: String? {
        self == .one ? "1" : nil
    }
}

/// A module in the strip along the bottom of the home tab. The strip is
/// user-composed the same way the idle widgets are: pick which ones appear and
/// in what order, because what is useful here is entirely personal.
enum HomePanel: String, CaseIterable, Identifiable {
    case quickActions = "Quick actions"
    case systemStats = "System stats"
    case battery = "Battery"
    case devices = "Device batteries"
    case focusStreak = "Focus streak"
    case recentShelf = "Recent files"
    case clipboard = "Last copied"
    case notes = "Note"
    case wifi = "Wi-Fi"
    case openApp = "Open app"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quickActions: return "Szybkie akcje"
        case .systemStats: return "Statystyki systemu"
        case .battery: return "Bateria"
        case .devices: return "Baterie urządzeń"
        case .focusStreak: return "Seria skupienia"
        case .recentShelf: return "Ostatnie pliki"
        case .clipboard: return "Ostatnio skopiowane"
        case .notes: return "Notatka"
        case .wifi: return "Wi-Fi"
        case .openApp: return "Otwórz aplikację"
        }
    }

    /// Whether the strip may hold more than one of these. Everything else says
    /// the same thing twice, but a launcher for a chosen app is only useful in
    /// multiples.
    var allowsDuplicates: Bool { self == .openApp }

    var symbol: String {
        switch self {
        case .quickActions: return "bolt.fill"
        case .systemStats:  return "waveform.path.ecg"
        case .battery:      return "battery.75"
        case .devices:      return "airpods"
        case .focusStreak:  return "flame.fill"
        case .recentShelf:  return "tray.full"
        case .clipboard:    return "doc.on.clipboard"
        case .notes:        return "note.text"
        case .wifi:         return "wifi"
        case .openApp:      return "app.badge"
        }
    }

    /// Roughly how much of the strip this one wants. The strip divides the
    /// width in proportion to these rather than equally, because a row of
    /// action buttons needs far more room than a battery percentage.
    var weight: CGFloat {
        switch self {
        case .quickActions: return 1.5
        case .systemStats:  return 1.4
        case .recentShelf:  return 1.3
        case .clipboard:    return 1.6
        case .notes:        return 1.6
        case .devices:      return 1.2
        case .battery:      return 1.0
        case .focusStreak:  return 1.0
        case .wifi:         return 1.0
        case .openApp:      return 0.6
        }
    }
}

/// One entry in the home strip. Panels need identity and a payload rather than
/// being a bare enum: "Open app" can appear several times, each pointing at a
/// different application, so the case alone no longer says what to draw.
struct HomePanelInstance: Identifiable, Equatable {
    let id: UUID
    var panel: HomePanel
    /// File path of the app to launch, for `.openApp`.
    var appPath: String?

    init(id: UUID = UUID(), panel: HomePanel, appPath: String? = nil) {
        self.id = id
        self.panel = panel
        self.appPath = appPath
    }

    var appName: String? {
        appPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
    }

    /// Stored as a single string so the existing string-array preference keeps
    /// working: older entries are a bare raw value and still decode.
    var encoded: String {
        guard let appPath, panel == .openApp else { return panel.rawValue }
        return "\(panel.rawValue)\u{1F}\(appPath)"
    }

    static func decode(_ raw: String) -> HomePanelInstance? {
        let parts = raw.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
        guard let panel = HomePanel(rawValue: String(parts[0])) else { return nil }
        return HomePanelInstance(
            panel: panel,
            appPath: parts.count > 1 ? String(parts[1]) : nil
        )
    }
}

/// How the panel looks on a display with no physical notch.
///
/// A fake notch flush with the top edge is the right answer on a MacBook,
/// where it lines up with real hardware. On an external monitor there is
/// nothing to line up with, and a black slab welded to the top of the screen
/// just looks like a dead pixel row — so the default there is an island that
/// floats free of the edge.
enum NonNotchStyle: String, CaseIterable, Identifiable {
    case island = "Dynamic Island"
    case notch = "Fake notch"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .island: return "Dynamic Island"
        case .notch: return "Sztuczny notch"
        }
    }
}

