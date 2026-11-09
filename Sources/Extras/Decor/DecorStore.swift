//
//  DecorStore.swift
//  FunNotch
//
//  Preferences for the decorations: alternative HUD styles, timer mascots, a
//  custom idle animation and Liquid Glass. Everything defaults to "off" so the
//  notch looks exactly as it did before until the user opts in.
//
//  Values live in UserDefaults under `extras.decor.*`; views observe this
//  store so a change in settings shows up in the notch at once.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Choices

enum DecorHUDStyle: String, CaseIterable, Identifiable {
    case notch
    case edgeBar
    case ring

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notch: return "W notchu"
        case .edgeBar: return "Pasek przy krawędzi"
        case .ring: return "Okrągły wskaźnik"
        }
    }
}

enum DecorMascot: String, CaseIterable, Identifiable {
    case none
    case cat
    case dog
    case snail
    case rocket

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Brak"
        case .cat: return "Kot"
        case .dog: return "Piesek"
        case .snail: return "Ślimak"
        case .rocket: return "Rakieta"
        }
    }
}

enum DecorIdleSide: String, CaseIterable, Identifiable {
    case leading
    case trailing
    case both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leading: return "Po lewej"
        case .trailing: return "Po prawej"
        case .both: return "Po obu stronach"
        }
    }
}

// MARK: - Store

@MainActor
final class DecorStore: ObservableObject {
    static let shared = DecorStore()

    private enum Key {
        static let hudStyle = "extras.decor.hudStyle"
        static let hudScale = "extras.decor.hudScale"
        static let mascot = "extras.decor.mascot"
        static let idleEnabled = "extras.decor.idleEnabled"
        static let idleFile = "extras.decor.idleFile"
        static let idleName = "extras.decor.idleName"
        static let idleSpeed = "extras.decor.idleSpeed"
        static let idleScale = "extras.decor.idleScale"
        static let idleOffsetY = "extras.decor.idleOffsetY"
        static let idleSide = "extras.decor.idleSide"
        static let glassPanel = "extras.decor.glassPanel"
        static let glassBanners = "extras.decor.glassBanners"
    }

    private let defaults = UserDefaults.standard

    // HUD

    @Published var hudStyle: DecorHUDStyle {
        didSet { defaults.set(hudStyle.rawValue, forKey: Key.hudStyle) }
    }

    /// 1 is the designed size; the edge bar and the ring both scale from it.
    @Published var hudScale: Double {
        didSet { defaults.set(hudScale, forKey: Key.hudScale) }
    }

    // Mascots

    @Published var mascot: DecorMascot {
        didSet { defaults.set(mascot.rawValue, forKey: Key.mascot) }
    }

    // Idle animation

    @Published var idleEnabled: Bool {
        didSet {
            defaults.set(idleEnabled, forKey: Key.idleEnabled)
            if idleEnabled { loadIdleAnimationIfNeeded() }
        }
    }

    @Published var idleSpeed: Double {
        didSet { defaults.set(idleSpeed, forKey: Key.idleSpeed) }
    }

    @Published var idleScale: Double {
        didSet { defaults.set(idleScale, forKey: Key.idleScale) }
    }

    /// Points; positive moves the picture down.
    @Published var idleOffsetY: Double {
        didSet { defaults.set(idleOffsetY, forKey: Key.idleOffsetY) }
    }

    @Published var idleSide: DecorIdleSide {
        didSet { defaults.set(idleSide.rawValue, forKey: Key.idleSide) }
    }

    /// The decoded picture, once it has loaded.
    @Published private(set) var idleAnimation: DecorAnimation?
    @Published private(set) var idleName: String?
    @Published private(set) var idleError: String?
    @Published private(set) var idleIsLoading = false

    // Liquid Glass

    @Published var glassPanel: Bool {
        didSet { defaults.set(glassPanel, forKey: Key.glassPanel) }
    }

    @Published var glassBanners: Bool {
        didSet { defaults.set(glassBanners, forKey: Key.glassBanners) }
    }

    private var loadGeneration = 0

    private init() {
        let defaults = UserDefaults.standard
        hudStyle = defaults.string(forKey: Key.hudStyle).flatMap(DecorHUDStyle.init(rawValue:)) ?? .notch
        hudScale = Self.number(Key.hudScale, default: 1, in: 0.6 ... 2)
        mascot = defaults.string(forKey: Key.mascot).flatMap(DecorMascot.init(rawValue:)) ?? .none
        idleEnabled = defaults.bool(forKey: Key.idleEnabled)
        idleSpeed = Self.number(Key.idleSpeed, default: 1, in: 0.25 ... 3)
        idleScale = Self.number(Key.idleScale, default: 1, in: 0.5 ... 1.6)
        idleOffsetY = Self.number(Key.idleOffsetY, default: 0, in: -8 ... 8)
        idleSide = defaults.string(forKey: Key.idleSide).flatMap(DecorIdleSide.init(rawValue:)) ?? .leading
        glassPanel = defaults.bool(forKey: Key.glassPanel)
        glassBanners = defaults.bool(forKey: Key.glassBanners)
        idleName = defaults.string(forKey: Key.idleName)
    }

