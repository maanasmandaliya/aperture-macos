//
//  ApertureSlider.swift
//  Aperture
//

import SwiftUI

/// A slim, keyboard- and VoiceOver-navigable slider.
///
/// Built rather than borrowed because the stock control cannot be made this
/// short without losing its hit target. Keyboard and accessibility parity is
/// preserved explicitly: it is focusable, arrow keys nudge, Home/End jump, and
/// it exposes an adjustable action to VoiceOver.
struct ApertureSlider: View {

    /// What the slider is for, which decides whether it wears a knob.
    enum Style: Equatable {
        /// Something the user takes hold of — volume, brightness. The knob
        /// marks where to grab, and the fill is at full strength.
        case control
        /// A timeline. It is read far more often than it is dragged, so it
        /// carries no knob and a softer fill; the leading edge of the fill is
        /// the playhead.
        case timeline
    }

    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var accent: AccentChoice
    var isEnabled: Bool = true
    var trackHeight: CGFloat = 5
    var style: Style = .control
    /// Restores full-strength fill: deliberately reducing contrast is the one
    /// thing this setting exists to undo.
    var increaseContrast: Bool = false
    var label: String
    var valueDescription: (Double) -> String
    var onCommit: ((Double) -> Void)? = nil

    @FocusState private var isFocused: Bool
    @State private var isDragging = false
    @State private var dragValue: Double = 0
    /// Focus rings are for keyboard users, but clicking a slider focuses it too
    /// — which is how a seek ended up leaving an outline parked on the track.
    /// The ring is shown for focus that arrives any way *other* than a drag, so
    /// tabbing to the slider still reveals it immediately.
    @State private var showsFocusRing = false

    private var span: Double { max(range.upperBound - range.lowerBound, .leastNonzeroMagnitude) }
    private var step: Double { span / 20 }
    private var displayed: Double { isDragging ? dragValue : value }
    private var fraction: Double { min(max((displayed - range.lowerBound) / span, 0), 1) }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Tokens.Palette.meterTrack)
                    .frame(height: trackHeight)

                Capsule(style: .continuous)
                    .fill(Self.fillColor(
                        style: style,
                        isEnabled: isEnabled,
                        increaseContrast: increaseContrast
                    ))
                    .frame(width: max(width * fraction, trackHeight), height: trackHeight)

                if style == .control {
                    Circle()
                        .fill(Color.white)
                        .frame(width: knobSize, height: knobSize)
                        .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                        .offset(x: max(min(width * fraction - knobSize / 2, width - knobSize), 0))
                        .opacity(isEnabled ? 1 : 0.35)
                }
            }
            // Reserves the knob's height even when none is drawn, so a
            // timeline keeps the same hit target and the same row height as a
            // control.
            .frame(height: max(knobSize, trackHeight), alignment: .center)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(dragGesture(width: width))
        }
        .frame(height: 18)
        .opacity(isEnabled ? 1 : 0.55)
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(accent.color.opacity(showsFocusRing && isFocused ? 0.9 : 0), lineWidth: 1.5)
                .padding(-3)
        }
        .focusable(isEnabled)
        .focused($isFocused)
        // AppKit's own blue ring would sit on top of the overlay's palette and
        // linger after a click; the app draws its own instead.
        .focusEffectDisabled()
        .onChange(of: isFocused) { _, focused in
            // Focus gained mid-drag came from the pointer; anything else is
            // keyboard navigation and should be visible straight away.
            showsFocusRing = focused && !isDragging
        }
        .onKeyPress(.leftArrow) { keyboardNudge(-step); return .handled }
        .onKeyPress(.rightArrow) { keyboardNudge(step); return .handled }
        .onKeyPress(.downArrow) { keyboardNudge(-step); return .handled }
        .onKeyPress(.upArrow) { keyboardNudge(step); return .handled }
        .onKeyPress(.home) { showsFocusRing = true; commit(range.lowerBound); return .handled }
        .onKeyPress(.end) { showsFocusRing = true; commit(range.upperBound); return .handled }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(valueDescription(displayed))
        .accessibilityAddTraits(.isButton)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: nudge(step)
            case .decrement: nudge(-step)
            @unknown default: break
            }
        }
    }

    private var knobSize: CGFloat { trackHeight + 7 }

    /// Colour of the filled part of the track.
    nonisolated static func fillColor(
        style: Style,
        isEnabled: Bool,
        increaseContrast: Bool
    ) -> Color {
        guard isEnabled else { return Tokens.Palette.hairline }
        guard style == .timeline, !increaseContrast else { return Tokens.Palette.meter }
        return Tokens.Palette.meterSoft
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                guard isEnabled, width > 0 else { return }
                showsFocusRing = false
                isDragging = true
                dragValue = valueFor(x: gesture.location.x, width: width)
                value = dragValue
            }
            .onEnded { gesture in
                guard isEnabled, width > 0 else { return }
                let final = valueFor(x: gesture.location.x, width: width)
                isDragging = false
                value = final
                onCommit?(final)
            }
    }

    private func valueFor(x: CGFloat, width: CGFloat) -> Double {
        let clamped = min(max(Double(x / width), 0), 1)
        return range.lowerBound + clamped * span
    }

    /// Keyboard adjustment also reveals the ring — that is the moment it starts
    /// being useful.
    private func keyboardNudge(_ delta: Double) {
        showsFocusRing = true
        nudge(delta)
    }

    private func nudge(_ delta: Double) {
        guard isEnabled else { return }
        commit(min(max(value + delta, range.lowerBound), range.upperBound))
    }

    private func commit(_ newValue: Double) {
        value = newValue
        onCommit?(newValue)
    }
}

