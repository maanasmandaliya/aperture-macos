//
//  NotchSlabShapeTests.swift
//  ApertureTests
//

import SwiftUI
import XCTest
@testable import Aperture

final class NotchSlabShapeTests: XCTestCase {

    private let rect = CGRect(x: 0, y: 0, width: 300, height: 80)

    private func path(bottomRadius: CGFloat = 18, flare: CGFloat = 7, overhang: CGFloat = 8) -> Path {
        NotchSlabShape(bottomRadius: bottomRadius, flare: flare, topOverhang: overhang).path(in: rect)
    }

    func testShapeOvershootsTheTopEdge() {
        // The overshoot is what guarantees no sliver of desktop can appear
        // between the slab and the bezel.
        XCTAssertLessThanOrEqual(path().boundingRect.minY, rect.minY - 8 + 0.001)
    }

    func testShapeFlaresWiderThanItsFrameAtTheTop() {
        let bounds = path(flare: 7).boundingRect
        XCTAssertLessThanOrEqual(bounds.minX, rect.minX - 7 + 0.001)
        XCTAssertGreaterThanOrEqual(bounds.maxX, rect.maxX + 7 - 0.001)
    }

    func testShapeDoesNotExtendBelowItsFrame() {
        XCTAssertEqual(path().boundingRect.maxY, rect.maxY, accuracy: 0.001)
    }

    func testTopCornersAreSquareSoTheSlabNeverLooksDetached() {
        // A point just inside the top edge and inside the frame must be filled.
        // With a rounded top corner it would fall outside the path.
        XCTAssertTrue(path().contains(CGPoint(x: rect.minX + 0.5, y: rect.minY - 1)))
        XCTAssertTrue(path().contains(CGPoint(x: rect.maxX - 0.5, y: rect.minY - 1)))
    }

    func testBottomCornersAreRounded() {
        let radius: CGFloat = 18
        let p = path(bottomRadius: radius)
        // The extreme bottom corner is cut away...
        XCTAssertFalse(p.contains(CGPoint(x: rect.minX + 0.5, y: rect.maxY - 0.5)))
        XCTAssertFalse(p.contains(CGPoint(x: rect.maxX - 0.5, y: rect.maxY - 0.5)))
        // ...while the middle of the bottom edge is not.
        XCTAssertTrue(p.contains(CGPoint(x: rect.midX, y: rect.maxY - 0.5)))
    }

    func testZeroFlareAndRadiusStillProducesAClosedShape() {
        let p = path(bottomRadius: 0, flare: 0)
        XCTAssertFalse(p.isEmpty)
        XCTAssertTrue(p.contains(CGPoint(x: rect.minX + 0.5, y: rect.maxY - 0.5)))
    }

    func testOversizedRadiusIsClampedRatherThanInverted() {
        // A hand-edited scale could ask for a radius larger than the slab.
        let p = path(bottomRadius: 10_000, flare: 0)
        XCTAssertFalse(p.isEmpty)
        XCTAssertEqual(p.boundingRect.maxY, rect.maxY, accuracy: 0.001)
        XCTAssertTrue(p.contains(CGPoint(x: rect.midX, y: rect.maxY - 0.5)))
    }

    func testAnimatableDataRoundTrips() {
        var shape = NotchSlabShape(bottomRadius: 12, flare: 6)
        shape.animatableData = AnimatablePair(24, 9)
        XCTAssertEqual(shape.bottomRadius, 24, accuracy: 0.001)
        XCTAssertEqual(shape.flare, 9, accuracy: 0.001)
    }
}
