//
//  GeneralSettingsView.swift
//  Aperture
//

import ServiceManagement
import SwiftUI

struct GeneralSettingsView: View {

    @Environment(AppEnvironment.self) private var environment
    @State private var loginItemStatusText = LoginItemManager.statusDescription
    /// Re-checked when the window regains focus: the user grants this in System
    /// Settings, and macOS sends no notification when they do.
    @State private var isAccessibilityGranted = MediaKeyTap.isPermitted()

    var body: some View {
        @Bindable var preferences = environment.preferences

        Form {
            Section {
                Toggle("Launch Aperture at login", isOn: Binding(
                    get: { preferences.launchAtLogin },
                    set: { newValue in
                        preferences.launchAtLogin = newValue
                        let status = LoginItemManager.setEnabled(newValue)
                        loginItemStatusText = LoginItemManager.statusDescription
                        // Reflect reality: an unsigned or relocated build cannot
                        // register, and silently showing "on" would be a lie.
                        if newValue, status != .enabled {
                            preferences.launchAtLogin = (status == .requiresApproval)
                        }
                    }
                ))
                if LoginItemManager.requiresApproval {
                    HStack {
                        Text(loginItemStatusText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Open Login Items") { LoginItemManager.openLoginItemsSettings() }
                            .controlSize(.small)
                    }
                } else {
                    Text(loginItemStatusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Startup")
            }

            Section {
                Toggle("Show on every Space", isOn: $preferences.showInFullscreen)
                Toggle("Hide the pill in full-screen apps", isOn: $preferences.hideInFullscreen)
                Toggle("Grow the pill on hover", isOn: $preferences.hoverExpansion)
                Toggle("Tap the trackpad on hover", isOn: $preferences.hapticFeedback)
                Toggle("Close the hub when you stop using it", isOn: $preferences.autoCollapseHub)
            } header: {
                Text("Overlay")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Aperture rests as a small slab around the camera housing, showing artwork and a track glyph. Click it or swipe down on it with two fingers to open the hub; swipe up to close it again.")
                    Text("Hover only enlarges the pill. Opening the hub always needs a click, a swipe or the shortcut, so brushing the top of the screen never interrupts you.")
                    Text("The trackpad tap needs a Force Touch trackpad and follows \u{201C}Force Click and haptic feedback\u{201D} in System Settings; on other hardware it is simply silent.")
                    Text("With \u{201C}Hide the pill in full-screen apps\u{201D} on, Aperture shows nothing of its own accord while an app is full screen \u{2014} no pill, no track announcements, no finished-timer alerts. What you ask for still appears: the volume and brightness readouts when you press those keys, and the hub when you swipe down with two fingers at the top of the screen or press the shortcut. Clicking cannot open the hub there, because a pill that is not drawn must not swallow clicks meant for the app underneath.")
                    Label(
                        "Full-screen Spaces are detected from the public window list rather than reported by macOS, so an app that covers the whole screen without using a full-screen Space is not affected.",
                        systemImage: "info.circle"
                    )
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show only Aperture's volume and brightness readout", isOn: $preferences.interceptMediaKeys)
                if preferences.interceptMediaKeys && !isAccessibilityGranted {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Aperture could not take the keys. It needs two permissions — Input Monitoring to see them, Accessibility to swallow them — and macOS reports only that the request was refused, never which one is missing.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Request Permissions") { environment.requestMediaKeyPermissions() }
                                .controlSize(.small)
                            Button("Open Accessibility") { MediaKeyTap.openAccessibilitySettings() }
                                .controlSize(.small)
                            Button("Open Input Monitoring") { MediaKeyTap.openInputMonitoringSettings() }
                                .controlSize(.small)
                        }
                        Text("Aperture appears in the Input Monitoring list only after it asks — that list has no + button — so use Request Permissions first, then tick it in both panes.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        // The confusing case: a row is there and ticked, yet
                        // the check still fails, because macOS remembers the
                        // exact build it was granted to.
                        Text("If an Aperture entry is already listed and ticked, remove it with – and add this copy again. An unsigned build gets a new identity every time it is rebuilt, so an older entry no longer matches.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text("Volume and brightness keys")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("macOS draws its own panel whenever it handles a volume or brightness key, and offers no way to switch that off. Aperture can take the keys before the system sees them and make the change itself, so only its own readout appears.")
                    Label(
                        "Without the permission nothing is installed: the keys keep working exactly as they do now, and macOS keeps drawing its panel. Aperture needs no other permission to run.",
                        systemImage: "info.circle"
                    )
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Media", isOn: $preferences.showMedia)
                Toggle("Calendar events", isOn: $preferences.showCalendar)
                Toggle("Timers", isOn: $preferences.showTimers)
            } header: {
                Text("Show on the pill")
            } footer: {
                Text("When several are live at once, Aperture shows the most urgent: call, then timer, then media, then calendar.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Media source", selection: $preferences.mediaSource) {
                    ForEach(MediaSourceChoice.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                Text(preferences.mediaSource.explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Playback")
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isAccessibilityGranted = MediaKeyTap.isPermitted()
            environment.applyMediaKeyPreference()
        }
    }
}

#Preview("General") {
    GeneralSettingsView()
        .environment(AppEnvironment.preview())
        .frame(width: 600, height: 470)
}
