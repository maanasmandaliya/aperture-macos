//
//  Formatters.swift
//  Aperture
//

import Foundation

enum DurationFormatter {

    /// `m:ss`, or `h:mm:ss` past an hour. Used for playheads and countdowns.
    static func clock(_ interval: TimeInterval) -> String {
        let total = Int(max(interval, 0).rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Compact relative phrasing for event countdowns: "now", "in 4 min", "in 2 h".
    static func countdown(_ interval: TimeInterval) -> String {
        if interval <= 30 { return "now" }
        let minutes = Int((interval / 60).rounded())
        if minutes < 60 { return "in \(minutes) min" }
        let hours = Double(minutes) / 60
        if hours < 24 {
            // One decimal only while it says something: "in 1.6 h" is useful,
            // "in 4.0 h" is just noise.
            let rounded = (hours * 10).rounded() / 10
            if hours >= 6 || rounded == rounded.rounded() {
                return "in \(Int(rounded.rounded())) h"
            }
            return "in \(String(format: "%.1f", rounded)) h"
        }
        return "in \(Int((hours / 24).rounded())) d"
    }

    /// Spoken form, so VoiceOver does not read "4:03" as a time of day.
    static func spokenClock(_ interval: TimeInterval) -> String {
        let total = Int(max(interval, 0).rounded())
        let minutes = total / 60
        let seconds = total % 60
        var parts: [String] = []
        if minutes > 0 { parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")") }
        if seconds > 0 || minutes == 0 { parts.append("\(seconds) second\(seconds == 1 ? "" : "s")") }
        return parts.joined(separator: " ")
    }
}

enum EventTimeFormatter {

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let dayTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE j:mm")
        return formatter
    }()

    /// Time alone for today, weekday + time otherwise.
    static func startLabel(for event: CalendarActivity, relativeTo now: Date) -> String {
        if event.isAllDay { return "All day" }
        if Calendar.current.isDate(event.start, inSameDayAs: now) {
            return timeFormatter.string(from: event.start)
        }
        return dayTimeFormatter.string(from: event.start)
    }

    static func rangeLabel(for event: CalendarActivity) -> String {
        guard !event.isAllDay else { return "All day" }
        return "\(timeFormatter.string(from: event.start)) – \(timeFormatter.string(from: event.end))"
    }
}
