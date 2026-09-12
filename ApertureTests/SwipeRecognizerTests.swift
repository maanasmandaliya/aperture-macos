//
//  SwipeRecognizerTests.swift
//  ApertureTests
//

import XCTest
@testable import Aperture

final class SwipeRecognizerTests: XCTestCase {

    private func recogniser(threshold: CGFloat = 18) -> SwipeRecognizer {
        SwipeRecognizer(threshold: threshold)
    }

    /// A trackpad gesture: a start, some travel, then a lift.
    private func trackpad(
        _ delta: CGFloat, at time: TimeInterval,
        right: CGFloat = 0, start: Bool = false, end: Bool = false
    ) -> ScrollSample {
        ScrollSample(fingerDownDelta: delta, fingerRightDelta: right,
                     isGestureStart: start, isGestureEnd: end,
                     isMomentum: false, hasPhase: true, timestamp: time)
    }

    /// A purely sideways gesture.
    private func sideways(_ right: CGFloat, at time: TimeInterval, start: Bool = false) -> ScrollSample {
        ScrollSample(fingerDownDelta: 0, fingerRightDelta: right,
                     isGestureStart: start, hasPhase: true, timestamp: time)
    }

    private func momentum(_ delta: CGFloat, at time: TimeInterval) -> ScrollSample {
        ScrollSample(fingerDownDelta: delta, isMomentum: true, hasPhase: true, timestamp: time)
    }

    /// A wheel mouse: coarse deltas and no phase information at all.
    private func wheel(_ delta: CGFloat, at time: TimeInterval) -> ScrollSample {
        ScrollSample(fingerDownDelta: delta, hasPhase: false, timestamp: time)
    }

    // MARK: - Threshold

    func testTravelBelowTheThresholdDoesNothing() {
        var swipe = recogniser()
        XCTAssertEqual(swipe.consume(trackpad(6, at: 0, start: true)), .none)
        XCTAssertEqual(swipe.consume(trackpad(6, at: 0.02)), .none)
        XCTAssertEqual(swipe.consume(trackpad(5, at: 0.04)), .none)
    }

    func testCrossingTheThresholdReportsADownwardSwipe() {
        var swipe = recogniser()
        XCTAssertEqual(swipe.consume(trackpad(10, at: 0, start: true)), .none)
        XCTAssertEqual(swipe.consume(trackpad(10, at: 0.02)), .swipedDown)
    }

    func testUpwardTravelReportsAnUpwardSwipe() {
        var swipe = recogniser()
        XCTAssertEqual(swipe.consume(trackpad(-10, at: 0, start: true)), .none)
        XCTAssertEqual(swipe.consume(trackpad(-10, at: 0.02)), .swipedUp)
    }

    func testASingleLargeEventIsEnough() {
        var swipe = recogniser()
        XCTAssertEqual(swipe.consume(trackpad(40, at: 0, start: true)), .swipedDown)
    }

    // MARK: - One action per gesture

    func testALongFlickFiresOnlyOnce() {
        // The whole reason the threshold can be low: without latching, this
        // would page through every pane in one gesture.
        var swipe = recogniser()
        _ = swipe.consume(trackpad(20, at: 0, start: true))
        for step in 1...20 {
            XCTAssertEqual(swipe.consume(trackpad(20, at: Double(step) * 0.02)), .none)
        }
    }

    func testANewGestureCanFireAgain() {
        var swipe = recogniser()
        XCTAssertEqual(swipe.consume(trackpad(20, at: 0, start: true)), .swipedDown)
        XCTAssertEqual(swipe.consume(trackpad(0, at: 0.1, end: true)), .none)
        XCTAssertEqual(swipe.consume(trackpad(20, at: 0.2, start: true)), .swipedDown)
    }

    func testTravelResetsBetweenGestures() {
        var swipe = recogniser()
        _ = swipe.consume(trackpad(12, at: 0, start: true))
        _ = swipe.consume(trackpad(0, at: 0.05, end: true))
        // The 12 points from the abandoned gesture must not carry over.
        XCTAssertEqual(swipe.consume(trackpad(12, at: 0.1, start: true)), .none)
    }

    // MARK: - Momentum

    func testMomentumIsIgnoredEntirely() {
        var swipe = recogniser()
        XCTAssertEqual(swipe.consume(momentum(60, at: 0)), .none)
        XCTAssertEqual(swipe.consume(momentum(60, at: 0.02)), .none)
    }

    func testMomentumAfterAFlickCannotPageAgain() {
        var swipe = recogniser()
        XCTAssertEqual(swipe.consume(trackpad(20, at: 0, start: true)), .swipedDown)
        XCTAssertEqual(swipe.consume(trackpad(0, at: 0.1, end: true)), .none)
        for step in 1...15 {
            XCTAssertEqual(swipe.consume(momentum(30, at: 0.1 + Double(step) * 0.02)), .none)
        }
    }

    // MARK: - Wheel mice

