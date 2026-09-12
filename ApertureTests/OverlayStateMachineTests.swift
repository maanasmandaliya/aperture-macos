//
//  OverlayStateMachineTests.swift
//  ApertureTests
//

import XCTest
@testable import Aperture

final class OverlayStateMachineTests: XCTestCase {

    func testAnActivityDoesNotEnlargeTheRestingOverlay() {
        // The whole point of the minimal state: something playing changes what
        // the slab *shows*, never how much room it takes.
        var machine = OverlayStateMachine()
        XCTAssertEqual(machine.presentation, .minimal)

        XCTAssertFalse(machine.apply(.activityChanged(true)))
        XCTAssertEqual(machine.presentation, .minimal)
    }

    func testPeekShowsTheWideStripThenRetires() {
        var machine = OverlayStateMachine(hasActivity: true)
        XCTAssertTrue(machine.apply(.peekBegan))
        XCTAssertEqual(machine.presentation, .compact)

        XCTAssertTrue(machine.apply(.peekEnded))
        XCTAssertEqual(machine.presentation, .minimal)
    }

    func testPeekIsIgnoredWithoutAnActivity() {
        var machine = OverlayStateMachine(hasActivity: false)
        XCTAssertFalse(machine.apply(.peekBegan))
        XCTAssertEqual(machine.presentation, .minimal)
    }

    func testPeekNeverDisplacesAHUD() {
        var machine = OverlayStateMachine(hasActivity: true)
        machine.apply(.hudBegan(.meter))
        XCTAssertFalse(machine.apply(.peekBegan), "A HUD the user is reading outranks a peek")
        XCTAssertEqual(machine.presentation, .hud(.meter))
    }

    func testPeekNeverDisplacesTheHub() {
        var machine = OverlayStateMachine(hasActivity: true)
        machine.apply(.expand(.schedule))
        XCTAssertFalse(machine.apply(.peekBegan))
        XCTAssertEqual(machine.presentation, .expanded(.schedule))
    }

    func testHUDOutranksAPeekInProgress() {
        var machine = OverlayStateMachine(hasActivity: true)
        machine.apply(.peekBegan)
        XCTAssertTrue(machine.apply(.hudBegan(.meter)))
        XCTAssertEqual(machine.presentation, .hud(.meter))

        machine.apply(.hudEnded)
        XCTAssertEqual(machine.presentation, .minimal, "The interrupted peek is not resumed")
    }

    func testLosingTheActivityRetiresAPeekEarly() {
        var machine = OverlayStateMachine(hasActivity: true)
        machine.apply(.peekBegan)
        XCTAssertTrue(machine.apply(.activityChanged(false)))
        XCTAssertEqual(machine.presentation, .minimal)
    }

    func testPauseHidesAndResumeRestores() {
        var machine = OverlayStateMachine(hasActivity: true)
        XCTAssertEqual(machine.presentation, .minimal)

        machine.apply(.pauseChanged(true))
        XCTAssertEqual(machine.presentation, .hidden)

        machine.apply(.pauseChanged(false))
        XCTAssertEqual(machine.presentation, .minimal, "Resuming returns to rest, not to the wide strip")
    }

    func testCannotExpandWhilePaused() {
        var machine = OverlayStateMachine(isPaused: true)
        XCTAssertFalse(machine.apply(.toggleExpanded))
        XCTAssertEqual(machine.presentation, .hidden)
    }

    func testCannotExpandWithoutAScreen() {
        var machine = OverlayStateMachine(hasScreen: false)
        XCTAssertEqual(machine.presentation, .hidden)
        XCTAssertFalse(machine.apply(.toggleExpanded))
        XCTAssertEqual(machine.presentation, .hidden)
    }

    func testToggleExpandsAndCollapses() {
        var machine = OverlayStateMachine()
        machine.apply(.toggleExpanded)
        XCTAssertEqual(machine.presentation, .expanded(.nowPlaying))

        machine.apply(.toggleExpanded)
        XCTAssertEqual(machine.presentation, .minimal)
    }

