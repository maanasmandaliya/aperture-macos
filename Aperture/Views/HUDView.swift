//
//  HUDView.swift
//  Aperture
//
//  Temporary overlays. They are intentionally narrow and short-lived: a HUD
//  never occupies the width the menu bar's right-hand controls need, and it
//  clears itself after a fixed dwell rather than waiting on a user action.
//

import SwiftUI

struct HUDView: View {

    var event: HUDEvent
    var layout: ScreenGeometry.Layout
    var accent: AccentChoice
    var increaseContrast: Bool
    var scale: CGFloat

    /// True while the level is still moving, which is when the reading is worth
    /// more than the name of the thing being read.
    @State private var isChanging = false
    @State private var settleTask: Task<Void, Never>?

    /// Interior only; the slab is owned by ``OverlayRootView``.
    var body: some View {
        Group {
            switch event.style {
            case .meter: meterBody
            case .message: messageBody
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(event.accessibilityDescription)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var metrics: OverlayMetrics { OverlayMetrics(layout: layout, scale: scale) }
    private var size: CGSize { metrics.hudSize(for: event.style) }

    // MARK: - Meter

    /// Label in one wing, level in the other, with the housing between them.
    ///
    /// Nothing is ever drawn across the housing, so on a notched display the
    /// slab can stay exactly as tall as the notch and simply reach out either
    /// side of it.
    @ViewBuilder
    private var meterBody: some View {
        if layout.hasNotch {
            HStack(spacing: 0) {
                wing { label }
                Color.clear
                    .frame(width: layout.notchRect.width)
                    .accessibilityHidden(true)
                wing { bar }
            }
        } else {
            HStack(spacing: Tokens.Space.md * scale) {
                label
                Spacer(minLength: 0)
                bar
            }
            .padding(.horizontal, Tokens.Space.md * scale)
        }
    }

    /// Padding goes *inside* the fixed width, not around it. Outside, each wing
    /// asks for more room than the slab allocates and the label is clipped
    /// rather than inset.
    private func wing<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, Tokens.Space.md * scale)
            .frame(width: metrics.meterWing)
    }

    /// The name of what is being changed, or its value while it is moving.
    ///
    /// One slot rather than two: a fixed percentage column would have to be
    /// wide enough for "100%" at all times, and the wing has no width to spare
    /// beside a word as long as "Brightness".
    private var label: some View {
        Text(isChanging ? readout : event.meterName)
            .font(Tokens.Text.caption)
            .foregroundStyle(Tokens.Palette.textPrimary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentTransition(.numericText())
            .animation(Tokens.Motion.controlState(reduceMotion: false), value: isChanging)
            .task(id: event.meterLevel) {
                isChanging = true
                // Cancelled and restarted by every further change, so holding a
                // volume key keeps the number up and only the last one settles.
                try? await Task.sleep(for: .seconds(Tokens.Motion.hudReadoutDwell))
                guard !Task.isCancelled else { return }
                isChanging = false
            }
    }

    private var bar: some View {
        ProgressStrip(progress: event.meterLevel, accent: accent, height: 5)
            .frame(maxWidth: .infinity)
    }

    private var readout: String {
        if case .volume(_, let muted) = event, muted { return "Muted" }
        return "\(Int((event.meterLevel * 100).rounded()))%"
    }

    // MARK: - Message

    private var messageBody: some View {
        VStack(spacing: 0) {
            if layout.hasNotch {
                Color.clear.frame(height: metrics.notchBand)
            }
            message
                .padding(.horizontal, Tokens.Space.md * scale)
                .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var message: some View {
        switch event {
        case .timerCompleted(let title):
            message(symbol: event.symbolName, title: "Timer finished", detail: title, tint: accent.color)
        case .notification(let note):
            message(
                symbol: note.symbolName,
                title: note.title,
                detail: note.body.isEmpty ? note.sourceName : note.body,
                tint: note.tint?.color ?? accent.color
            )
        case .volume, .brightness:
            // Meters never reach here; the style switch in `body` covers them.
            EmptyView()
        }
    }

    private func message(symbol: String, title: String, detail: String, tint: Color) -> some View {
        HStack(spacing: Tokens.Space.sm) {
            ZStack {
                Circle().fill(tint.opacity(0.20))
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Tokens.Text.caption)
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .lineLimit(1)
                Text(detail)
                    .font(Tokens.Text.micro)
                    .foregroundStyle(Tokens.Palette.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }
}

#Preview("HUD — volume") {
    SlabPreview(geometry: PreviewData.notchedScreen, presentation: .hud(.meter)) { layout in
        HUDView(
            event: .volume(level: 0.62, isMuted: false),
            layout: layout, accent: .mono, increaseContrast: false, scale: 1
        )
    }
}

#Preview("HUD — brightness") {
    SlabPreview(geometry: PreviewData.plainScreen, presentation: .hud(.meter)) { layout in
        HUDView(
            event: .brightness(level: 0.35, displayName: "Studio Display"),
            layout: layout, accent: .azure, increaseContrast: false, scale: 1
        )
    }
}

#Preview("HUD — timer finished") {
    SlabPreview(geometry: PreviewData.plainScreen, presentation: .hud(.message)) { layout in
        HUDView(
            event: .timerCompleted(title: "Steep tea"),
            layout: layout, accent: .amber, increaseContrast: false, scale: 1
        )
    }
}

#Preview("HUD — notification") {
    SlabPreview(geometry: PreviewData.notchedScreen, presentation: .hud(.message)) { layout in
        HUDView(
            event: .notification(PreviewData.notification),
            layout: layout, accent: .teal, increaseContrast: false, scale: 1
        )
    }
}
