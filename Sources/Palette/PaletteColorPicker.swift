//
//  PaletteColorPicker.swift
//  FunNotch
//
//  The system eyedropper. Picking a colour copies its HEX code and announces
//  it in the notch tinted with the colour itself.
//
//  The name shadows SwiftUI's ColorPicker inside this module on purpose, so
//  other features can call `ColorPicker.pick()`; nothing here uses the SwiftUI one.
//

import AppKit
import SwiftUI

@MainActor
enum ColorPicker {
    /// NSColorSampler stops sampling when it is deallocated, so it is kept here.
    private static var sampler: NSColorSampler?

    /// Starts the eyedropper. `completion` gets the HEX string ("#RRGGBB") of
    /// the picked colour, or nil when the user cancelled with Esc.
    static func pick(completion: ((String?) -> Void)? = nil) {
        guard sampler == nil else { return }
        let sampler = NSColorSampler()
        self.sampler = sampler
        sampler.show { color in
            MainActor.assumeIsolated {
                Self.sampler = nil
                guard let color, let hex = hex(of: color) else {
                    completion?(nil)
                    return
                }
                PaletteClipboard.copy(hex)
                IslandCenter.shared.post(Island(
                    symbol: "eyedropper.halffull",
                    tint: Color(nsColor: color),
                    title: "Kolor",
                    detail: " · skopiowano",
                    trailing: hex
                ))
                completion?(hex)
            }
        }
    }

    /// "#RRGGBB" in sRGB, which is what CSS and design tools expect.
    static func hex(of color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        func channel(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channel(rgb.redComponent), channel(rgb.greenComponent), channel(rgb.blueComponent))
    }
}