    func testExpandRemembersLastTab() {
        var machine = OverlayStateMachine()
        machine.apply(.expand(.schedule))
        XCTAssertEqual(machine.presentation, .expanded(.schedule))

        machine.apply(.collapse)
        machine.apply(.toggleExpanded)
        XCTAssertEqual(machine.presentation, .expanded(.schedule))
    }

    func testSelectTabWhileCollapsedOnlyRecordsPreference() {
        var machine = OverlayStateMachine()
        machine.apply(.selectTab(.controls))
        XCTAssertEqual(machine.presentation, .minimal)

        machine.apply(.toggleExpanded)
        XCTAssertEqual(machine.presentation, .expanded(.controls))
    }

    func testHUDInterruptsTheRestingState() {
        var machine = OverlayStateMachine(hasActivity: true)
        machine.apply(.hudBegan(.meter))
        XCTAssertEqual(machine.presentation, .hud(.meter))

        machine.apply(.hudEnded)
        XCTAssertEqual(machine.presentation, .minimal)
    }

    func testHUDNeverInterruptsTheHub() {
        var machine = OverlayStateMachine()
        machine.apply(.expand(.controls))
        XCTAssertFalse(machine.apply(.hudBegan(.meter)))
        XCTAssertEqual(machine.presentation, .expanded(.controls))
    }

    func testActivityChangeDoesNotCollapseTheHub() {
        var machine = OverlayStateMachine()
        machine.apply(.expand(.nowPlaying))
        XCTAssertFalse(machine.apply(.activityChanged(true)))
        XCTAssertEqual(machine.presentation, .expanded(.nowPlaying))
    }

    func testActivityChangeDoesNotTruncateAHUD() {
        var machine = OverlayStateMachine()
        machine.apply(.hudBegan(.meter))
        XCTAssertFalse(machine.apply(.activityChanged(true)))
        XCTAssertEqual(machine.presentation, .hud(.meter))

        machine.apply(.hudEnded)
        XCTAssertEqual(machine.presentation, .minimal)
    }

    func testPauseWhileExpandedHides() {
        var machine = OverlayStateMachine()
        machine.apply(.expand(.nowPlaying))
        machine.apply(.pauseChanged(true))
        XCTAssertEqual(machine.presentation, .hidden)
    }

    func testScreenLossHidesAndRecoveryRestores() {
        var machine = OverlayStateMachine(hasActivity: true)
        machine.apply(.screenAvailabilityChanged(false))
        XCTAssertEqual(machine.presentation, .hidden)

        machine.apply(.screenAvailabilityChanged(true))
        XCTAssertEqual(machine.presentation, .minimal)
    }

    func testApplyReportsWhetherPresentationMoved() {
        var machine = OverlayStateMachine(hasActivity: true)
        XCTAssertFalse(machine.apply(.activityChanged(true)), "No-op events must not report a change")
        XCTAssertTrue(machine.apply(.peekBegan))
    }

    func testTransientStatesAreLabelledAsSuch() {
        XCTAssertTrue(OverlayPresentation.compact.isTransient)
        XCTAssertTrue(OverlayPresentation.hud(.meter).isTransient)
        XCTAssertTrue(OverlayPresentation.hud(.message).isTransient)
        XCTAssertFalse(OverlayPresentation.minimal.isTransient)
        XCTAssertFalse(OverlayPresentation.expanded(.nowPlaying).isTransient)
    }

    func testCollapseWhileAlreadyCollapsedIsANoOp() {
        var machine = OverlayStateMachine()
        XCTAssertFalse(machine.apply(.collapse))
        XCTAssertEqual(machine.presentation, .minimal)
    }

    func testHUDEndedWithoutHUDIsANoOp() {
        var machine = OverlayStateMachine()
        XCTAssertFalse(machine.apply(.hudEnded))
        XCTAssertEqual(machine.presentation, .minimal)
    }

    func testInteractivityIsExclusiveToTheHub() {
        XCTAssertFalse(OverlayPresentation.minimal.isInteractive)
        XCTAssertFalse(OverlayPresentation.compact.isInteractive)
        XCTAssertFalse(OverlayPresentation.hud(.meter).isInteractive)
        XCTAssertTrue(OverlayPresentation.expanded(.schedule).isInteractive)
    }
}
