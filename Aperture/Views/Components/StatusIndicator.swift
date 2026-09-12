//
//  StatusIndicator.swift
//  Aperture
//

import SwiftUI

/// The small dot on the left wing of the idle pill.
///
/// It is the only always-on element, so it carries the whole "is Aperture
/// awake" signal: dim gray when idle, accent-tinted with a slow breath when an
/// activity is live. The breath is suppressed under Reduce Motion.
struct StatusIndicator: View {

    var accent: AccentChoice
    var isActive: Bool
    var reduceMotion: Bool

    @State private var isBreathing = false

    var body: some View {
        ZStack {
            if isActive {
                Circle()
                    .fill(Tokens.Palette.meter.opacity(0.28))
                    .frame(width: Tokens.Size.statusDot * 2.4, height: Tokens.Size.statusDot * 2.4)
                    .scaleEffect(isBreathing ? 1.0 : 0.55)
                    .opacity(isBreathing ? 0.0 : 0.9)
            }
            Circle()
                .fill(isActive ? AnyShapeStyle(Tokens.Palette.meter) : AnyShapeStyle(Tokens.Palette.textTertiary.opacity(0.6)))
                .frame(width: Tokens.Size.statusDot, height: Tokens.Size.statusDot)
        }
        .frame(width: Tokens.Size.statusDot * 2.4, height: Tokens.Size.statusDot * 2.4)
        .onAppear { startBreathIfNeeded() }
        .onChange(of: isActive) { _, _ in startBreathIfNeeded() }
        .onChange(of: reduceMotion) { _, _ in startBreathIfNeeded() }
        .accessibilityHidden(true)
    }

    private func startBreathIfNeeded() {
        guard isActive, !reduceMotion else {
            isBreathing = false
            return
        }
        withAnimation(.easeOut(duration: 2.8).repeatForever(autoreverses: false)) {
            isBreathing = true
        }
    }
}

/// Thin capsule progress used on the compact strip.
struct ProgressStrip: View {
    var progress: Double
    var accent: AccentChoice
    var height: CGFloat = 3

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Tokens.Palette.meterTrack)
                Capsule(style: .continuous)
                    .fill(Tokens.Palette.meter)
                    .frame(width: max(proxy.size.width * min(max(progress, 0), 1), height))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// Six-bar equaliser shown while media is playing. Purely decorative, and it
/// stops moving entirely under Reduce Motion (where it becomes a static
/// waveform glyph instead of a frozen bar chart).
struct PlaybackPulse: View {
    var accent: AccentChoice
    var isPlaying: Bool
    var reduceMotion: Bool

    /// Raised bars, toggled once. Everything after that is Core Animation's job.
    @State private var raised = false

    private static let bars = 4
    private static let barWidth: CGFloat = 2
    private static let barSpacing: CGFloat = 2
    private static let barHeight: CGFloat = 12
    private static let intrinsicWidth: CGFloat =
        CGFloat(bars) * barWidth + CGFloat(bars - 1) * barSpacing

    var body: some View {
        if reduceMotion {
            Image(systemName: isPlaying ? "waveform" : "pause.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Tokens.Palette.meter)
        } else {
            // Scaled, not resized, and animated by a repeating curve rather than
            // a per-frame timeline.
            //
            // This was a `TimelineView` recomputing four bar *heights* twelve
            // times a second. Measured, that one view cost ~14% of a core with a
            // track playing — every tick drove a full SwiftUI update, once per
            // display. A `scaleEffect` under `repeatForever` is handed to Core
            // Animation instead: the app does no work per frame at all, and the
            // bars still ripple because each carries its own duration and drifts
            // out of phase with its neighbours.
            HStack(alignment: .center, spacing: Self.barSpacing) {
                ForEach(0..<Self.bars, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(Tokens.Palette.meter)
                        .frame(width: Self.barWidth, height: Self.barHeight)
                        .scaleEffect(y: scale(for: index), anchor: .center)
                        .animation(curve(for: index), value: raised)
                        .animation(Tokens.Motion.controlState(reduceMotion: false), value: isPlaying)
                }
            }
            .frame(width: Self.intrinsicWidth, height: Self.barHeight)
            .onAppear { raised = isPlaying }
            .onChange(of: isPlaying) { _, playing in raised = playing }
        }
    }

    /// Silence sits as a row of stubs; playback swings between a low and a high
    /// scale, each bar on its own beat.
    private func scale(for index: Int) -> CGFloat {
        guard isPlaying else { return 0.25 }
        return raised ? highScale(for: index) : 0.3
    }

    private func highScale(for index: Int) -> CGFloat {
        [1.0, 0.72, 0.92, 0.6][index % 4]
    }

    private func curve(for index: Int) -> Animation? {
        guard isPlaying else { return .easeOut(duration: 0.2) }
        // Deliberately unequal, and none a multiple of another: equal durations
        // would march the bars in lockstep and read as a single block.
        let duration = [0.46, 0.63, 0.53, 0.71][index % 4]
        return .easeInOut(duration: duration).repeatForever(autoreverses: true)
    }
}
