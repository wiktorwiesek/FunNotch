//
//  SystemExtraViews.swift
//  FunNotch
//
//  The closed-notch widgets of the system extras, placed by
//  `NotchWidgets.swift`. Their Home quick actions live in the chip strip of
//  `HomeStripView.swift`.
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

/// A green dot while the camera is on, an orange one while the microphone is
/// and a purple one while the screen is being recorded, like the menu bar's.
/// When none is, a quiet shield says it is watching.
struct PrivacyWidget: View {
    @ObservedObject private var privacy = PrivacyIndicatorManager.shared

    var body: some View {
        HStack(spacing: 5) {
            if !privacy.cameraActive && !privacy.microphoneActive && !privacy.screenActive {
                Image(systemName: "lock.shield")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            }
            if privacy.cameraActive { dot(.green) }
            if privacy.microphoneActive { dot(.orange) }
            if privacy.screenActive { dot(.purple) }
        }
        .fixedSize()
        .onAppear { PrivacyIndicatorManager.shared.start() }
        .help(privacy.helpText)
    }

    private func dot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
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

