//
//  CalendarFilteringTests.swift
//  ApertureTests
//

import XCTest
@testable import Aperture

final class CalendarFilteringTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 780_000_000)

    private func event(
        _ title: String,
        startingIn offset: TimeInterval,
        duration: TimeInterval = 1800,
        allDay: Bool = false
    ) -> CalendarActivity {
        CalendarActivity(
            id: "\(title)-\(offset)",
            title: title,
            start: now.addingTimeInterval(offset),
            end: now.addingTimeInterval(offset + duration),
            isAllDay: allDay,
            location: nil,
            calendarTitle: "Work",
            calendarColor: .neutral
        )
    }

    func testFinishedEventsAreDropped() {
        let events = [event("Over", startingIn: -7200), event("Next", startingIn: 600)]
        let filtered = CalendarEventFilter.filter(events, at: now, limit: 10)
        XCTAssertEqual(filtered.map(\.title), ["Next"])
    }

    func testEventUnderwayIsKept() {
        let events = [event("Underway", startingIn: -600, duration: 3600)]
        XCTAssertEqual(CalendarEventFilter.filter(events, at: now, limit: 10).count, 1)
    }

    func testResultsAreSortedByStart() {
        let events = [
            event("Third", startingIn: 5400),
            event("First", startingIn: 300),
            event("Second", startingIn: 1800),
        ]
        let filtered = CalendarEventFilter.filter(events, at: now, limit: 10)
        XCTAssertEqual(filtered.map(\.title), ["First", "Second", "Third"])
    }

    func testTimedEventsSortAheadOfAllDayAtTheSameInstant() {
        let start: TimeInterval = 600
        let events = [
            event("All day", startingIn: start, allDay: true),
            event("Timed", startingIn: start),
        ]
        let filtered = CalendarEventFilter.filter(events, at: now, limit: 10)
        XCTAssertEqual(filtered.map(\.title), ["Timed", "All day"])
    }

    func testDuplicateRecurringInstancesAreCollapsed() {
        let events = [
            event("Standup", startingIn: 900),
            event("Standup", startingIn: 900),
        ]
        XCTAssertEqual(CalendarEventFilter.filter(events, at: now, limit: 10).count, 1)
    }

    func testUntitledEventsAreDropped() {
        var blank = event("Real", startingIn: 600)
        blank.title = "   "
        let filtered = CalendarEventFilter.filter([blank, event("Real", startingIn: 900)], at: now, limit: 10)
        XCTAssertEqual(filtered.map(\.title), ["Real"])
    }

    func testLimitIsRespected() {
        let events = (1...10).map { event("Event \($0)", startingIn: TimeInterval($0) * 600) }
        XCTAssertEqual(CalendarEventFilter.filter(events, at: now, limit: 3).count, 3)
    }

    func testEmptyInputProducesEmptyOutput() {
        XCTAssertTrue(CalendarEventFilter.filter([], at: now, limit: 5).isEmpty)
    }

    // MARK: - Imminence window

    func testImminentEventHonoursPolicyWindow() {
        var policy = ActivityPolicy.default
        policy.calendarImminentWindow = 5 * 60

        let events = [event("Soon", startingIn: 10 * 60)]
        XCTAssertNil(ActivitySelector.imminentEvent(in: events, at: now, policy: policy))

        policy.calendarImminentWindow = 15 * 60
        XCTAssertEqual(ActivitySelector.imminentEvent(in: events, at: now, policy: policy)?.title, "Soon")
    }

    func testImminentEventSkipsAllDayEntries() {
        let events = [event("All day", startingIn: 60, allDay: true), event("Timed", startingIn: 300)]
        XCTAssertEqual(ActivitySelector.imminentEvent(in: events, at: now)?.title, "Timed")
    }

    func testImminentEventPrefersUnderwayOverUpcoming() {
        let events = [event("Upcoming", startingIn: 120), event("Underway", startingIn: -120, duration: 3600)]
        XCTAssertEqual(ActivitySelector.imminentEvent(in: events, at: now)?.title, "Underway")
    }
}
