//
//  AppearanceSettingsView.swift
//  Aperture
//

import SwiftUI

struct AppearanceSettingsView: View {

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var preferences = environment.preferences

        Form {
            Section {
                LabeledContent("Overlay scale") {
                    HStack(spacing: 10) {
                        Slider(value: $preferences.overlayScale, in: 0.85...1.30, step: 0.05)
                            .frame(width: 200)
                            .accessibilityLabel("Overlay scale")
                            .accessibilityValue("\(Int((preferences.overlayScale * 100).rounded())) percent")
                        Text("\(Int((preferences.overlayScale * 100).rounded()))%")
                            .monospacedDigit()
                            .valueColumn()
                    }
                }

                LabeledContent("Animation intensity") {
                    HStack(spacing: 10) {
                        Slider(value: $preferences.animationIntensity, in: 0...1)
                            .frame(width: 200)
                            .accessibilityLabel("Animation intensity")
                            .accessibilityValue(intensityLabel)
                        Text(intensityLabel)
                            .valueColumn()
                    }
                }
            } header: {
                Text("Size and motion")
            } footer: {
                Text("Lower intensity means shorter, flatter springs. Reduce Motion overrides this entirely.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Accent") {
                HStack(spacing: 12) {
                    ForEach(AccentChoice.allCases) { choice in
                        Button {
                            preferences.accent = choice
                        } label: {
                            Circle()
                                .fill(choice.gradient)
                                .frame(width: 26, height: 26)
                                .overlay {
                                    Circle()
                                        .strokeBorder(
                                            Color.primary.opacity(preferences.accent == choice ? 0.9 : 0.15),
                                            lineWidth: preferences.accent == choice ? 2 : 1
                                        )
                                }
                        }
                        .buttonStyle(.plain)
                        .help(choice.displayName)
                        .accessibilityLabel(choice.displayName)
                        .accessibilityAddTraits(preferences.accent == choice ? [.isSelected, .isButton] : .isButton)
                    }
                    Spacer()
                }
                .padding(.vertical, 2)

                Picker("Light and dark", selection: $preferences.appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section("Preview") {
                SlabPreview(
                    geometry: PreviewData.notchedScreen,
                    presentation: .minimal,
                    scale: preferences.resolvedScale,
                    increaseContrast: preferences.increaseContrast,
                    canvasHeight: 96,
                    // The form column is narrower than the stage's standard
                    // canvas, and a fixed canvas overflows rather than shrinks.
                    canvasWidth: .fill
                ) { layout in
                    MinimalPillView(
                        layout: layout,
                        accent: preferences.accent,
                        activity: .media(PreviewData.playingMedia),
                        artwork: nil,
                        isHovering: false,
                        reduceMotion: preferences.reduceMotion,
                        increaseContrast: preferences.increaseContrast,
                        scale: preferences.resolvedScale
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityLabel("Live preview of the collapsed pill")
            }
        }
        .formStyle(.grouped)
    }

    private var intensityLabel: String {
        let value = environment.preferences.resolvedAnimationIntensity
        switch value {
        case ..<0.25: return "Calm"
        case ..<0.6: return "Even"
        case ..<0.85: return "Lively"
        default: return "Springy"
        }
    }
}

private extension View {
    /// The read-out beside a slider.
    ///
    /// A fixed width is what made "Springy" wrap onto a second line and shove
    /// the rest of the pane down, so the width is a floor rather than a
    /// ceiling: the columns still line up, and a word that needs more room —
    /// or a larger accessibility text size — takes it.
    func valueColumn() -> some View {
        lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: 52, alignment: .trailing)
            .foregroundStyle(.secondary)
    }
}

#Preview("Appearance") {
    AppearanceSettingsView()
        .environment(AppEnvironment.preview())
        .frame(width: 600, height: 470)
}
