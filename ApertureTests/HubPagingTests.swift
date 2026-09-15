//
//  HubPagingTests.swift
//  ApertureTests
//

import XCTest
@testable import Aperture

/// The hub has no tab bar: panes are a vertical stack paged by swiping. These
/// lock in the rules that gesture depends on.
final class HubPagingTests: XCTestCase {

    func testPanesAreOrderedNowPlayingScheduleMirrorControls() {
        XCTAssertEqual(HubTab.allCases, [.nowPlaying, .schedule, .mirror, .controls])
        XCTAssertEqual(HubTab.nowPlaying.depth, 0)
        XCTAssertEqual(HubTab.schedule.depth, 1)
        XCTAssertEqual(HubTab.mirror.depth, 2)
        XCTAssertEqual(HubTab.controls.depth, 3)
    }

    func testSwipingDownGoesDeeper() {
        XCTAssertEqual(HubTab.nowPlaying.deeper, .schedule)
        XCTAssertEqual(HubTab.schedule.deeper, .mirror)
        XCTAssertEqual(HubTab.mirror.deeper, .controls)
    }

    func testSwipingUpComesBack() {
        XCTAssertEqual(HubTab.controls.shallower, .mirror)
        XCTAssertEqual(HubTab.mirror.shallower, .schedule)
        XCTAssertEqual(HubTab.schedule.shallower, .nowPlaying)
    }

    func testThereIsNothingBelowTheLastPane() {
        // Deliberately not wrapping: wrapping would make it impossible to tell
        // where you are in the stack without looking.
        XCTAssertNil(HubTab.controls.deeper)
    }

    func testNothingAboveTheFirstPaneIsTheCloseSignal() {
        // The manager reads this `nil` as "collapse", which is what makes one
        // gesture cover open, page and close.
        XCTAssertNil(HubTab.nowPlaying.shallower)
    }

    func testPagingIsReversible() {
        for tab in HubTab.allCases {
            if let deeper = tab.deeper {
                XCTAssertEqual(deeper.shallower, tab)
            }
            if let shallower = tab.shallower {
                XCTAssertEqual(shallower.deeper, tab)
            }
        }
    }

    func testDepthIsMonotonicWithPaging() {
        for tab in HubTab.allCases {
            if let deeper = tab.deeper { XCTAssertEqual(deeper.depth, tab.depth + 1) }
            if let shallower = tab.shallower { XCTAssertEqual(shallower.depth, tab.depth - 1) }
        }
    }

    // MARK: - Sizing follows the pane

    func testEveryPaneHasARenderableHeight() {
        let metrics = OverlayMetrics(layout: PreviewData.notchedScreen.layout(scale: 1), scale: 1)
        for tab in HubTab.allCases {
            let size = metrics.hubSize(for: tab)
            XCTAssertGreaterThan(size.height, 120, "\(tab.title) needs room for its content")
            XCTAssertEqual(size.width, Tokens.Size.hub.width, accuracy: 0.001)
        }
    }

    func testTheStateMachineRemembersTheDeepestPaneVisited() {
        var machine = OverlayStateMachine()
        machine.apply(.expand(.nowPlaying))
        machine.apply(.selectTab(.controls))
        XCTAssertEqual(machine.presentation, .expanded(.controls))

        machine.apply(.collapse)
        machine.apply(.toggleExpanded)
        XCTAssertEqual(machine.presentation, .expanded(.controls),
                       "Reopening returns to the pane the user left")
    }
}
