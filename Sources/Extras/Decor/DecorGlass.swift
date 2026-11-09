//
//  DecorGlass.swift
//  FunNotch
//
//  An optional Liquid Glass look for the open notch and for island banners.
//  Only macOS 26 and later have `glassEffect`; on older systems the toggles
//  are disabled in settings and the notch stays solid black.
//

import SwiftUI

/// What the notch silhouette is filled with: black, or on request glass.
struct DecorBackdrop: View {
    @EnvironmentObject private var viewModel: NotchViewModel
    @ObservedObject private var store = DecorStore.shared

    var body: some View {
        if wantsGlass, #available(macOS 26.0, *) {
            DecorGlassFill(
                shape: NotchShape(
                    topCornerRadius: viewModel.topCornerRadius,
                    bottomCornerRadius: viewModel.bottomCornerRadius,
                    isIsland: viewModel.isIsland
                )
            )
        } else {
            Color.black
        }
    }

    private var wantsGlass: Bool {
        switch viewModel.notchState {
        case .open:
            return store.glassPanel
        case .closed:
            // Banners only: the idle pill hugs the hardware notch, and glass
            // beside a black camera housing would look like a mistake.
            return store.glassBanners
                && viewModel.isShowingStandardHUD
                && viewModel.expandingView.type == .island
        }
    }
}

@available(macOS 26.0, *)
private struct DecorGlassFill<S: Shape>: View {
    let shape: S

    var body: some View {
        // A dark tint keeps the white text and glyphs legible over bright
        // wallpapers; the glass shows through as a soft sheen and blur.
        Color.clear
            .glassEffect(.regular.tint(.black.opacity(0.55)), in: shape)
    }
}
