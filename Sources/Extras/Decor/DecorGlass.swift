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
            ZStack(alignment: .top) {
                DecorGlassFill(
                    shape: NotchShape(
                        topCornerRadius: viewModel.topCornerRadius,
                        bottomCornerRadius: viewModel.bottomCornerRadius,
                        isIsland: viewModel.isIsland
                    )
                )
                // The open panel grows out of the hardware notch, which is
                // pure black: fade the glass in below the header row so the
                // two do not meet in a hard grey edge.
                if !viewModel.isIsland {
                    LinearGradient(
                        colors: [.black, .black.opacity(0)],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: viewModel.closedNotchSize.height + 18)
                    .allowsHitTesting(false)
                }
            }
        } else {
            Color.black
        }
    }

    private var wantsGlass: Bool {
        switch viewModel.notchState {
        case .open:
            return store.glassPanel
        case .closed:
            // Banners on a floating island only. Beside the hardware notch the
            // banner grows out of the camera housing, which is black; glass
            // there reads as a grey patch stuck to it.
            return store.glassBanners
                && viewModel.isIsland
                && viewModel.isShowingStandardHUD
                && viewModel.expandingView.type == .island
        }
    }
}

@available(macOS 26.0, *)
private struct DecorGlassFill<S: Shape>: View {
    let shape: S

    var body: some View {
        // Glass alone is only as dark as its tint, and over a light wallpaper
        // a 55 % tint is a mid grey that washes out white text and the
        // dimmer labels. A black base under it keeps the panel dark whatever
        // is behind; the glass still adds the blur and the sheen.
        ZStack {
            shape.fill(Color.black.opacity(0.5))
            Color.clear
                .glassEffect(.regular.tint(.black.opacity(0.6)), in: shape)
        }
    }
}
