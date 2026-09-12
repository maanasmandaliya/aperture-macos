//
//  Activities.swift
//  Aperture
//
//  Value types describing everything the overlay can surface. They are plain
//  `Sendable` structs so selection logic stays pure and unit-testable.
//

import Foundation

// MARK: - Kind & priority

/// Ordering used by ``ActivitySelector``. Higher raw value wins.
enum ActivityKind: Int, Comparable, CaseIterable, Sendable {
    case calendar = 1
    case media = 2
    case timer = 3
    case call = 4

    static func < (lhs: ActivityKind, rhs: ActivityKind) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var symbolName: String {
        switch self {
        case .calendar: "calendar"
        case .media: "waveform"
        case .timer: "timer"
        case .call: "phone.fill"
        }
    }

    var accessibilityNoun: String {
        switch self {
        case .calendar: "calendar event"
        case .media: "media playback"
        case .timer: "timer"
        case .call: "call"
        }
    }
}

// MARK: - Media

struct MediaSnapshot: Equatable, Sendable {
    var title: String
    var artist: String
    var album: String
    var isPlaying: Bool
    /// Total track length in seconds. `nil` when the source cannot report it.
    var duration: TimeInterval?
    /// Playhead position in seconds at ``sampledAt``.
    var elapsed: TimeInterval
    /// When `elapsed` was measured, so the UI can interpolate without polling.
    var sampledAt: Date
    /// Last time the *track or transport state* changed. Used to keep a
    /// just-paused track on screen briefly instead of snapping back to idle.
    var lastTransportChange: Date
    var artworkData: Data?
    /// Human-readable name of the app the snapshot came from.
    var sourceName: String
    /// Marked explicit by the source. Only sources that actually report it set
    /// this; it is never inferred from the title.
    var isExplicit: Bool = false
    /// Shuffle state, when the source exposes one.
    var isShuffled: Bool = false

    static let empty = MediaSnapshot(
        title: "", artist: "", album: "",
        isPlaying: false, duration: nil, elapsed: 0,
        sampledAt: .distantPast, lastTransportChange: .distantPast,
        artworkData: nil, sourceName: "", isExplicit: false, isShuffled: false
    )

    var hasTrack: Bool { !title.isEmpty }

    /// Stable identity of the loaded track.
    ///
    /// Everything that needs to notice "the track changed" — the header
    /// cross-fade, the artwork flip, the artwork cache — keys off this rather
    /// than re-deriving the same string, so they can never disagree about when
    /// a change happened.
    var identity: String { "\(title)|\(artist)|\(album)" }

    /// Playhead interpolated to `now` without asking the source again.
    func elapsed(at now: Date) -> TimeInterval {
        guard isPlaying else { return elapsed }
        let projected = elapsed + now.timeIntervalSince(sampledAt)
        if let duration { return min(projected, duration) }
        return max(projected, 0)
    }

    func progress(at now: Date) -> Double? {
        guard let duration, duration > 0 else { return nil }
        return min(max(elapsed(at: now) / duration, 0), 1)
    }

    /// Time left in the track, for the counting-down label beside the scrubber.
    func remaining(at now: Date) -> TimeInterval? {
        guard let duration else { return nil }
        return max(duration - elapsed(at: now), 0)
    }
}

// MARK: - Timer

struct TimerActivity: Equatable, Sendable, Identifiable {
    var id: UUID
    var title: String
    /// Total configured length.
    var total: TimeInterval
    /// When the timer will fire, if running.
    var fireDate: Date?
    /// Frozen remaining time while paused.
    var pausedRemaining: TimeInterval?

    var isPaused: Bool { pausedRemaining != nil }

    func remaining(at now: Date) -> TimeInterval {
        if let pausedRemaining { return max(pausedRemaining, 0) }
        guard let fireDate else { return 0 }
        return max(fireDate.timeIntervalSince(now), 0)
    }

    func progress(at now: Date) -> Double {
        guard total > 0 else { return 0 }
        return min(max(1 - remaining(at: now) / total, 0), 1)
    }

    func hasCompleted(at now: Date) -> Bool {
        !isPaused && remaining(at: now) <= 0
    }
}

// MARK: - Calendar

struct CalendarActivity: Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var location: String?
    var calendarTitle: String
    /// sRGB components of the owning calendar's colour.
    var calendarColor: RGBColor

    func countdown(at now: Date) -> TimeInterval { start.timeIntervalSince(now) }
    func isUnderway(at now: Date) -> Bool { now >= start && now < end }
    func hasEnded(at now: Date) -> Bool { now >= end }
}

/// Transport-friendly colour so models stay free of AppKit/SwiftUI.
struct RGBColor: Equatable, Sendable, Codable {
    var red: Double
    var green: Double
    var blue: Double

    static let neutral = RGBColor(red: 0.45, green: 0.48, blue: 0.55)
}

// MARK: - Call

struct CallActivity: Equatable, Sendable, Identifiable {
    var id: UUID
    /// Who or what the call is with.
    var title: String
    var startedAt: Date
    var isMuted: Bool

    func duration(at now: Date) -> TimeInterval { max(now.timeIntervalSince(startedAt), 0) }
}

// MARK: - Notification

/// Aperture's own notification model.
///
/// macOS exposes no public API for mirroring other apps' Notification Center
/// alerts, so this feed is app-owned: it carries demo events plus anything an
/// integrator pushes through ``NotificationFeed/publish(_:)``.
struct NotificationActivity: Equatable, Sendable, Identifiable {
    var id: UUID
    var sourceName: String
    var title: String
    var body: String
    var symbolName: String
    var date: Date
    var tint: RGBColor?
}

// MARK: - Unified activity

enum Activity: Equatable, Sendable {
    case call(CallActivity)
    case timer(TimerActivity)
    case media(MediaSnapshot)
    case calendar(CalendarActivity)

    var kind: ActivityKind {
        switch self {
        case .call: .call
        case .timer: .timer
        case .media: .media
        case .calendar: .calendar
        }
    }

    /// Short label used for the collapsed pill's activity glyph and VoiceOver.
    var summary: String {
        switch self {
        case .call(let call): call.title
        case .timer(let timer): timer.title
        case .media(let media): media.hasTrack ? media.title : "Nothing playing"
        case .calendar(let event): event.title
        }
    }
}
