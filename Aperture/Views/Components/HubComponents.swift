//
//  HubComponents.swift
//  Aperture
//
//  Shared pieces of the expanded hub: its buttons and control rows.
//

import SwiftUI

/// A flat text button for the overlay.
///
/// The hub has no filled controls at all, so these are bare labels: dim at
/// rest, full brightness on hover, with the accent reserved for the one action
/// a pane is steering you toward and the critical colour for anything
/// destructive. AppKit's `.bordered` style would put a translucent capsule back
/// behind every one of them.
struct ApertureTextButton: View {

    enum Emphasis {
        case normal
        case prominent
        case destructive
    }

    var title: String
    var systemImage: String?
    var accent: AccentChoice
    var emphasis: Emphasis = .normal
    var isEnabled: Bool = true
    var action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Space.xs) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .font(Tokens.Text.caption)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, Tokens.Space.xs)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .focused($isFocused)
        .focusEffectDisabled()
        .onHover { isHovering = $0 }
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(accent.color.opacity(isFocused ? 0.9 : 0), lineWidth: 1.5)
                .padding(-2)
        }
        .animation(Tokens.Motion.controlState(reduceMotion: reduceMotion), value: isHovering)
        .accessibilityLabel(title)
    }

    private var foreground: Color {
        switch emphasis {
        case .prominent: accent.color
        case .destructive: isHovering ? Tokens.Palette.critical : Tokens.Palette.critical.opacity(0.75)
        case .normal: isHovering ? Tokens.Palette.textPrimary : Tokens.Palette.textSecondary
        }
    }
}

/// A labelled row in the Controls tab, with an optional trailing control and an
/// explanation shown when the underlying capability is unavailable.
struct ControlRow<Trailing: View>: View {

    var symbolName: String
    var title: String
    var detail: String?
    var accent: AccentChoice
    var isAvailable: Bool = true
    var unavailableExplanation: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Tokens.Space.md) {
            Image(systemName: symbolName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isAvailable ? Tokens.Palette.textPrimary : Tokens.Palette.textTertiary)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Tokens.Text.body)
                    .foregroundStyle(Tokens.Palette.textPrimary)
                if let detail {
                    Text(detail)
                        .font(Tokens.Text.micro)
                        .foregroundStyle(Tokens.Palette.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: Tokens.Space.sm)

            trailing
        }
        .padding(.vertical, 5)
        .opacity(isAvailable ? 1 : 0.75)
        .help(isAvailable ? "" : (unavailableExplanation ?? ""))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityHint(isAvailable ? (detail ?? "") : (unavailableExplanation ?? "Unavailable"))
    }
}
