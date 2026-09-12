//
//  CalendarAccessTests.swift
//  ApertureTests
//

import XCTest
@testable import Aperture

/// Rules governing when the system permission panel may be raised.
///
/// These exist because of a bug that shipped: preference observation is broad,
/// so an unrelated change (accent, overlay scale) re-ran the calendar setup, and
/// EventKit keeps reporting `.notDetermined` until the user answers — so every
/// caller that arrived while the panel was on screen raised another one.
final class CalendarAccessTests: XCTestCase {

    func testAsksOnlyWhenAccessHasNeverBeenRequested() {
        XCTAssertTrue(
            CalendarService.shouldRequestAccess(
                current: .notRequested, hasAskedThisLaunch: false, promptAllowed: true
            )
        )
    }

    func testLaunchNeverPrompts() {
        // An ad-hoc-signed build gets a new identity on every rebuild, so macOS
        // forgets the grant and the state legitimately reads `.notRequested`
        // again. Launching must still not put a panel on screen unbidden — the
        // Schedule pane explains it and offers a button instead.
        XCTAssertFalse(
            CalendarService.shouldRequestAccess(
                current: .notRequested, hasAskedThisLaunch: false, promptAllowed: false
            )
        )
    }

    func testDoesNotAskTwiceInOneLaunch() {
        // Dismissing the panel without choosing leaves the status
        // `.notDetermined`; without this guard the next preference change would
        // put it straight back up.
        XCTAssertFalse(
            CalendarService.shouldRequestAccess(
                current: .notRequested, hasAskedThisLaunch: true, promptAllowed: true
            )
        )
    }

    func testNeverAsksOnceAnAnswerExists() {
        for state: CalendarService.Access in [.authorized, .denied, .restricted, .writeOnly] {
            XCTAssertFalse(
                CalendarService.shouldRequestAccess(
                    current: state, hasAskedThisLaunch: false, promptAllowed: true
                ),
                "\(state) is already an answer; re-asking is pointless and macOS would not show a panel anyway"
            )
            XCTAssertFalse(
                CalendarService.shouldRequestAccess(
                    current: state, hasAskedThisLaunch: true, promptAllowed: true
                )
            )
        }
    }

    func testOnlyFullAccessCanReadEvents() {
        XCTAssertTrue(CalendarService.Access.authorized.isReadable)
        for state: CalendarService.Access in [.notRequested, .denied, .restricted, .writeOnly] {
            XCTAssertFalse(state.isReadable, "\(state) must not be treated as readable")
        }
    }

    func testEveryAccessStateExplainsItself() {
        for state: CalendarService.Access in [.notRequested, .authorized, .denied, .restricted, .writeOnly] {
            XCTAssertFalse(state.statusText.isEmpty)
        }
    }

    @MainActor
    func testRetryReArmsThePrompt() {
        let service = CalendarService()
        service.allowRetryingAccess()
        // The guard is per-launch and only an explicit user action clears it,
        // which is what the Settings button does.
        XCTAssertTrue(
            CalendarService.shouldRequestAccess(
                current: .notRequested, hasAskedThisLaunch: false, promptAllowed: true
            )
        )
    }
}
