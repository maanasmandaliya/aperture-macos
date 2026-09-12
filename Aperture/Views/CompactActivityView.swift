//
//  CompactActivityView.swift
//  Aperture
//
//  The peek: the resting slab dropping open to name what just started.
//

import SwiftUI

/// The transient peek shown when an activity starts or changes.
///
/// It keeps the resting slab's width exactly and grows *downward* by one row.
/// Announcing without widening is what keeps it reading as the camera housing
/// rather than as a panel that arrived from somewhere else, and it means the
/// only thing the peek has to say is the name — everything else waits for the
/// hub. The top row is the resting slab's own content, so the artwork and
/// meter appear not to move at all while the name drops in beneath them.
struct CompactActivityView: View {

    var activity: Activity
    var layout: ScreenGeometry.Layout
    var accent: AccentChoice
    var artwork: NSImage?
    var now: Date
    var reduceMotion: Bool
    var increaseContrast: Bool
    var scale: CGFloat

    private var metrics: OverlayMetrics { OverlayMetrics(layout: layout, scale: scale) }

    var body: some View {
        VStack(spacing: 0) {
            topRow
                .frame(height: layout.pillSize.height)
            title
                .frame(height: metrics.peekTitleRow)
        }
        .frame(width: metrics.compactSize.width, height: metrics.compactSize.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Unchanged from the resting slab, so nothing appears to jump when the
    /// peek opens: content in the wings, never across the housing.
    @ViewBuilder
    private var topRow: some View {
        if layout.hasNotch {
            HStack(spacing: 0) {
                wing { leading }
                Color.clear
                    .frame(width: layout.notchRect.width)
                    .accessibilityHidden(true)
                wing { trailing }
            }
        } else {
            HStack(spacing: Tokens.Space.sm) {
                leading
                Spacer(minLength: 0)
                trailing
            }
            .padding(.horizontal, Tokens.Space.md * scale)
        }
    }

    private func wing<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(width: (metrics.compactSize.width - layout.notchRect.width) / 2)
    }

    @ViewBuilder
    private var leading: some View {
        if case .media(let media) = activity {
            ArtworkView(
                image: artwork,
                side: artworkSide,
                accent: accent,
                isPlaying: true,
                cornerRadius: artworkSide * 0.28,
                reduceMotion: reduceMotion,
                flipKey: media.identity
            )
        } else {
            Image(systemName: activity.kind.symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Tokens.Palette.meter)
                .frame(width: artworkSide, height: artworkSide)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if case .media(let media) = activity {
            PlaybackPulse(accent: accent, isPlaying: media.isPlaying, reduceMotion: reduceMotion)
        } else {
            Image(systemName: activity.kind.symbolName)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Tokens.Palette.meter)
        }
    }

    private var artworkSide: CGFloat {
        max(min(layout.pillSize.height - 12 * scale, 22 * scale), 12)
    }

    /// The one thing the peek exists to say. Spans the full width because it
    /// sits below the housing, where there is nothing to avoid.
    private var title: some View {
        Text(activity.summary)
            .font(Tokens.Text.body)
            .foregroundStyle(Tokens.Palette.textPrimary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Tokens.Space.md * scale)
    }

    private var accessibilityLabel: String {
        switch activity {
        case .media(let media):
            "Now playing: \(media.title) by \(media.artist)"
        case .timer(let timer):
            "Timer \(timer.title), \(DurationFormatter.spokenClock(timer.remaining(at: now))) remaining"
        case .calendar(let event):
            "\(event.title), \(event.isUnderway(at: now) ? "happening now" : DurationFormatter.countdown(event.countdown(at: now)))"
        case .call(let call):
            "Call with \(call.title)"
        }
    }
}

#Preview("Peek — media, notched") {
    SlabPreview(geometry: PreviewData.notchedScreen, presentation: .compact) { layout in
        CompactActivityView(
            activity: .media(PreviewData.playingMedia),
            layout: layout, accent: .mono,
            artwork: ArtworkGenerator.fallbackImage(for: "Slow Meridian|Halden Cross"),
            now: PreviewData.referenceDate, reduceMotion: false, increaseContrast: false, scale: 1
        )
    }
}

#Preview("Peek — media, non-notched") {
    SlabPreview(geometry: PreviewData.plainScreen, presentation: .compact) { layout in
        CompactActivityView(
            activity: .media(PreviewData.playingMedia),
            layout: layout, accent: .mono,
            artwork: ArtworkGenerator.fallbackImage(for: "Slow Meridian|Halden Cross"),
            now: PreviewData.referenceDate, reduceMotion: false, increaseContrast: false, scale: 1
        )
    }
}

#Preview("Peek — timer") {
    SlabPreview(geometry: PreviewData.notchedScreen, presentation: .compact) { layout in
        CompactActivityView(
            activity: .timer(PreviewData.runningTimer),
            layout: layout, accent: .mono, artwork: nil,
            now: PreviewData.referenceDate, reduceMotion: false, increaseContrast: false, scale: 1
        )
    }
}

#Preview("Peek — calendar") {
    SlabPreview(geometry: PreviewData.notchedScreen, presentation: .compact) { layout in
        CompactActivityView(
            activity: .calendar(PreviewData.imminentEvent),
            layout: layout, accent: .mono, artwork: nil,
            now: PreviewData.referenceDate, reduceMotion: false, increaseContrast: false, scale: 1
        )
    }
}
