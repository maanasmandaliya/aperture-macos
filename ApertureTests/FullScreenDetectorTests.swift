//
//  FullScreenDetectorTests.swift
//  ApertureTests
//
//  The rectangles here are the ones actually measured on a 14" MacBook Pro
//  (1728×1117, 33 pt menu bar) in each state, not invented shapes.
//

import XCTest
@testable import Aperture

final class FullScreenDetectorTests: XCTestCase {

    private let display = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    private let menuBar: CGFloat = 33

    private var desktop: WindowSample {
        WindowSample(layer: FullScreenDetector.desktopLayer, bounds: display)
    }

    private func normal(_ rect: CGRect) -> WindowSample {
        WindowSample(layer: Int(CGWindowLevelForKey(.normalWindow)), bounds: rect)
    }

    private func isFullScreen(_ windows: [WindowSample]) -> Bool {
        FullScreenDetector.isFullScreen(display: display, windows: windows, menuBarHeight: menuBar)
    }

    /// A full-screen app: its window sits below the menu bar and the Space has
    /// no desktop behind it.
    func testFullScreenSpaceIsDetected() {
        XCTAssertTrue(isFullScreen([normal(CGRect(x: 0, y: 33, width: 1728, height: 1084))]))
    }

    /// The case that makes geometry alone useless: a zoomed window has exactly
    /// the same bounds as a full-screen one, and is only told apart by the
    /// desktop still being there.
    func testZoomedWindowIsNotFullScreen() {
        XCTAssertFalse(isFullScreen([
            desktop,
            normal(CGRect(x: 0, y: 33, width: 1728, height: 1084)),
        ]))
    }

    /// Some apps take the whole display, notch strip included.
    func testWindowCoveringTheEntireDisplayCounts() {
        XCTAssertTrue(isFullScreen([normal(display)]))
        XCTAssertFalse(isFullScreen([desktop, normal(display)]))
    }

    /// An empty desktop Space: no covering window, so nothing is full screen
    /// even though the desktop check alone would be inconclusive.
    func testDesktopWithNoWindowsIsNotFullScreen() {
        XCTAssertFalse(isFullScreen([desktop]))
        XCTAssertFalse(isFullScreen([]))
    }

    /// The safety net: with the desktop window absent for any reason, a
    /// covering window is still required before anything is suppressed.
    func testMissingDesktopAloneIsNotEnough() {
        XCTAssertFalse(isFullScreen([normal(CGRect(x: 100, y: 200, width: 800, height: 500))]))
    }

    /// Nearly-covering windows must not count — a window one row short of the
    /// bottom is just a big window.
    func testWindowThatDoesNotReachTheEdgesIsNotFullScreen() {
        XCTAssertFalse(isFullScreen([normal(CGRect(x: 0, y: 33, width: 1728, height: 1000))]))
        XCTAssertFalse(isFullScreen([normal(CGRect(x: 0, y: 33, width: 1600, height: 1084))]))
        // Starting well below the menu bar is not a full-screen window either.
        XCTAssertFalse(isFullScreen([normal(CGRect(x: 0, y: 120, width: 1728, height: 997))]))
    }

    /// Half-pixel rounding on scaled displays must not flip the answer.
    func testSubPixelSlackIsTolerated() {
        XCTAssertTrue(isFullScreen([normal(CGRect(x: 0.5, y: 33.5, width: 1727.5, height: 1083.5))]))
    }

    /// A second display's windows must not decide this display's answer.
    func testWindowsOnAnotherDisplayAreIgnored() {
        let secondary = CGRect(x: 1728, y: 0, width: 1920, height: 1080)
        XCTAssertFalse(isFullScreen([normal(secondary)]))

        let onSecondary = FullScreenDetector.isFullScreen(
            display: secondary,
            windows: [desktop, normal(secondary)],
            menuBarHeight: 0
        )
        XCTAssertTrue(onSecondary, "The desktop window belongs to the other display")
    }

    /// A display with the menu bar hidden has no top inset to allow for.
    func testAutoHiddenMenuBarStillDetects() {
        let windows = [normal(display)]
        XCTAssertTrue(FullScreenDetector.isFullScreen(display: display, windows: windows, menuBarHeight: 0))
    }

    // MARK: - What suppression does to each presentation

    /// The point of the setting: the hub still opens on request while
    /// everything automatic is withheld.
    func testTheHubSurvivesSuppression() {
        let hub = OverlayPresentation.expanded(.nowPlaying)
        XCTAssertEqual(OverlayManager.suppressing(hub, isSuppressed: true), hub)
    }

    func testEverythingAutomaticIsWithheld() {
        // A finished timer and a notification arrive on Aperture's initiative,
        // so they wait.
        for base in [OverlayPresentation.minimal, .compact, .hud(.message)] {
            XCTAssertEqual(OverlayManager.suppressing(base, isSuppressed: true), .hidden,
                           "\(base) should not appear over a full-screen app")
        }
    }

    /// Pressing a volume or brightness key is a direct request for feedback.
    /// Withholding it leaves nothing on screen at all, because Aperture may
    /// also be suppressing the system's own panel.
    func testTheVolumeAndBrightnessReadoutSurvives() {
        XCTAssertEqual(OverlayManager.suppressing(.hud(.meter), isSuppressed: true), .hud(.meter))
    }

    func testNothingChangesWhenNotSuppressed() {
        for base in [OverlayPresentation.hidden, .minimal, .compact, .expanded(.controls)] {
            XCTAssertEqual(OverlayManager.suppressing(base, isSuppressed: false), base)
        }
    }

    func testEmptyDisplayIsNeverFullScreen() {
        XCTAssertFalse(FullScreenDetector.isFullScreen(display: .zero, windows: [normal(display)], menuBarHeight: 0))
    }
}