    /// A stored number, or `default` when nothing sensible is there. `object`
    /// rather than `double`, which cannot tell "0" from "never set".
    private static func number(_ key: String, default value: Double, in range: ClosedRange<Double>) -> Double {
        guard let stored = UserDefaults.standard.object(forKey: key) as? Double else { return value }
        return min(max(stored, range.lowerBound), range.upperBound)
    }

    // MARK: - Idle picture

    /// Where the chosen picture is kept. Copied into the app's own folder so
    /// the notch keeps working after the original is moved or deleted.
    private static var folder: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("FunNotch", isDirectory: true)
            .appendingPathComponent("Decor", isDirectory: true)
    }

    var hasIdleFile: Bool { defaults.string(forKey: Key.idleFile) != nil }

    /// Decodes the saved picture in the background, once.
    func loadIdleAnimationIfNeeded() {
        guard idleAnimation == nil, !idleIsLoading,
              let file = defaults.string(forKey: Key.idleFile)
        else { return }
        let url = Self.folder.appendingPathComponent(file)
        decode(url, copyFrom: nil, displayName: idleName)
    }

    /// Copies `source` into the app folder and shows it.
    func chooseIdleFile(_ source: URL) {
        decode(nil, copyFrom: source, displayName: source.lastPathComponent)
    }

    func removeIdleFile() {
        loadGeneration += 1
        if let file = defaults.string(forKey: Key.idleFile) {
            try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(file))
        }
        defaults.removeObject(forKey: Key.idleFile)
        defaults.removeObject(forKey: Key.idleName)
        idleAnimation = nil
        idleName = nil
        idleError = nil
        idleIsLoading = false
    }

    private func decode(_ stored: URL?, copyFrom source: URL?, displayName: String?) {
        loadGeneration += 1
        let generation = loadGeneration
        idleIsLoading = true
        idleError = nil

        let folder = Self.folder
        Task.detached(priority: .userInitiated) {
            var result: DecorAnimation?
            var failure: String?
            var storedName: String?

            if let source {
                // Decode the original first, so a file that is not an
                // animation never replaces one that works.
                if let animation = DecorAnimation.load(from: source) {
                    do {
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        let ext = source.pathExtension.lowercased()
                        let name = "idle-\(UUID().uuidString.prefix(8)).\(ext.isEmpty ? "gif" : ext)"
                        try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(name))
                        storedName = name
                        result = animation
                    } catch {
                        failure = "Nie udało się zapisać pliku: \(error.localizedDescription)"
                    }
                } else {
                    failure = "Nie można odczytać tego pliku. Wybierz animowany GIF albo APNG."
                }
            } else if let stored {
                result = DecorAnimation.load(from: stored)
                if result == nil { failure = "Zapisany plik animacji nie daje się odczytać." }
            }

            await MainActor.run {
                let store = DecorStore.shared
                guard store.loadGeneration == generation else { return }
                store.idleIsLoading = false
                if let failure {
                    store.idleError = failure
                    DiagnosticLog.write("decor", "idle animation failed: \(failure)")
                    return
                }
                guard let result else { return }
                if let storedName {
                    // Drop the previous copy only now that the new one is in.
                    if let old = store.defaults.string(forKey: Key.idleFile), old != storedName {
                        try? FileManager.default.removeItem(at: folder.appendingPathComponent(old))
                    }
                    store.defaults.set(storedName, forKey: Key.idleFile)
                    store.defaults.set(displayName, forKey: Key.idleName)
                }
                store.idleName = displayName
                store.idleAnimation = result
                store.idleEnabled = true
            }
        }
    }

    // MARK: - Idle geometry

    /// Row height the picture is sized against at scale 1.
    static let idleBaseHeight: CGFloat = 20
    /// The widest the picture may get, so a panorama cannot shove the camera
    /// cutout across the screen.
    static let idleMaxWidth: CGFloat = 96
    /// Room kept clear on each side of the picture.
    static let idlePadding: CGFloat = 10

    /// Drawn size of the picture at the current scale.
    var idleSize: CGSize {
        guard let animation = idleAnimation else { return .zero }
        let aspect = max(animation.aspect, 0.1)
        var height = Self.idleBaseHeight * CGFloat(idleScale)
        height = min(height, Self.idleMaxWidth / aspect)
        return CGSize(width: height * aspect, height: height)
    }

    /// Width each wing gets while the idle picture is showing.
    var idleInset: CGFloat {
        idleSize.width + Self.idlePadding * 2
    }

    /// True when there is something to draw.
    var idleIsReady: Bool { idleEnabled && idleAnimation != nil }

    // MARK: - Glass

    /// True on a macOS that has `glassEffect`.
    static var glassIsAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
}

// MARK: - Startup

/// Called once from `FunNotchApp`.
@MainActor
enum DecorExtras {
    static func start() {
        let store = DecorStore.shared
        if store.idleEnabled { store.loadIdleAnimationIfNeeded() }
    }
}
