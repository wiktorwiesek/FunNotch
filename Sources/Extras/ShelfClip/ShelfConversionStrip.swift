//
//  ShelfConversionStrip.swift
//  FunNotch
//
//  Progress, result and errors of shelf conversions, shown in a thin strip
//  above the items. The notch is open while the shelf is visible, so the
//  island alone would never be seen.
//

import SwiftUI

struct ShelfConversionStrip: View {
    @ObservedObject private var converter = ShelfConverter.shared

    var body: some View {
        if !converter.jobs.isEmpty {
            VStack(spacing: 2) {
                ForEach(converter.jobs.suffix(3)) { job in
                    ShelfConversionRow(job: job)
                }
            }
            .padding(.horizontal, 2)
            .transition(.opacity)
        }
    }
}

private struct ShelfConversionRow: View {
    let job: ShelfConversionJob

    @ObservedObject private var converter = ShelfConverter.shared

    var body: some View {
        HStack(spacing: 6) {
            icon
                .frame(width: 12, height: 12)

            Text(job.title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)

            switch job.state {
            case .running:
                if let progress = job.progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                        .frame(width: 80)
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.system(size: 9, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.5))
                }
            case let .done(name):
                Text(name)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
            case let .failed(message):
                Text(message)
                    .font(.system(size: 9))
                    .foregroundStyle(.orange.opacity(0.9))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button {
                if job.state == .running {
                    converter.cancel(job.id)
                } else {
                    converter.dismiss(job.id)
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(NotchPressStyle())
            .help(job.state == .running ? "Anuluj" : "Zamknij")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .notchGlass(in: Capsule(), subtle: true)
    }

    @ViewBuilder
    private var icon: some View {
        switch job.state {
        case .running:
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.6)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(SettingsStyle.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(SettingsStyle.orange)
        }
    }
}
