//
//  ControlsPane.swift
//  Aperture
//

import AppKit
import SwiftUI

struct ControlsPane: View {

    @Environment(AppEnvironment.self) private var environment

    var accent: AccentChoice
    var onClose: () -> Void

    @State private var volumeDraft: Double?
    @State private var brightnessDraft: Double?

    var body: some View {
        VStack(spacing: 0) {
            outputRow
            Divider().overlay(Tokens.Palette.hairline.opacity(0.5))
            brightnessRow
            Divider().overlay(Tokens.Palette.hairline.opacity(0.5))
            focusRow
            Divider().overlay(Tokens.Palette.hairline.opacity(0.5))
            timerRow

            Spacer(minLength: Tokens.Space.sm)

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Controls")
    }

    // MARK: - Rows

    private var outputRow: some View {
        ControlRow(
            symbolName: environment.audio.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
            title: "Output",
            detail: environment.audio.capability.unavailableReason ?? environment.audio.deviceName,
            accent: accent,
            isAvailable: environment.audio.capability.canRead,
            unavailableExplanation: environment.audio.capability.unavailableReason
        ) {
            ApertureSlider(
                value: Binding(
                    get: { volumeDraft ?? environment.audio.level },
                    set: { newValue in
                        volumeDraft = newValue
                        environment.audio.setLevel(newValue)
                    }
                ),
                accent: accent,
                isEnabled: environment.audio.capability.canWrite,
                trackHeight: 4,
                label: "Output volume",
                valueDescription: { "\(Int(($0 * 100).rounded())) percent" },
                onCommit: { _ in volumeDraft = nil }
            )
            .frame(width: 130)
        }
    }

    private var brightnessRow: some View {
        ControlRow(
            symbolName: "sun.max.fill",
            title: "Brightness",
            detail: brightnessDetail,
            accent: accent,
            isAvailable: !environment.brightness.capability.isUnavailable,
            unavailableExplanation: BrightnessController.unsupportedExplanation
        ) {
            if environment.brightness.capability.isUnavailable {
                // Non-interactive status: the value cannot be read on this Mac,
                // through any of the three routes the controller tries.
                // Sized to its own text rather than to the slider it replaces,
                // so the row's explanation keeps the width it needs.
                Text("Unavailable")
                    .font(Tokens.Text.micro)
                    .foregroundStyle(Tokens.Palette.textTertiary)
                    .fixedSize()
            } else {
                ApertureSlider(
                    value: Binding(
                        get: { brightnessDraft ?? environment.brightness.level },
                        set: { newValue in
                            brightnessDraft = newValue
                            environment.brightness.setLevel(newValue)
                        }
                    ),
                    accent: accent,
                    isEnabled: environment.brightness.capability.canWrite,
                    trackHeight: 4,
                    label: "Display brightness",
                    valueDescription: { "\(Int(($0 * 100).rounded())) percent" },
                    onCommit: { _ in brightnessDraft = nil }
                )
                .frame(width: 130)
            }
        }
    }

    private var brightnessDetail: String {
        if environment.brightness.capability.isUnavailable {
            return "No brightness control for this display"
        }
        let name = environment.brightness.displayName
        return name.isEmpty ? "Connected display" : name
    }

    private var focusRow: some View {
        ControlRow(
            symbolName: environment.focus.state.symbolName,
            title: "Focus",
            detail: environment.focus.state == .notAuthorized ? "Aperture needs Focus permission" : nil,
            accent: accent,
            isAvailable: environment.focus.state == .on || environment.focus.state == .off,
            unavailableExplanation: "Focus status requires permission, granted the first time you open this tab."
        ) {
            if environment.focus.needsAuthorization {
                ApertureTextButton(title: "Allow", accent: accent, emphasis: .prominent) {
                    Task { await environment.focus.requestAuthorization() }
                }
            } else {
                Text(environment.focus.state.displayText)
                    .font(Tokens.Text.caption)
                    .foregroundStyle(
                        environment.focus.state == .on ? accent.color : Tokens.Palette.textSecondary
                    )
            }
        }
    }

    private var timerRow: some View {
        ControlRow(
            symbolName: "timer",
            title: "Timer",
            detail: environment.timers.active.map {
                DurationFormatter.clock($0.remaining(at: environment.now))
            } ?? "Not running",
            accent: accent
        ) {
            HStack(spacing: Tokens.Space.xs) {
                if environment.timers.active == nil {
                    ForEach([5, 10, 25], id: \.self) { minutes in
                        ApertureTextButton(title: "\(minutes)m", accent: accent) {
                            environment.timers.start(title: "\(minutes) minute timer", duration: TimeInterval(minutes * 60))
                            environment.recomputeActivity()
                        }
                        .accessibilityLabel("Start \(minutes) minute timer")
                    }
                } else {
                    ApertureIconButton(
                        systemName: environment.timers.active?.isPaused == true ? "play.fill" : "pause.fill",
                        accessibilityLabel: environment.timers.active?.isPaused == true ? "Resume timer" : "Pause timer",
                        accent: accent,
                        size: 24,
                        action: { environment.timers.togglePause() }
                    )
                    ApertureIconButton(
                        systemName: "stop.fill",
                        accessibilityLabel: "Stop timer",
                        accent: accent,
                        size: 24,
                        action: {
                            environment.timers.stop()
                            environment.recomputeActivity()
                        }
                    )
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: Tokens.Space.md) {
            ApertureTextButton(title: "Settings", systemImage: "gearshape", accent: accent) {
                NSApp.sendAction(#selector(AppDelegate.showSettings), to: nil, from: nil)
                onClose()
            }
            .accessibilityHint("Opens Aperture settings")

            ApertureTextButton(title: "Test HUD", systemImage: "bell.badge", accent: accent) {
                environment.notifications.emitSample()
            }
            .accessibilityHint("Shows a sample notification HUD")

            Spacer(minLength: 0)

            ApertureTextButton(
                title: "Quit", systemImage: "power",
                accent: accent, emphasis: .destructive
            ) {
                NSApp.terminate(nil)
            }
        }
    }
}

#Preview("Controls") {
    ControlsPane(accent: .mono, onClose: {})
        .environment(AppEnvironment.preview())
        .padding(Tokens.Space.lg)
        .frame(width: 420, height: 270)
        .background(Tokens.Palette.graphite)
        .environment(\.colorScheme, .dark)
}
