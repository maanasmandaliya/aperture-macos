//
//  MinimalPillView.swift
//  Aperture
//

import SwiftUI

/// The resting state, and where the overlay spends nearly all of its time.
///
/// On a notched Mac the slab straddles the camera housing and every element
/// lives in the wings either side of it, so nothing is drawn where there are no
/// pixels: artwork on the left, a track glyph on the right. That is the whole
/// resting presentation — the wide strip is a peek with a deadline, and the hub
/// only opens when asked. On a Mac with no housing the same elements lay out
/// across a plain pill.
struct MinimalPillView: View {

    var layout: ScreenGeometry.Layout
    var accent: AccentChoice
    var activity: Activity?
    /// Album art for the current track, when there is one.
    var artwork: NSImage?
    var isHovering: Bool
    /// False while the slab is kept alive but invisible — suppressed in a
    /// full-screen app. The tree has to exist so the hub can spring out of it,
    /// but nothing in it should still be animating.
    var isVisible: Bool = true
    var reduceMotion: Bool
    var increaseContrast: Bool
    var scale: CGFloat

    private var isActive: Bool { activity != nil }

    /// Interior only. The slab itself is owned by ``OverlayRootView`` so it can
    /// persist across state changes and be animated as one object.
    var body: some View {
        content
            .frame(width: size.width, height: size.height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Aperture")
            .accessibilityValue(accessibilityValue)
            .accessibilityHint("Click, swipe down with two fingers, or press the Aperture shortcut, to open the hub.")
            .accessibilityAddTraits(.isButton)
    }

    private var size: CGSize {
        OverlayMetrics(layout: layout, scale: scale)
            .minimalSize(isHovering: isHovering, hasActivity: isActive)
    }

    @ViewBuilder
    private var content: some View {
        if layout.hasNotch && !isActive {
            // Exactly the housing, carrying nothing — including while hovered.
            // Hover widens the slab by a few points, which is nowhere near
            // enough wing to hold a glyph; drawing one would just clip it. The
            // widening is the affordance.
            Color.clear.accessibilityHidden(true)
        } else if layout.hasNotch {
            HStack(spacing: 0) {
                wing { statusCluster }
                // Reserve the housing. Nothing may be drawn here.
                Color.clear
                    .frame(width: layout.notchRect.width)
                    .accessibilityHidden(true)
                wing { activityCluster }
            }
        } else {
            HStack(spacing: Tokens.Space.sm) {
                statusCluster
                Spacer(minLength: 0)
                Text(isActive ? (activity?.summary ?? "") : ApertureInfo.name)
                    .font(Tokens.Text.micro)
                    .foregroundStyle(isActive ? Tokens.Palette.textSecondary : Tokens.Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                activityCluster
            }
            .padding(.horizontal, Tokens.Space.md * scale)
        }
    }

    private func wing<Wing: View>(@ViewBuilder _ content: () -> Wing) -> some View {
        content()
            .frame(width: (size.width - layout.notchRect.width) / 2)
    }

    /// Left wing. Album art whenever a track is playing, otherwise the status
    /// dot — the artwork *is* the status when there is one.
    @ViewBuilder
    private var statusCluster: some View {
        if case .media(let media) = activity, media.hasTrack {
            ArtworkView(
                image: artwork,
                side: artworkSide,
                accent: accent,
                isPlaying: media.isPlaying,
                cornerRadius: artworkSide * 0.28,
                reduceMotion: reduceMotion,
                flipKey: media.identity
            )
            .transition(.opacity.combined(with: .scale(scale: 0.6)))
        } else {
            StatusIndicator(accent: accent, isActive: isActive, reduceMotion: reduceMotion)
        }
    }

    /// Sized to leave a clear margin inside the housing's height, so the art
    /// never crowds the bezel.
    private var artworkSide: CGFloat {
        max(min(size.height - 12 * scale, 22 * scale), 12)
    }

    /// Right wing. A moving waveform while audio is actually playing, so the
    /// resting slab still says "this is live" at a glance; a static glyph for
    /// everything else.
    @ViewBuilder
    private var activityCluster: some View {
        if case .media(let media) = activity, media.isPlaying {
            PlaybackPulse(accent: accent, isPlaying: isVisible, reduceMotion: reduceMotion)
                .transition(.opacity)
        } else if let activity {
            Image(systemName: activity.kind.symbolName)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Tokens.Palette.meter)
                .symbolRenderingMode(.hierarchical)
                .transition(.opacity.combined(with: .scale(scale: 0.7)))
        } else {
            Image(systemName: "circle.dotted")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Tokens.Palette.textTertiary.opacity(0.7))
        }
    }

    private var accessibilityValue: String {
        guard let activity else { return "Nothing active" }
        return "\(activity.kind.accessibilityNoun): \(activity.summary)"
    }
}

#Preview("Idle — notched") {
    SlabPreview(geometry: PreviewData.notchedScreen, presentation: .minimal) { layout in
        MinimalPillView(
            layout: layout, accent: .mono, activity: nil,
            artwork: nil,
            isHovering: false, reduceMotion: false, increaseContrast: false, scale: 1
        )
    }
}

#Preview("Idle — non-notched, hovering") {
    SlabPreview(geometry: PreviewData.plainScreen, presentation: .minimal) { layout in
        MinimalPillView(
            layout: layout, accent: .mono, activity: nil,
            artwork: nil,
            isHovering: true, reduceMotion: false, increaseContrast: false, scale: 1
        )
    }
}

#Preview("Idle — with media activity") {
    SlabPreview(geometry: PreviewData.notchedScreen, presentation: .minimal) { layout in
        MinimalPillView(
            layout: layout, accent: .teal, activity: .media(PreviewData.playingMedia),
            artwork: nil,
            isHovering: false, reduceMotion: false, increaseContrast: false, scale: 1
        )
    }
}
