//
//  ActivitySelector.swift
//  Aperture
//
//  Pure, synchronous priority resolution. Kept free of AppKit and of any
//  reference type so it can be exercised directly from unit tests.
//

import Foundation

/// Everything the selector may consider, sampled at a single instant.
struct ActivityInputs: Sendable {
    var call: CallActivity?
    var timer: TimerActivity?
    var media: MediaSnapshot
    /// Upcoming events, expected in ascending start order.
    var calendarEvents: [CalendarActivity]
    var now: Date

    init(
        call: CallActivity? = nil,
        timer: TimerActivity? = nil,
        media: MediaSnapshot = .empty,
        calendarEvents: [CalendarActivity] = [],
        now: Date = Date()
    ) {
        self.call = call
        self.timer = timer
        self.media = media
        self.calendarEvents = calendarEvents
        self.now = now
    }
}

/// User-tunable rules layered on top of the fixed priority order.
struct ActivityPolicy: Sendable, Equatable {
    var mediaEnabled: Bool = true
    var calendarEnabled: Bool = true
    var timersEnabled: Bool = true
    /// How long a paused track stays on the pill before yielding.
    var mediaLinger: TimeInterval = 45
    /// How far ahead an event must be to count as "imminent".
    var calendarImminentWindow: TimeInterval = 15 * 60

    static let `default` = ActivityPolicy()
}

enum ActivitySelector {

    /// Resolves the single activity the overlay should present.
    ///
    /// Fixed order: active call ▸ timer ▸ media ▸ imminent calendar event.
    /// Anything the user disabled in Settings is skipped entirely rather than
    /// demoted, so turning Media off never lets a stale track outrank an event.
    static func select(_ inputs: ActivityInputs, policy: ActivityPolicy = .default) -> Activity? {
        if let call = inputs.call {
            return .call(call)
        }

        if policy.timersEnabled,
           let timer = inputs.timer,
           timer.isPaused || timer.remaining(at: inputs.now) > 0 {
            return .timer(timer)
        }

        if policy.mediaEnabled, isMediaEligible(inputs.media, at: inputs.now, policy: policy) {
            return .media(inputs.media)
        }

        if policy.calendarEnabled,
           let event = imminentEvent(in: inputs.calendarEvents, at: inputs.now, policy: policy) {
            return .calendar(event)
        }

        return nil
    }

    /// Media stays eligible while playing, and for `mediaLinger` seconds after
    /// a pause so a quick pause/resume does not make the pill flicker.
    static func isMediaEligible(_ media: MediaSnapshot, at now: Date, policy: ActivityPolicy = .default) -> Bool {
        guard media.hasTrack else { return false }
        if media.isPlaying { return true }
        return now.timeIntervalSince(media.lastTransportChange) < policy.mediaLinger
    }

    /// First event that is either already underway or starting inside the
    /// imminence window. All-day events never take the pill — they have no
    /// meaningful countdown — but they still appear in the Schedule tab.
    static func imminentEvent(
        in events: [CalendarActivity],
        at now: Date,
        policy: ActivityPolicy = .default
    ) -> CalendarActivity? {
        events
            .filter { !$0.isAllDay && !$0.hasEnded(at: now) }
            .sorted { $0.start < $1.start }
            .first { $0.isUnderway(at: now) || $0.countdown(at: now) <= policy.calendarImminentWindow }
    }
}
