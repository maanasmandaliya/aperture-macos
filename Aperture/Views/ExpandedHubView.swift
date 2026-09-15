//
//  ExpandedHubView.swift
//  Aperture
//

import SwiftUI

/// The expanded panel. Anchored to the same top-centre point as the pill so the
/// spring reads as one object growing rather than two views cross-fading.
struct ExpandedHubView: View {

    @Environment(AppEnvironment.self) private var environment

    var layout: ScreenGeometry.Layout
    var scale: CGFloat
    var onClose: () -> Void


    /// Derived, never stored. The pane is also changed by the swipe gesture, so
    /// a local `@State` copy would only be synced when the view first appears —
    /// the slab would resize to the new pane while the content stayed put.
    private var selectedTab: HubTab { environment.overlay.presentation.tab ?? .nowPlaying }

    private var accent: AccentChoice { environment.preferences.accent }
    private var reduceMotion: Bool { environment.preferences.reduceMotion }
    private var increaseContrast: Bool { environment.preferences.increaseContrast }

    private var animation: Animation {
        Tokens.Motion.spring(
            intensity: environment.preferences.resolvedAnimationIntensity,
            reduceMotion: reduceMotion
        )
    }

    /// Interior only; the slab is owned by ``OverlayRootView``.
    var body: some View {
        VStack(spacing: Tokens.Space.sm) {
            // Reserve the housing band. Without a housing the same strip still
            // has to exist, because the close button lives in it.
            Color.clear.frame(height: topReserve)

            Group {
                switch selectedTab {
                case .nowPlaying: NowPlayingPane(accent: accent, scale: scale)
                case .schedule: SchedulePane(accent: accent)
                case .mirror: MirrorPane(accent: accent)
                case .controls: ControlsPane(accent: accent, onClose: onClose)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .transition(
                reduceMotion
                    ? .opacity
                    : .asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 8)),
                        removal: .opacity
                    )
            )
        }
        .padding(.leading, Tokens.Space.lg * scale)
        .padding(.trailing, Tokens.Space.lg * scale)
        .padding(.top, Tokens.Space.sm * scale)
        .padding(.bottom, Tokens.Space.md * scale)
        .frame(width: hubSize.width, height: hubSize.height)
        // No visible page indicator and no visible close control: the hub is
        // paged by a two-finger swipe and collapses on a swipe up from the first
        // pane, a click on the slab, a click outside it, Escape, or the
        // shortcut. VoiceOver can discover none of those, so each one is offered
        // as an explicit action instead of a control taking up space.
        .accessibilityActions {
            ForEach(HubTab.allCases) { tab in
                Button(tab.title) { environment.overlay.selectTab(tab) }
            }
        }
        .accessibilityAction(named: "Collapse hub", onClose)
        .animation(animation, value: selectedTab)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Aperture hub")
        .accessibilityAddTraits(.isModal)
    }

    private var hubSize: CGSize {
        OverlayMetrics(layout: layout, scale: scale).hubSize(for: selectedTab)
    }

    /// Height kept clear at the top for the camera housing. Without one, a
    /// small inset still keeps content off the very edge of the bezel.
    /// Vertical strip kept clear at the top of the hub.
    ///
    /// The full housing height, not a point less. Trimming it — which this used
    /// to do — left the track title starting 3.5 pt below the housing's bottom
    /// edge, close enough to read as touching it. Without a housing the same
    /// strip still has to exist, because the close button lives in it.
    private var topReserve: CGFloat {
        max(layout.hasNotch ? layout.notchRect.height : 0, 12)
    }
}

#Preview("Hub — Now Playing") {
    SlabPreview(
        geometry: PreviewData.notchedScreen,
        presentation: .expanded(.nowPlaying),
        canvasHeight: 480
    ) { layout in
        ExpandedHubView(layout: layout, scale: 1, onClose: {})
            .environment(AppEnvironment.preview(activity: .media(PreviewData.playingMedia)))
    }
}

#Preview("Hub — high contrast, reduced motion") {
    SlabPreview(
        geometry: PreviewData.plainScreen,
        presentation: .expanded(.controls),
        increaseContrast: true,
        canvasHeight: 480
    ) { layout in
        ExpandedHubView(layout: layout, scale: 1, onClose: {})
            .environment(AppEnvironment.preview { preferences in
                preferences.increaseContrastOverride = true
                preferences.reduceMotionOverride = true
                preferences.accent = .amber
            })
    }
}