/// Circular icon button used for transport and hub actions.
struct ApertureIconButton: View {

    var systemName: String
    var accessibilityLabel: String
    var accent: AccentChoice
    var size: CGFloat = 30
    /// The primary action. Same bare treatment as the rest, just larger and
    /// brighter — with no wells anywhere, emphasis comes from size and value.
    var isProminent: Bool = false
    /// Latched on, e.g. shuffle. Tints the glyph and shows a soft accent well.
    var isActive: Bool = false
    var isEnabled: Bool = true
    var action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * glyphScale, weight: isProminent ? .semibold : .medium))
                .foregroundStyle(glyphStyle)
                .frame(width: size, height: size)
                .contentShape(Circle())
            .frame(width: size, height: size)
            .scaleEffect(isHovering && isEnabled ? 1.06 : 1.0)
            .overlay {
                Circle()
                    .strokeBorder(accent.color.opacity(isFocused ? 0.9 : 0), lineWidth: 1.5)
                    .padding(-3)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .focused($isFocused)
        .focusEffectDisabled()
        .onHover { isHovering = $0 }
        .animation(Tokens.Motion.controlState(reduceMotion: reduceMotion), value: isHovering)
        .animation(Tokens.Motion.controlState(reduceMotion: reduceMotion), value: isActive)
        .animation(Tokens.Motion.controlState(reduceMotion: reduceMotion), value: isProminent)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    /// Bare glyphs carry less weight than filled ones, so the primary action is
    /// drawn considerably larger to stay the obvious target.
    private var glyphScale: CGFloat { isProminent ? 0.64 : 0.46 }

    /// With no wells, state has to be carried entirely by the glyph. Brightness
    /// does that work: latched-on and primary sit at full value, everything
    /// else rests dimmer and lifts on hover.
    private var glyphStyle: AnyShapeStyle {
        if isProminent { return AnyShapeStyle(Tokens.Palette.meter) }
        if isActive { return AnyShapeStyle(accent.color) }
        return AnyShapeStyle(isHovering ? Tokens.Palette.textPrimary : Tokens.Palette.textSecondary)
    }
}
