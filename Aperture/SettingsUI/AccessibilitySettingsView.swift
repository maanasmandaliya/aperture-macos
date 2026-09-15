//
//  AccessibilitySettingsView.swift
//  Aperture
//

import SwiftUI

struct AccessibilitySettingsView: View {

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var preferences = environment.preferences

        Form {
            Section {
                Toggle("Reduce motion", isOn: $preferences.reduceMotionOverride)
                Toggle("Increase contrast", isOn: $preferences.increaseContrastOverride)
            } header: {
                Text("Motion and contrast")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("These add to the system settings — they never turn a system setting off.")
                    if preferences.systemReduceMotion {
                        Label("macOS Reduce Motion is on, so Aperture is already using short fades.",
                              systemImage: "info.circle")
                    }
                    if preferences.systemIncreaseContrast {
                        Label("macOS Increase Contrast is on, so overlay borders are already stronger.",
                              systemImage: "info.circle")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Toggle hub") {
                    ShortcutRecorderView(
                        binding: $preferences.hotKey,
                        registrationFailed: registrationFailed(for: .toggleHub)
                    )
                }
                LabeledContent("Open mirror") {
                    ShortcutRecorderView(
                        binding: $preferences.mirrorHotKey,
                        registrationFailed: registrationFailed(for: .openMirror)
                    )
                }
            } header: {
                Text("Keyboard")
            } footer: {
                Text("The shortcuts work system-wide and need no Accessibility permission. Open mirror also closes the mirror when it is already showing. Inside the hub, Tab moves between controls, arrow keys adjust sliders, and Escape collapses it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("""
                    Every overlay state exposes a VoiceOver label describing what \
                    it is showing, and live values — countdowns, playback position, \
                    volume — are announced as they change. The collapsed pill \
                    reports the current activity and how to open the hub.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("VoiceOver")
            }
        }
        .formStyle(.grouped)
    }

    private func registrationFailed(for slot: HotKeySlot) -> Bool {
        (NSApp.delegate as? AppDelegate)?.hotKeyRegistrationFailed(for: slot) ?? false
    }
}

#Preview("Accessibility") {
    AccessibilitySettingsView()
        .environment(AppEnvironment.preview())
        .frame(width: 600, height: 470)
}
