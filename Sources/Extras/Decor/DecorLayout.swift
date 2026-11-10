//
//  DecorLayout.swift
//  FunNotch
//
//  How the decorations claim room beside the camera cutout. The closed notch
//  sizes itself from `NotchViewModel.closedActivityInsets`; this is the one
//  place that adds the timer mascot's track, the idle animation and the cat
//  that lives there to it, so the views that draw them and the width they
//  were promised cannot drift.
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
        guard store.idleIsReady, notchState == .closed,
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

    /// The cat lives left of the cutout whenever the row has no cat of its
    /// own. Rows that do: the music (the cat is the spectrum), a focus
    /// countdown whose mascot is the cat, and a working agent with nothing
    /// else beside the camera (the cat at its laptop has the left wing).
    var showsResidentCat: Bool {
        let store = DecorStore.shared
        guard store.catResidentIsReady, notchState == .closed,
              !isShowingDropZone, !isShowingStandardHUD, !isShowingStandardMusicPeek
        else { return false }
        if showsFocusActivity { return store.mascot != .cat }
        if showsClosedMediaActivity { return false }
        return isShowingWidgets || !showsAgentActivity
    }

    /// Room the cat takes at the inner edge of the left wing, with the count
    /// of busy sessions beside it when it stands in for the agent light.
    var residentCatWidth: CGFloat {
        guard showsResidentCat else { return 0 }
        let counts = agentPresentation == .cat && agentActivity.active > 1
        return ResidentCat.width + (counts ? Self.agentPipWidthWithCount - Self.agentPipWidth : 0)
    }

    func decorAdjustedInsets(
        _ base: (leading: CGFloat, trailing: CGFloat)
    ) -> (leading: CGFloat, trailing: CGFloat) {
        guard !isShowingDropZone else { return base }
        var insets = base
        insets.trailing += decorMascotTrackWidth
        if let wings = decorIdleWings {
            let width = DecorStore.shared.idleInset
            if wings.leading { insets.leading = width }
            if wings.trailing { insets.trailing = width }
        }
        insets.leading += residentCatWidth
        return insets
    }
}
