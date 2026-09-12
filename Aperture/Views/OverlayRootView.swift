//
//  OverlayRootView.swift
//  Aperture
//
//  The view hosted by every overlay panel. It owns the visual state machine's
//  presentation layer: one anchored container whose contents morph between
//  idle, compact, HUD and hub.
//

import SwiftUI

struct OverlayRootView: View {

    @Environment(AppEnvironment.self) private var environment

    let geometry: ScreenGeometry

    @State private var isHovering = false

    private var preferences: Preferences { environment.preferences }
    private var presentation: OverlayPresentation { environment.overlay.presentation(for: geometry.id) }
    /// Hidden because an app is full screen, rather than because there is
    /// nothing to show. The overlay is still reachable in that state.
    private var isSuppressed: Bool { environment.overlay.isSuppressed(geometry.id) }
    private var scale: CGFloat { preferences.resolvedScale }
    private var layout: ScreenGeometry.Layout { geometry.layout(scale: scale) }
    private var accent: AccentChoice { preferences.accent }

    private var expandAnimation: Animation {
        Tokens.Motion.spring(
            intensity: preferences.resolvedAnimationIntensity,
            reduceMotion: preferences.reduceMotion
        )
    }

    private var collapseAnimation: Animation {
        Tokens.Motion.collapse(
            intensity: preferences.resolvedAnimationIntensity,
            reduceMotion: preferences.reduceMotion
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Nothing is built while hidden — with one exception. Suppressed in
            // a full-screen app the overlay is invisible but still *reachable*,
            // and a swipe there takes it straight to the hub. Destroying the
            // tree left the spring with no size to grow from, so the hub
            // appeared fully formed instead of emerging from the housing. It is
            // kept alive at its resting size for that case only; paused, or with
            // no eligible screen, nothing can reach it and nothing is built.
            if presentation != .hidden || isSuppressed {
                // Click-away target: only present while expanded, so the
                // collapsed overlay never intercepts anything outside the pill.
                if presentation.isExpanded {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { environment.overlay.collapse() }
                        .accessibilityHidden(true)
                }

                slab
                    // Invisible while suppressed, but present, so the slab has a
                    // size the spring can start from.
                    .opacity(presentation == .hidden ? 0 : 1)
                    .allowsHitTesting(presentation != .hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    /// One surface for every state.
    ///
    /// The overlay morphs rather than swapping views: a single ``OverlaySurface``
    /// persists across presentations and only its *size* and silhouette change,
    /// so the spring runs on the shape itself. Replacing one slab with another —
    /// which is what a `switch` over the presentation would do — cross-fades two
    /// unrelated views and reads as a pop no matter how the spring is tuned.
    private var slab: some View {
        OverlaySurface(
            bottomRadius: metrics.bottomRadius(for: presentation),
            flare: metrics.flare(for: presentation),
            isElevated: presentation.isExpanded,
            increaseContrast: preferences.increaseContrast
        ) {
            ZStack(alignment: .top) {
                layer(restingContent, visible: showsResting)
                layer(hudContent, visible: presentation.isHUD)
                layer(hubContent, visible: presentation.isExpanded)
            }
            // Each layer keeps its own natural size and is clipped by the slab,
            // so nothing reflows while the slab is in motion — the growing
            // silhouette reveals the hub instead of squeezing it into place.
            .frame(width: slabSize.width, height: slabSize.height, alignment: .top)
        }
        .frame(width: slabSize.width, height: slabSize.height)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { handleTap() }
        .animation(slabAnimation, value: presentation)
        .animation(slabAnimation, value: slabSize)
    }

    /// Layers cross-fade on their own short curve rather than riding the spring;
    /// a bouncing opacity looks like a flicker.
    private func layer<Layer: View>(_ content: Layer, visible: Bool) -> some View {
        content
            .fixedSize()
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .animation(contentAnimation(visible: visible), value: presentation)
    }

    private var showsResting: Bool {
        presentation == .minimal || presentation == .compact
    }

    private var slabSize: CGSize {
        metrics.slabSize(
            for: presentation,
            isHovering: isHovering && preferences.hoverExpansion,
            hasActivity: environment.currentActivity != nil
        )
    }

    private var metrics: OverlayMetrics {
        OverlayMetrics(layout: layout, scale: scale)
    }

    private var slabAnimation: Animation {
        presentation.isExpanded ? expandAnimation : collapseAnimation
    }

    private func contentAnimation(visible: Bool) -> Animation {
        visible
            ? Tokens.Motion.contentIn(reduceMotion: preferences.reduceMotion)
            : Tokens.Motion.contentOut(reduceMotion: preferences.reduceMotion)
    }

    private func handleTap() {
        if presentation.isHUD {
            environment.hud.dismiss()
        } else {
            environment.toggleHub()
        }
    }

    // MARK: - Layers

    @ViewBuilder
    private var restingContent: some View {
        if let activity = environment.currentActivity, presentation == .compact {
            CompactActivityView(
                activity: activity,
                layout: layout,
                accent: accent,
                artwork: environment.media.artwork,
                now: environment.now,
                reduceMotion: preferences.reduceMotion,
                increaseContrast: preferences.increaseContrast,
                scale: scale
            )
        } else {
            MinimalPillView(
                layout: layout,
                accent: accent,
                activity: environment.currentActivity,
                artwork: environment.media.artwork,
                isHovering: isHovering && preferences.hoverExpansion,
                isVisible: presentation != .hidden,
                reduceMotion: preferences.reduceMotion,
                increaseContrast: preferences.increaseContrast,
                scale: scale
            )
        }
    }

    @ViewBuilder
    private var hudContent: some View {
        if let event = environment.hud.current {
            HUDView(
                event: event,
                layout: layout,
                accent: accent,
                increaseContrast: preferences.increaseContrast,
                scale: scale
            )
        } else {
            let size = metrics.hudSize(for: .message)
            Color.clear.frame(width: size.width, height: size.height)
        }
    }

    private var hubContent: some View {
        ExpandedHubView(
            layout: layout,
            scale: scale,
            onClose: { environment.overlay.collapse() }
        )
    }
}

// MARK: - Previews

#Preview("Overlay — idle, notched") {
    OverlayRootPreview(geometry: PreviewData.notchedScreen, presentation: .minimal)
}

#Preview("Overlay — compact media, non-notched") {
    OverlayRootPreview(
        geometry: PreviewData.plainScreen,
        presentation: .compact,
        activity: .media(PreviewData.playingMedia)
    )
}

#Preview("Overlay — expanded hub") {
    OverlayRootPreview(
        geometry: PreviewData.notchedScreen,
        presentation: .expanded(.nowPlaying),
        activity: .media(PreviewData.playingMedia),
        canvasHeight: 500
    )
}

/// Drives ``OverlayRootView`` into a specific state for the canvas.
private struct OverlayRootPreview: View {
    var geometry: ScreenGeometry
    var presentation: OverlayPresentation
    var activity: Activity?
    var canvasHeight: CGFloat = 400

    @State private var environment = AppEnvironment.preview()

    var body: some View {
        OverlayPreviewStage(geometry: geometry, canvasHeight: canvasHeight) { _ in
            OverlayRootView(geometry: geometry)
                .environment(environment)
        }
        .task {
            environment.previewOverride(activity: activity)
            switch presentation {
            case .expanded(let tab): environment.overlay.expand(tab: tab)
            default: break
            }
        }
    }
}
