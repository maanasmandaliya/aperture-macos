//
//  SchedulePane.swift
//  Aperture
//

import SwiftUI

struct SchedulePane: View {

    @Environment(AppEnvironment.self) private var environment

    var accent: AccentChoice

    /// The hub shows the next three; the rest stay in Calendar.app.
    private var events: [CalendarActivity] {
        Array(environment.calendar.upcomingEvents.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.sm) {
            if !environment.preferences.calendarEnabled {
                disabledState
            } else if !environment.calendar.access.isReadable {
                permissionState
            } else if events.isEmpty {
                emptyState
            } else {
                ForEach(events) { event in
                    EventRow(event: event, now: environment.now, accent: accent)
                }
                Spacer(minLength: 0)
                openCalendarButton
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Schedule")
    }

    private var openCalendarButton: some View {
        ApertureTextButton(
            title: "Open Calendar", systemImage: "arrow.up.forward.app",
            accent: accent, emphasis: .prominent
        ) {
            environment.calendar.openInCalendar(events.first)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityHint("Opens the next event in the Calendar app")
    }

    private var disabledState: some View {
        ScheduleMessage(
            symbol: "calendar.badge.exclamationmark",
            title: "Calendar is off",
            detail: "Turn Calendar on in Settings to see what's next. Aperture asks macOS for access only after you do.",
            accent: accent
        )
    }

    private var permissionState: some View {
        VStack(spacing: Tokens.Space.sm) {
            ScheduleMessage(
                symbol: "lock.badge.clock",
                title: "Calendar access needed",
                detail: environment.calendar.access.statusText,
                accent: accent
            )
            if environment.calendar.access == .notRequested {
                ApertureTextButton(title: "Grant Access", accent: accent, emphasis: .prominent) {
                    Task { await environment.calendar.requestAccess() }
                }
            } else {
                ApertureTextButton(title: "Open Privacy Settings", accent: accent) {
                    CalendarService.openPrivacySettings()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        ScheduleMessage(
            symbol: "checkmark.circle",
            title: "Nothing scheduled",
            detail: "No events in the next \(environment.preferences.lookAheadMinutes / 60) hours.",
            accent: accent
        )
    }
}

private struct ScheduleMessage: View {
    var symbol: String
    var title: String
    var detail: String
    var accent: AccentChoice

    var body: some View {
        VStack(spacing: Tokens.Space.xs) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Tokens.Palette.textTertiary)
            Text(title)
                .font(Tokens.Text.body)
                .foregroundStyle(Tokens.Palette.textSecondary)
            Text(detail)
                .font(Tokens.Text.caption)
                .foregroundStyle(Tokens.Palette.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Tokens.Space.md)
    }
}

private struct EventRow: View {
    var event: CalendarActivity
    var now: Date
    var accent: AccentChoice

    var body: some View {
        HStack(spacing: Tokens.Space.md) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(event.calendarColor.color)
                .frame(width: 3)
                .frame(maxHeight: .infinity)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(Tokens.Text.body)
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .lineLimit(1)
                HStack(spacing: Tokens.Space.xs) {
                    Text(EventTimeFormatter.startLabel(for: event, relativeTo: now))
                    if let location = event.location {
                        Text("·")
                        Text(location).lineLimit(1)
                    }
                }
                .font(Tokens.Text.micro)
                .foregroundStyle(Tokens.Palette.textTertiary)
            }

            Spacer(minLength: Tokens.Space.sm)

            Text(countdownLabel)
                .font(Tokens.Text.numeric)
                .foregroundStyle(event.isUnderway(at: now) ? accent.color : Tokens.Palette.textSecondary)
                .contentTransition(.numericText())
        }
        .padding(.vertical, Tokens.Space.sm)
        .padding(.horizontal, Tokens.Space.md)
        .background {
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .fill(Tokens.Palette.well.opacity(0.55))
        }
        .frame(height: 40)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var countdownLabel: String {
        if event.isAllDay { return "all day" }
        if event.isUnderway(at: now) { return "now" }
        return DurationFormatter.countdown(event.countdown(at: now))
    }

    private var accessibilityLabel: String {
        var parts = [event.title, EventTimeFormatter.rangeLabel(for: event)]
        if let location = event.location { parts.append("at \(location)") }
        parts.append(event.isUnderway(at: now) ? "happening now" : countdownLabel)
        parts.append("in calendar \(event.calendarTitle)")
        return parts.joined(separator: ", ")
    }
}

#Preview("Schedule — events") {
    let environment = AppEnvironment.preview { $0.calendarEnabled = true }
    return SchedulePane(accent: .azure)
        .environment(environment)
        .padding(Tokens.Space.lg)
        .frame(width: 420, height: 250)
        .background(Tokens.Palette.graphite)
        .environment(\.colorScheme, .dark)
}

#Preview("Schedule — calendar off") {
    SchedulePane(accent: .mono)
        .environment(AppEnvironment.preview())
        .padding(Tokens.Space.lg)
        .frame(width: 420, height: 250)
        .background(Tokens.Palette.graphite)
        .environment(\.colorScheme, .dark)
}
