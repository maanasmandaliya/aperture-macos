//
//  OverlayMetrics.swift
//  Aperture
//
//  The slab's dimensions for each presentation, resolved in one place.
//
//  These have to be *known up front* rather than derived from content: the
//  overlay animates by interpolating one persistent surface between states, and
//  a spring can only run against a size it can compute at both ends. Content is
//  therefore laid out to a fixed height per state and clipped by the slab, which
//  also stops text reflowing mid-flight.
//

import SwiftUI

struct OverlayMetrics: Equatable, Sendable {

    var layout: ScreenGeometry.Layout
    var scale: CGFloat

    /// Height reserved at the top for the camera housing. Zero without one.
    var notchBand: CGFloat { layout.hasNotch ? layout.notchRect.height : 0 }

    /// Outer size of the slab for a presentation.
    func slabSize(
        for presentation: OverlayPresentation,
        isHovering: Bool,
        hasActivity: Bool = true
    ) -> CGSize {
        switch presentation {
        case .hidden, .minimal:
            return minimalSize(isHovering: isHovering, hasActivity: hasActivity)
        case .compact:
            return compactSize
        case .hud(let style):
            return hudSize(for: style)
        case .expanded(let tab):
            return hubSize(for: tab)
        }
    }

    /// The resting slab.
    ///
    /// With nothing live, a notched display shows the housing and nothing more:
    /// the wings exist to carry artwork and a glyph, and with neither to show
    /// they are just black edges announcing that something is installed. Idle
    /// therefore collapses to the housing's own rect, which is invisible against
    /// it. Hovering still widens it, so the target can be found.
    ///
    /// A display without a housing keeps its pill — there is nothing to hide
    /// inside, and shrinking to nothing would leave no way back.
    func minimalSize(isHovering: Bool, hasActivity: Bool = true) -> CGSize {
        let resting = restingSize(hasActivity: hasActivity)
        guard isHovering else { return resting }
        // On a notched display the slab *is* the housing, so it may only grow
        // sideways — a taller pill would immediately read as a separate object.
        let heightGrowth = layout.hasNotch ? 0 : Tokens.Size.hoverGrowth.height * scale
        return CGSize(
            width: resting.width + Tokens.Size.hoverGrowth.width * scale,
            height: resting.height + heightGrowth
        )
    }

    private func restingSize(hasActivity: Bool) -> CGSize {
        guard layout.hasNotch, !hasActivity else { return layout.pillSize }
        return layout.notchRect.size
    }

    var hudWidth: CGFloat { max(Tokens.Size.hud.width * scale, layout.pillSize.width) }

    /// Width of a meter HUD: the housing plus a wing either side, wide enough
    /// for the label on one side and the level bar on the other.
    var meterHUDWidth: CGFloat {
        guard layout.hasNotch else {
            return max(Tokens.Size.hudMeterPlain.width * scale, layout.pillSize.width)
        }
        return layout.notchRect.width + Tokens.Size.hudMeterWing * scale * 2
    }

    /// Content width of one wing of a meter HUD.
    var meterWing: CGFloat {
        layout.hasNotch
            ? Tokens.Size.hudMeterWing * scale
            : (meterHUDWidth - Tokens.Space.md * scale * 2) / 2
    }

    /// The peek is the resting slab plus a row for the track name. Same width,
    /// so it drops open rather than spreading sideways.
    var compactSize: CGSize {
        CGSize(
            width: layout.pillSize.width,
            height: layout.pillSize.height + Tokens.Size.peekTitleRow * scale
        )
    }

    /// Height of the name row hanging below the housing.
    var peekTitleRow: CGFloat { Tokens.Size.peekTitleRow * scale }

    func hudSize(for style: HUDStyle) -> CGSize {
        switch style {
        case .meter:
            // Exactly the resting slab's height on a notched display, so the
            // housing appears to widen rather than something dropping out of it.
            return CGSize(
                width: meterHUDWidth,
                height: layout.hasNotch ? layout.pillSize.height : Tokens.Size.hudMeterPlain.height * scale
            )
        case .message:
            return CGSize(width: hudWidth, height: notchBand + Tokens.Size.hud.height * scale)
        }
    }

    /// Hub footprint for a tab. Width is constant so only the height animates
    /// when switching tabs — a slab that changed width too would slosh.
    func hubSize(for tab: HubTab) -> CGSize {
        let height: CGFloat
        switch tab {
        case .nowPlaying: height = Tokens.Size.hub.height
        case .schedule: height = Tokens.Size.hubScheduleHeight
        case .mirror: height = Tokens.Size.hubMirrorHeight
        case .controls: height = Tokens.Size.hubControlsHeight
        }
        return CGSize(width: Tokens.Size.hub.width * scale, height: height * scale)
    }

    /// Tallest hub footprint, for anything that needs to reserve room.
    var maxHubSize: CGSize {
        HubTab.allCases.reduce(CGSize.zero) { largest, tab in
            let size = hubSize(for: tab)
            return CGSize(width: max(largest.width, size.width), height: max(largest.height, size.height))
        }
    }

    /// Bottom-corner radius for a presentation. Interpolated by the spring, so
    /// the silhouette tightens and relaxes as the slab resizes.
    func bottomRadius(for presentation: OverlayPresentation) -> CGFloat {
        switch presentation {
        case .hidden, .minimal: Tokens.Radius.slabMinimal * scale
        // A meter HUD is the resting slab's height, so it wants the resting
        // silhouette too — the compact radius would round a 33 pt slab almost
        // to a capsule.
        case .hud(.meter): Tokens.Radius.slabMinimal * scale
        case .compact, .hud(.message): Tokens.Radius.slabCompact * scale
        case .expanded: Tokens.Radius.slabHub * scale
        }
    }

    func flare(for presentation: OverlayPresentation) -> CGFloat {
        switch presentation {
        case .hidden, .minimal: Tokens.Radius.flareMinimal * scale
        case .hud(.meter): Tokens.Radius.flareMinimal * scale
        case .compact, .hud(.message): Tokens.Radius.flareCompact * scale
        case .expanded: Tokens.Radius.flareHub * scale
        }
    }
}
