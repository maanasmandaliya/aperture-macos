//
//  HapticFeedbackTests.swift
//  ApertureTests
//

import XCTest
@testable import Aperture

final class HapticFeedbackTests: XCTestCase {

    func testTheFirstRequestAlwaysFires() {
        var throttle = HapticThrottle(minimumInterval: 0.25)

        XCTAssertTrue(throttle.shouldFire(at: 0))
    }

    /// The cursor sitting on the pill's edge flips hover back and forth; the
    /// trackpad must not buzz once per flip.
    func testEdgeChatterIsSwallowed() {
        var throttle = HapticThrottle(minimumInterval: 0.25)
        XCTAssertTrue(throttle.shouldFire(at: 10.0))

        for time in stride(from: 10.02, through: 10.24, by: 0.02) {
            XCTAssertFalse(throttle.shouldFire(at: time), "Chatter at \(time) should be silent")
        }
    }

    func testADeliberateReturnFiresAgain() {
        var throttle = HapticThrottle(minimumInterval: 0.25)
        XCTAssertTrue(throttle.shouldFire(at: 10.0))
        XCTAssertFalse(throttle.shouldFire(at: 10.1))

        XCTAssertTrue(throttle.shouldFire(at: 10.3), "A quarter-second later is a real re-entry")
    }

    /// A suppressed request must not push the window forward, or a steady
    /// stream of chatter would keep the trackpad silent indefinitely.
    func testSuppressedRequestsDoNotExtendTheWindow() {
        var throttle = HapticThrottle(minimumInterval: 0.25)
        XCTAssertTrue(throttle.shouldFire(at: 0))

        for time in stride(from: 0.05, to: 0.25, by: 0.05) {
            XCTAssertFalse(throttle.shouldFire(at: time))
        }
        XCTAssertTrue(throttle.shouldFire(at: 0.25))
    }
}
