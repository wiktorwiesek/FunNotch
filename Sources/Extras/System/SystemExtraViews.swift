//
//  SystemExtraViews.swift
//  FunNotch
//
//  The closed-notch widgets and Home quick-action buttons of the system
//  extras. `NotchWidgets.swift` places the widgets; `HomeStripView.swift`
//  places `SystemQuickActionButtons` inside its quick-action row.
//

import AppKit
import SwiftUI

private let widgetRed = Color(red: 1, green: 0.35, blue: 0.32)

// MARK: - Keep awake

/// The duration choices shared by the widget's and the button's context menu.
private struct KeepAwakeMenu: View {
    @ObservedObject var keepAwake: KeepAwakeManager

    var body: some View {
        ForEach(KeepAwakeManager.durationChoices, id: \.title) { choice in
            Button(choice.title) { keepAwake.activate(minutes: choice.minutes) }
        }
        if keepAwake.isActive {
            Divider()
            Button("Wyłącz") { keepAwake.deactivate() }
        }
    }
}

struct KeepAwakeWidget: View {
    @ObservedObject private var keepAwake = KeepAwakeManager.shared

    var body: some View {
        Group {
            if keepAwake.isActive {
                // The remaining time is the point of the widget, so it has a clock.
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    content(text: keepAwake.remainingText(at: context.date))
                }
            } else {
                content(text: nil)
            }
        }
        .fixedSize()
        .onAppear { KeepAwakeManager.shared.start() }
        .help(keepAwake.helpText())
        .contextMenu { KeepAwakeMenu(keepAwake: keepAwake) }
    }

    private func content(text: String?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: keepAwake.isActive ? KeepAwakeManager.activeSymbol : KeepAwakeManager.symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(keepAwake.isActive ? Color.orange : .white.opacity(0.4))
            if let text {
                Text(text)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }
}

// MARK: - Microphone

struct MicMuteWidget: View {
    @ObservedObject private var mic = MicMuteManager.shared

    var body: some View {
        Image(systemName: mic.isMuted ? "mic.slash.fill" : "mic.fill")
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(mic.isMuted ? widgetRed : .white.opacity(mic.isSupported ? 0.6 : 0.3))
            .fixedSize()
            .onAppear { MicMuteManager.shared.start() }
            .help(mic.helpText)
    }
}

// MARK: - Privacy

/// A green dot while the camera is on and an orange one while the microphone
/// is, like the menu bar's. When neither is, a quiet shield says it is watching.
struct PrivacyWidget: View {
    @ObservedObject private var privacy = PrivacyIndicatorManager.shared

    var body: some View {
        HStack(spacing: 5) {
            if !privacy.cameraActive && !privacy.microphoneActive {
                Image(systemName: "lock.shield")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            }
            if privacy.cameraActive { dot(.green) }
            if privacy.microphoneActive { dot(.orange) }
        }
        .fixedSize()
        .onAppear { PrivacyIndicatorManager.shared.start() }
        .help(privacy.helpText)
    }

    private func dot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .shadow(color: color.opacity(0.7), radius: 2)
    }
}

// MARK: - Audio output

struct AudioOutputWidget: View {
    @ObservedObject private var output = AudioOutputManager.shared

    var body: some View {
        Image(systemName: output.current?.symbol ?? "speaker.slash")
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.white.opacity(output.current == nil ? 0.4 : 0.85))
            .fixedSize()
            .onAppear { AudioOutputManager.shared.start() }
            .help(output.helpText)
    }
}

// MARK: - Quick actions

/// The extra buttons of the Home "Szybkie akcje" tile, each one switchable in
/// settings so the row does not get crowded.
struct SystemQuickActionButtons: View {
    @AppStorage("extras.system.quickActions.keepAwake") private var showKeepAwake = true
    @AppStorage("extras.system.quickActions.mic") private var showMic = true
    @AppStorage("extras.system.quickActions.output") private var showOutput = true

    @ObservedObject private var keepAwake = KeepAwakeManager.shared
    @ObservedObject private var mic = MicMuteManager.shared
    @ObservedObject private var output = AudioOutputManager.shared

    var body: some View {
        Group {
            if showKeepAwake {
                button(
                    keepAwake.isActive ? KeepAwakeManager.activeSymbol : KeepAwakeManager.symbol,
                    keepAwake.isActive ? "Nie usypiaj: włączone — kliknij, aby wyłączyć" : "Nie usypiaj Maca",
                    tint: keepAwake.isActive ? .orange : nil
                ) { keepAwake.toggle() }
                .contextMenu { KeepAwakeMenu(keepAwake: keepAwake) }
            }
            if showMic {
                button(
                    mic.isMuted ? "mic.slash.fill" : "mic.fill",
                    mic.isMuted ? "Mikrofon wyciszony — kliknij, aby włączyć" : "Wycisz mikrofon",
                    tint: mic.isMuted ? widgetRed : nil
                ) { mic.toggle() }
            }
            if showOutput {
                button(output.current?.symbol ?? "speaker.wave.2", output.helpText, tint: nil) {
                    output.showMenu()
                }
            }
        }
        .onAppear { SystemExtras.start() }
    }

    private func button(_ symbol: String, _ help: String, tint: Color?, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint ?? .white.opacity(0.8))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.white.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
