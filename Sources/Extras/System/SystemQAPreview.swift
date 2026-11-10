//
//  SystemQAPreview.swift
//  FunNotch
//
//  Preview jobs for the system extras, picked up by
//  `PreviewRenderer.renderExtras` (`--render-preview <dir>`). They exist so the
//  widgets and the Home quick-action row can be inspected without opening the
//  real panel.
//

import AppKit
import SwiftUI

extension PreviewRenderer {
    static func appendSystemJobs(to jobs: inout [(name: String, size: CGSize, dark: Bool, make: () -> AnyView)]) {
        // The closed-notch widgets and the Home quick-action row.
        jobs.append(("qa-system-widgets", CGSize(width: 520, height: 260), true, {
            SystemExtras.start()
            return AnyView(
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        KeepAwakeWidget()
                        MicMuteWidget()
                        PrivacyWidget()
                        AudioOutputWidget()
                    }
                    // The quick-action chips at the Home tile's real size:
                    // at rest, one widened by the pointer, and one with an
                    // options chevron and an active tint.
                    ForEach(["", "shot", "awake"], id: \.self) { hover in
                        QuickActionStrip(items: Self.sampleChips, previewHover: hover.isEmpty ? nil : hover)
                            .frame(width: 192, height: 42)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.black)
            )
        }))
    }

    /// The Home quick actions with fixed state, so the snapshot does not
    /// depend on what the Mac is doing.
    static var sampleChips: [QuickActionItem] {
        let menu = [PointerMenu.Item(title: "1 godzina") {}]
        return [
            QuickActionItem(id: "focus", symbol: "cup.and.saucer.fill", label: "Skupienie", help: "", menu: menu) {},
            QuickActionItem(id: "note", symbol: "note.text", label: "Notatka", help: "") {},
            QuickActionItem(id: "shot", symbol: "camera.viewfinder", label: "Zrzut ekranu", help: "") {},
            QuickActionItem(id: "timer", symbol: "timer", label: "Minutnik", help: "") {},
            QuickActionItem(
                id: "awake", symbol: KeepAwakeManager.activeSymbol, label: "Nie usypia, 45 min",
                activeTint: .yellow, help: "", menu: menu
            ) {},
            QuickActionItem(id: "mic", symbol: "mic.fill", label: "Wycisz mikrofon", help: "") {},
            QuickActionItem(id: "output", symbol: "laptopcomputer", label: "Głośniki MacBooka Air", help: "", menu: menu) {},
        ]
    }
}
