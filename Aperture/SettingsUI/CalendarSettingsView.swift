//
//  CalendarSettingsView.swift
//  Aperture
//

import SwiftUI

struct CalendarSettingsView: View {

    @Environment(AppEnvironment.self) private var environment
    @State private var isRequesting = false

    private var service: CalendarService { environment.calendar }

    var body: some View {
        @Bindable var preferences = environment.preferences

        Form {
            Section {
                Toggle("Show calendar events", isOn: $preferences.calendarEnabled)
                LabeledContent("Permission") {
                    HStack(spacing: 8) {
                        Image(systemName: statusSymbol)
                            .foregroundStyle(statusTint)
                        Text(service.access.statusText)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                permissionAction
            } header: {
                Text("Access")
            } footer: {
                Text("Aperture asks macOS for calendar access only after you switch this on. Events are read on this Mac and never leave it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Look ahead", selection: $preferences.lookAheadMinutes) {
                    Text("2 hours").tag(120)
                    Text("6 hours").tag(360)
                    Text("12 hours").tag(720)
                    Text("24 hours").tag(1440)
                    Text("48 hours").tag(2880)
                }
            } header: {
                Text("Window")
            } footer: {
                Text("The pill only counts down an event once it is within 15 minutes; this window controls the Schedule tab.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                if service.availableCalendars.isEmpty {
                    Text(preferences.calendarEnabled
                         ? "No calendars available yet."
                         : "Turn calendar events on to choose calendars.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(service.availableCalendars) { calendar in
                        Toggle(isOn: binding(for: calendar)) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(calendar.color.color)
                                    .frame(width: 10, height: 10)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(calendar.title)
                                    if !calendar.sourceName.isEmpty {
                                        Text(calendar.sourceName)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("Calendars")
            } footer: {
                Text("With nothing selected, Aperture shows every calendar.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { service.reloadCalendars() }
    }

    @ViewBuilder
    private var permissionAction: some View {
        switch service.access {
        case .notRequested:
            Button(isRequesting ? "Requesting…" : "Request Access") {
                isRequesting = true
                Task {
                    // Deliberate user action, so lift the once-per-launch guard
                    // that stops background preference changes from re-prompting.
                    service.allowRetryingAccess()
                    await service.requestAccess()
                    isRequesting = false
                }
            }
            .disabled(isRequesting)
        case .denied, .restricted, .writeOnly:
            Button("Open Privacy Settings") { CalendarService.openPrivacySettings() }
        case .authorized:
            Button("Refresh Calendars") { service.reloadCalendars() }
        }
    }

    private var statusSymbol: String {
        switch service.access {
        case .authorized: "checkmark.circle.fill"
        case .notRequested: "questionmark.circle"
        default: "exclamationmark.triangle.fill"
        }
    }

    private var statusTint: Color {
        switch service.access {
        case .authorized: Tokens.Palette.positive
        case .notRequested: .secondary
        default: Tokens.Palette.warning
        }
    }

    private func binding(for calendar: CalendarService.CalendarInfo) -> Binding<Bool> {
        Binding(
            get: { environment.preferences.selectedCalendarIDs.contains(calendar.id) },
            set: { isOn in
                var identifiers = environment.preferences.selectedCalendarIDs
                if isOn { identifiers.insert(calendar.id) } else { identifiers.remove(calendar.id) }
                environment.preferences.selectedCalendarIDs = identifiers
                environment.calendar.updateSelection(identifiers)
            }
        )
    }
}

#Preview("Calendar") {
    CalendarSettingsView()
        .environment(AppEnvironment.preview())
        .frame(width: 600, height: 470)
}
