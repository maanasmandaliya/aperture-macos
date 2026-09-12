//
//  ActivitySelectionTests.swift
//  ApertureTests
//

import XCTest
@testable import Aperture

final class ActivitySelectionTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 780_000_000)

    private func media(playing: Bool, pausedSecondsAgo: TimeInterval = 0) -> MediaSnapshot {
        MediaSnapshot(
            title: "Slow Meridian", artist: "Halden Cross", album: "Northlight",
            isPlaying: playing, duration: 214, elapsed: 30,
            sampledAt: now,
            lastTransportChange: now.addingTimeInterval(-pausedSecondsAgo),
            artworkData: nil, sourceName: "Demo"
        )
    }

    private func event(startingIn offset: TimeInterval, allDay: Bool = false, title: String = "Design review") -> CalendarActivity {
        CalendarActivity(
            id: title, title: title,
            start: now.addingTimeInterval(offset),
            end: now.addingTimeInterval(offset + 1800),
            isAllDay: allDay, location: nil,
            calendarTitle: "Work", calendarColor: .neutral
        )
    }

    private func timer(remaining: TimeInterval, paused: Bool = false) -> TimerActivity {
        TimerActivity(
            id: UUID(), title: "Steep tea", total: 300,
            fireDate: paused ? nil : now.addingTimeInterval(remaining),
            pausedRemaining: paused ? remaining : nil
        )
    }

    // MARK: - Priority order

    func testNothingActiveReturnsNil() {
        let result = ActivitySelector.select(ActivityInputs(now: now))
        XCTAssertNil(result)
    }

    func testCallOutranksEverythingElse() {
        let inputs = ActivityInputs(
            call: CallActivity(id: UUID(), title: "Standup", startedAt: now, isMuted: false),
            timer: timer(remaining: 120),
            media: media(playing: true),
            calendarEvents: [event(startingIn: 60)],
            now: now
        )
        XCTAssertEqual(ActivitySelector.select(inputs)?.kind, .call)
    }

    func testTimerOutranksMediaAndCalendar() {
        let inputs = ActivityInputs(
            timer: timer(remaining: 120),
            media: media(playing: true),
            calendarEvents: [event(startingIn: 60)],
            now: now
        )
        XCTAssertEqual(ActivitySelector.select(inputs)?.kind, .timer)
    }

    func testMediaOutranksCalendar() {
        let inputs = ActivityInputs(
            media: media(playing: true),
            calendarEvents: [event(startingIn: 60)],
            now: now
        )
        XCTAssertEqual(ActivitySelector.select(inputs)?.kind, .media)
    }

    func testCalendarWinsWhenNothingElseIsLive() {
        let inputs = ActivityInputs(calendarEvents: [event(startingIn: 60)], now: now)
        XCTAssertEqual(ActivitySelector.select(inputs)?.kind, .calendar)
    }

    // MARK: - Policy gating

    func testDisabledCategoryIsSkippedNotDemoted() {
        var policy = ActivityPolicy.default
        policy.mediaEnabled = false
        let inputs = ActivityInputs(
            media: media(playing: true),
            calendarEvents: [event(startingIn: 60)],
            now: now
        )
        XCTAssertEqual(ActivitySelector.select(inputs, policy: policy)?.kind, .calendar)
    }

    func testDisablingEverythingYieldsNil() {
        var policy = ActivityPolicy.default
        policy.mediaEnabled = false
        policy.calendarEnabled = false
        policy.timersEnabled = false
        let inputs = ActivityInputs(
            timer: timer(remaining: 60),
            media: media(playing: true),
            calendarEvents: [event(startingIn: 60)],
            now: now
        )
        XCTAssertNil(ActivitySelector.select(inputs, policy: policy))
    }

    func testCallIgnoresPolicyBecauseItIsNeverOptional() {
        var policy = ActivityPolicy.default
        policy.mediaEnabled = false
        policy.calendarEnabled = false
        policy.timersEnabled = false
        let inputs = ActivityInputs(
            call: CallActivity(id: UUID(), title: "Standup", startedAt: now, isMuted: false),
            now: now
        )
        XCTAssertEqual(ActivitySelector.select(inputs, policy: policy)?.kind, .call)
    }

    // MARK: - Media eligibility

    func testPausedMediaLingersThenYields() {
        let lingering = media(playing: false, pausedSecondsAgo: 10)
        XCTAssertTrue(ActivitySelector.isMediaEligible(lingering, at: now))

        let stale = media(playing: false, pausedSecondsAgo: 120)
        XCTAssertFalse(ActivitySelector.isMediaEligible(stale, at: now))
    }

    func testEmptyMediaIsNeverEligible() {
        XCTAssertFalse(ActivitySelector.isMediaEligible(.empty, at: now))
    }

    func testStaleMediaYieldsToCalendar() {
        let inputs = ActivityInputs(
            media: media(playing: false, pausedSecondsAgo: 300),
            calendarEvents: [event(startingIn: 60)],
            now: now
        )
        XCTAssertEqual(ActivitySelector.select(inputs)?.kind, .calendar)
    }

    // MARK: - Calendar imminence

    func testDistantEventIsNotImminent() {
        let inputs = ActivityInputs(calendarEvents: [event(startingIn: 3 * 3600)], now: now)
        XCTAssertNil(ActivitySelector.select(inputs))
    }

    func testUnderwayEventIsSelected() {
        let inputs = ActivityInputs(calendarEvents: [event(startingIn: -300)], now: now)
        XCTAssertEqual(ActivitySelector.select(inputs)?.kind, .calendar)
    }

    func testFinishedEventIsIgnored() {
        let finished = event(startingIn: -7200)
        let inputs = ActivityInputs(calendarEvents: [finished], now: now)
        XCTAssertNil(ActivitySelector.select(inputs))
    }

    func testAllDayEventNeverTakesThePill() {
        let inputs = ActivityInputs(calendarEvents: [event(startingIn: 60, allDay: true)], now: now)
        XCTAssertNil(ActivitySelector.select(inputs))
    }

    func testEarliestImminentEventWins() {
        let inputs = ActivityInputs(
            calendarEvents: [event(startingIn: 600, title: "Later"), event(startingIn: 120, title: "Sooner")],
            now: now
        )
        guard case .calendar(let selected)? = ActivitySelector.select(inputs) else {
            return XCTFail("Expected a calendar activity")
        }
        XCTAssertEqual(selected.title, "Sooner")
    }

    // MARK: - Timers

    func testPausedTimerStillHoldsThePill() {
        let inputs = ActivityInputs(timer: timer(remaining: 90, paused: true), media: media(playing: true), now: now)
        XCTAssertEqual(ActivitySelector.select(inputs)?.kind, .timer)
    }

    func testExpiredTimerYieldsToMedia() {
        let inputs = ActivityInputs(timer: timer(remaining: 0), media: media(playing: true), now: now)
        XCTAssertEqual(ActivitySelector.select(inputs)?.kind, .media)
    }
}
