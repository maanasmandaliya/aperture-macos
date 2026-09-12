//
//  BrightnessScaleTests.swift
//  ApertureTests
//
//  The numbers here are the ones actually read from this Mac's backlight:
//  `AppleARMBacklight`'s `IODisplayParameters` publishes brightness as
//  `{min: 0, max: 65536, value: …}`, and that value tracks the slider in
//  System Settings.
//

import XCTest
@testable import Aperture

final class BrightnessScaleTests: XCTestCase {

    /// The backlight's own scale.
    private let maximum = 65_536
    private let oneStep = 1.0 / 16

    // MARK: - Reading

    /// Measured together: the backlight read 32768 of 65536 while the system
    /// slider sat at half. The route this replaced reported 100% at that same
    /// moment, because it measured nits against a cap that moves with the
    /// ambient-light sensor.
    func testHalfBrightnessReadsAsHalf() {
        XCTAssertEqual(BrightnessController.fraction(level: 32_768, cap: maximum), 0.5, accuracy: 0.0001)
    }

    func testFullAndEmpty() {
        XCTAssertEqual(BrightnessController.fraction(level: maximum, cap: maximum), 1.0, accuracy: 0.0001)
        XCTAssertEqual(BrightnessController.fraction(level: 0, cap: maximum), 0.0, accuracy: 0.0001)
    }

    /// Defensive: nothing should report past the end of its own scale.
    func testAValueAboveTheMaximumIsClamped() {
        XCTAssertEqual(BrightnessController.fraction(level: maximum * 2, cap: maximum), 1.0, accuracy: 0.0001)
    }

    func testAnAbsentScaleReportsNothing() {
        XCTAssertEqual(BrightnessController.fraction(level: 32_768, cap: 0), 0)
        XCTAssertEqual(BrightnessController.fraction(level: 32_768, cap: -1), 0)
    }

    func testFractionsRoundTripThroughRawLevels() {
        for percent in stride(from: 0.0, through: 1.0, by: 0.05) {
            let raw = BrightnessController.rawLevel(fraction: percent, cap: maximum)
            XCTAssertEqual(BrightnessController.fraction(level: raw, cap: maximum), percent, accuracy: 0.0001,
                           "\(percent) did not survive the round trip")
        }
    }

    func testRawLevelsStayInRange() {
        XCTAssertEqual(BrightnessController.rawLevel(fraction: 2.0, cap: maximum), maximum)
        XCTAssertEqual(BrightnessController.rawLevel(fraction: -1.0, cap: maximum), 0)
    }

    // MARK: - Stepping with the keyboard

    func testAPressMovesOneSixteenthOfTheScale() {
        let start = BrightnessController.rawLevel(fraction: 0.5, cap: maximum)
        XCTAssertEqual(BrightnessController.stepped(raw: start, cap: maximum, by: -oneStep), start - maximum / 16)
        XCTAssertEqual(BrightnessController.stepped(raw: start, cap: maximum, by: oneStep), start + maximum / 16)
    }

    /// A ratchet here is indistinguishable, from the user's chair, from a
    /// screen that dims itself.
    func testSteppingDownAndBackUpReturnsToTheStart() {
        let start = BrightnessController.rawLevel(fraction: 0.5, cap: maximum)
        var raw = start
        for _ in 0..<3 { raw = BrightnessController.stepped(raw: raw, cap: maximum, by: -oneStep) }
        for _ in 0..<3 { raw = BrightnessController.stepped(raw: raw, cap: maximum, by: oneStep) }
        XCTAssertEqual(raw, start)
    }

    func testStepsStopAtTheTop() {
        let nearTop = BrightnessController.rawLevel(fraction: 0.98, cap: maximum)
        XCTAssertEqual(BrightnessController.stepped(raw: nearTop, cap: maximum, by: oneStep), maximum)
    }

    func testStepsStopAtTheFloor() {
        let nearFloor = BrightnessController.rawLevel(fraction: 0.06, cap: maximum)
        XCTAssertEqual(
            BrightnessController.stepped(raw: nearFloor, cap: maximum, by: -oneStep),
            BrightnessController.rawLevel(fraction: BrightnessController.minimumFraction, cap: maximum)
        )
    }

    /// HDR content drives the panel past its SDR maximum; a step *up* from
    /// there must never pull it down to that maximum.
    func testAnOverscaleValueIsNeverPulledDownByAStepUp() {
        let over = maximum * 2
        XCTAssertGreaterThanOrEqual(BrightnessController.stepped(raw: over, cap: maximum, by: oneStep), over)
    }

    func testAnAbsentScaleLeavesTheLevelAlone() {
        XCTAssertEqual(BrightnessController.stepped(raw: 123, cap: 0, by: oneStep), 123)
    }
}
