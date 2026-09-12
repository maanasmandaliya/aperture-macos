//
//  ScreenGeometryTests.swift
//  ApertureTests
//

import XCTest
@testable import Aperture

final class ScreenGeometryTests: XCTestCase {

    func testNotchedLayoutStraddlesTheHousing() {
        let layout = PreviewData.notchedScreen.layout(scale: 1)

        XCTAssertTrue(layout.hasNotch)
        XCTAssertGreaterThan(layout.pillSize.width, PreviewData.notchedScreen.notch.width,
                             "The pill must be wider than the housing so its wings are visible")
        XCTAssertEqual(layout.notchRect.width, PreviewData.notchedScreen.notch.width, accuracy: 0.001)
        XCTAssertEqual(layout.notchRect.midX, layout.pillSize.width / 2, accuracy: 0.001,
                       "The reserved housing must be centred in the pill")
        XCTAssertEqual(layout.pillSize.height, PreviewData.notchedScreen.notch.height, accuracy: 0.001,
                       "The idle slab must be exactly as tall as the housing, or it reads as a separate object")
    }

    func testPlainLayoutUsesTheDesignedPillSize() {
        let layout = PreviewData.plainScreen.layout(scale: 1)

        XCTAssertFalse(layout.hasNotch)
        XCTAssertEqual(layout.pillSize.width, Tokens.Size.pill.width, accuracy: 0.001)
        XCTAssertEqual(layout.pillSize.height, Tokens.Size.pill.height, accuracy: 0.001)
        XCTAssertEqual(layout.notchRect, .zero)
    }

    func testScaleMultipliesTheLayout() {
        let normal = PreviewData.plainScreen.layout(scale: 1)
        let large = PreviewData.plainScreen.layout(scale: 1.25)
        XCTAssertEqual(large.pillSize.width, normal.pillSize.width * 1.25, accuracy: 0.001)
        XCTAssertEqual(large.pillSize.height, normal.pillSize.height * 1.25, accuracy: 0.001)
    }

    func testScalingANotchedLayoutLeavesTheHousingUntouched() {
        // The camera housing is physical: wings scale, the reserved cut-out
        // must not — and neither may the slab's height, which has to keep
        // matching the housing exactly at every scale.
        let large = PreviewData.notchedScreen.layout(scale: 1.25)
        XCTAssertEqual(large.notchRect.width, PreviewData.notchedScreen.notch.width, accuracy: 0.001)
        XCTAssertEqual(large.pillSize.height, PreviewData.notchedScreen.notch.height, accuracy: 0.001)
        XCTAssertGreaterThan(large.pillSize.width, PreviewData.notchedScreen.layout(scale: 1).pillSize.width,
                             "Wings still scale with the user's overlay scale")
    }

    func testTopCenterIsAtTheTopEdge() {
        let geometry = PreviewData.plainScreen
        XCTAssertEqual(geometry.topCenter.x, geometry.frame.midX, accuracy: 0.001)
        XCTAssertEqual(geometry.topCenter.y, geometry.frame.maxY, accuracy: 0.001)
    }

    func testNotchMetricsPresenceThreshold() {
        XCTAssertFalse(NotchMetrics.none.isPresent)
        XCTAssertFalse(NotchMetrics(width: 0.5, height: 30).isPresent)
        XCTAssertTrue(NotchMetrics(width: 200, height: 37).isPresent)
    }
}
