//
//  DecorLayout.swift
//  FunNotch
//
//  How the decorations claim room beside the camera cutout. The closed notch
//  sizes itself from `NotchViewModel.closedActivityInsets`; this is the one
//  place that adds the timer mascot's track and the idle animation to it, so
//  the views that draw them and the width they were promised cannot drift.
//

import SwiftUI

extension NotchViewModel {
    /// Width the mascot's track needs beside the focus countdown, or 0 when
    /// no mascot is picked or no session is showing there.
    var decorMascotTrackWidth: CGFloat {
        guard showsFocusActivity, DecorStore.shared.mascot != .none else { return 0 }
        // On top of the countdown's own width: the track and the gap before
        // it, plus a little more margin on the outer edge, where the notch's
        // corner rounds away.
        return DecorMascotTrack.width + DecorMascotTrack.cameraGap + 4
    }

    /// Which wings the idle animation occupies right now, or nil. It only
    /// takes the stage when nothing else has — no music, widgets, focus,
    /// agent light, drop or announcement — so it is judged on the base
    /// insets: they are zero exactly when the row beside the camera is empty.
    var decorIdleWings: (leading: Bool, trailing: Bool)? {
        let store = DecorStore.shared
        guard store.idleIsReady || store.catIdleIsReady, notchState == .closed,
              !isShowingDropZone, !isShowingStandardHUD, !isShowingStandardMusicPeek
        else { return nil }
        let base = baseClosedActivityInsets
        guard base.leading == 0, base.trailing == 0 else { return nil }
        switch store.idleSide {
        case .leading: return (true, false)
        case .trailing: return (false, true)
        case .both: return (true, true)
        }
    }

    func decorAdjustedInsets(
        _ base: (leading: CGFloat, trailing: CGFloat)
    ) -> (leading: CGFloat, trailing: CGFloat) {
        guard !isShowingDropZone else { return base }
        var insets = base
        insets.trailing += decorMascotTrackWidth
        if let wings = decorIdleWings {
            let store = DecorStore.shared
            let width = store.idleIsReady ? store.idleInset : DecorStore.catIdleInset
            if wings.leading { insets.leading = width }
            if wings.trailing { insets.trailing = width }
        }
        return insets
    }
}
