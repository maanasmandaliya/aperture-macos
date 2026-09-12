//
//  ArtworkView.swift
//  Aperture
//

import SwiftUI

/// Artwork treatment: rounded, hairlined, and floated over a bloom tinted with
/// the accent. When no image exists the same frame carries a generated glyph so
/// the layout never collapses.
struct ArtworkView: View {

    var image: NSImage?
    var side: CGFloat
    var accent: AccentChoice
    var isPlaying: Bool
    var cornerRadius: CGFloat = Tokens.Radius.artwork
    /// Whether the cover shrinks and drains of colour while paused. Only the
    /// large treatment does: at thumbnail size the same change reads as jitter
    /// rather than as a state.
    var reactsToPlayback: Bool = false
    var reduceMotion: Bool = false
    var animationIntensity: Double = 0.6
    /// Identity of the track this cover belongs to. Changing it turns the cover
    /// over to reveal the new one; passing an empty key disables the flip.
    var flipKey: String = ""

    /// The cover actually on screen, which lags `image` for half a flip.
    @State private var shown: NSImage?
    @State private var shownKey: String?
    @State private var angle: Double = 0
    @State private var isFlipping = false

    /// Paused covers sit back: a little smaller, a little grey, resting closer
    /// to the panel. Playing snaps them back to full size and full colour.
    private var isResting: Bool { reactsToPlayback && !isPlaying }

    var body: some View {
        ZStack {
            if side > 60 {
                AccentBloom(accent: accent, intensity: isPlaying ? 0.9 : 0.4)
                    .frame(width: side * 1.5, height: side * 1.5)
                    .blur(radius: 18)
            }

            Group {
                if let shown {
                    Image(nsImage: shown)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Rectangle().fill(Tokens.Palette.well)
                        Image(systemName: "music.note")
                            .font(.system(size: side * 0.34, weight: .medium))
                            .foregroundStyle(Tokens.Palette.textTertiary)
                    }
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.7)
            }
            .saturation(isResting ? Tokens.Size.artworkPausedSaturation : 1)
            .scaleEffect(isResting ? Tokens.Size.artworkPausedScale : 1)
            // Perspective kept shallow: at these sizes a strong vanishing point
            // makes the cover look like it is falling away rather than turning.
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.35)
            // Shadow eases off with the scale so the cover reads as settling
            // toward the panel rather than just getting smaller.
            .shadow(
                color: .black.opacity(isResting ? 0.28 : 0.45),
                radius: (side > 60 ? 14 : 4) * (isResting ? 0.6 : 1),
                y: (side > 60 ? 6 : 2) * (isResting ? 0.5 : 1)
            )
        }
        // Fixed frame, so shrinking the cover never reflows the row around it.
        .frame(width: side, height: side)
        .animation(
            Tokens.Motion.artwork(intensity: animationIntensity, reduceMotion: reduceMotion),
            value: isPlaying
        )
        .onAppear {
            shown = image
            shownKey = flipKey
        }
        .onChange(of: flipKey) { _, newKey in
            handleTrackChange(to: newKey)
        }
        .onChange(of: image) { _, newImage in
            // Artwork can arrive *after* the track does — the Music provider
            // fetches it in a second round trip — so a late image for the track
            // already on screen is swapped in without a flip.
            if shownKey == flipKey { shown = newImage }
        }
        .accessibilityHidden(true)
    }

    /// Turns the cover over: rotate to edge-on, swap faces there, rotate back.
    ///
    /// Two halves rather than one 180° sweep, because a single rotation would
    /// leave the incoming cover mirrored for the second half of the turn.
    /// Jumping to −90° at the midpoint puts the new face the right way round.
    private func handleTrackChange(to newKey: String) {
        let newImage = image

        // Nothing to turn over yet, or motion is unwanted.
        guard let current = shownKey, !current.isEmpty, !newKey.isEmpty, !reduceMotion else {
            shown = newImage
            shownKey = newKey
            angle = 0
            return
        }

        // A change arriving mid-flip cuts to the newest cover rather than
        // queueing a second turn behind the first.
        guard !isFlipping else {
            shown = newImage
            shownKey = newKey
            angle = 0
            return
        }

        isFlipping = true
        let half = Tokens.Motion.artworkFlipHalf(intensity: animationIntensity)

        withAnimation(.easeIn(duration: half)) { angle = 90 }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(half))
            shown = newImage
            shownKey = newKey

            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { angle = -90 }

            withAnimation(.easeOut(duration: half)) { angle = 0 }
            try? await Task.sleep(for: .seconds(half))
            isFlipping = false
        }
    }
}

/// Title/subtitle pair with consistent truncation. Kept as one view so every
/// surface truncates identically.
struct TrackLabel: View {
    var title: String
    var subtitle: String
    var titleFont: Font = Tokens.Text.title
    var subtitleFont: Font = Tokens.Text.caption
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(title)
                .font(titleFont)
                .foregroundStyle(Tokens.Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(subtitleFont)
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .center)
    }
}