    func testWheelEventsAccumulateWithinTheIdleGap() {
        var swipe = recogniser()
        XCTAssertEqual(swipe.consume(wheel(10, at: 0)), .none)
        XCTAssertEqual(swipe.consume(wheel(10, at: 0.05)), .swipedDown)
    }

    func testAPauseStartsAFreshWheelGesture() {
        var swipe = recogniser(threshold: 18)
        XCTAssertEqual(swipe.consume(wheel(10, at: 0)), .none)
        // Longer than the gap: the earlier 10 points are forgotten.
        XCTAssertEqual(swipe.consume(wheel(10, at: 5.0)), .none)
        XCTAssertEqual(swipe.consume(wheel(10, at: 5.05)), .swipedDown)
    }

    func testWheelCanFireAgainAfterAPause() {
        var swipe = recogniser()
        XCTAssertEqual(swipe.consume(wheel(20, at: 0)), .swipedDown)
        XCTAssertEqual(swipe.consume(wheel(20, at: 0.05)), .none, "Same gesture, already fired")
        XCTAssertEqual(swipe.consume(wheel(20, at: 1.0)), .swipedDown, "New gesture after the gap")
    }

    // MARK: - Horizontal

    func testSwipingLeftIsReported() {
        var swipe = recogniser()
        XCTAssertEqual(swipe.consume(sideways(-10, at: 0, start: true)), .none)
        XCTAssertEqual(swipe.consume(sideways(-10, at: 0.02)), .swipedLeft)
    }

    func testSwipingRightIsReported() {
        var swipe = recogniser()
        XCTAssertEqual(swipe.consume(sideways(20, at: 0, start: true)), .swipedRight)
    }

    func testHorizontalAlsoFiresOnlyOncePerGesture() {
        var swipe = recogniser()
        XCTAssertEqual(swipe.consume(sideways(20, at: 0, start: true)), .swipedRight)
        for step in 1...15 {
            XCTAssertEqual(swipe.consume(sideways(20, at: Double(step) * 0.02)), .none)
        }
    }

    // MARK: - Dominant axis

    func testAMostlyVerticalSwipeIsVertical() {
        // Real swipes drift. A page gesture with a little sideways slop must not
        // also skip a track.
        var swipe = recogniser()
        XCTAssertEqual(swipe.consume(trackpad(20, at: 0, right: 6, start: true)), .swipedDown)
    }

    func testAMostlyHorizontalSwipeIsHorizontal() {
        var swipe = recogniser()
        XCTAssertEqual(swipe.consume(trackpad(6, at: 0, right: -20, start: true)), .swipedLeft)
    }

    func testADiagonalSwipeCommitsToOneAxisOnly() {
        // Both axes cross the threshold in the same event; exactly one outcome
        // may come out, and the latch must block the other.
        var swipe = recogniser()
        let first = swipe.consume(trackpad(25, at: 0, right: 22, start: true))
        XCTAssertEqual(first, .swipedDown, "Vertical travelled further")
        XCTAssertEqual(swipe.consume(trackpad(25, at: 0.02, right: 22)), .none)
    }

    func testAxisIsDecidedByTotalTravelNotTheLastEvent() {
        var swipe = recogniser()
        XCTAssertEqual(swipe.consume(trackpad(12, at: 0, right: 0, start: true)), .none)
        // This event is sideways, but the gesture overall is still vertical.
        XCTAssertEqual(swipe.consume(trackpad(8, at: 0.02, right: 9)), .swipedDown)
    }

    func testHorizontalTravelDoesNotContributeToAVerticalSwipe() {
        var swipe = recogniser()
        // 12 points down and 12 right: neither axis reaches 18 on its own.
        XCTAssertEqual(swipe.consume(trackpad(12, at: 0, right: 12, start: true)), .none)
    }

    func testAxisTravelResetsBetweenGestures() {
        var swipe = recogniser()
        _ = swipe.consume(sideways(12, at: 0, start: true))
        _ = swipe.consume(trackpad(0, at: 0.05, end: true))
        XCTAssertEqual(swipe.consume(sideways(12, at: 0.1, start: true)), .none)
    }

    // MARK: - Reset

    func testResetClearsPendingTravel() {
        var swipe = recogniser()
        _ = swipe.consume(trackpad(12, at: 0, start: true))
        swipe.reset()
        XCTAssertEqual(swipe.consume(trackpad(12, at: 0.02)), .none)
    }

    func testDirectionReversalWithinAGestureNeedsFullTravel() {
        var swipe = recogniser()
        _ = swipe.consume(trackpad(12, at: 0, start: true))
        // Reversing cancels the accumulated downward travel rather than
        // instantly counting as an upward swipe.
        XCTAssertEqual(swipe.consume(trackpad(-12, at: 0.02)), .none)
        XCTAssertEqual(swipe.consume(trackpad(-18, at: 0.04)), .swipedUp)
    }
}
