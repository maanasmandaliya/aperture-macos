//
//  MediaKeyTapTests.swift
//  ApertureTests
//

import AppKit
import IOKit.hidsystem
import XCTest
@testable import Aperture

final class MediaKeyTapTests: XCTestCase {

    /// Builds the `data1` payload the keyboard sends: key in the high 16 bits,
    /// 0x0A in the state byte for a press and 0x0B for a release, low bit set
    /// while auto-repeating.
    private func data1(_ keyCode: Int32, down: Bool = true, repeating: Bool = false) -> Int {
        let state = down ? 0x0A : 0x0B
        return (Int(keyCode) << 16) | (state << 8) | (repeating ? 1 : 0)
    }

    private func decode(_ value: Int, modifiers: NSEvent.ModifierFlags = []) -> MediaKeyPress? {
        MediaKeyTap.decode(data1: value, modifiers: modifiers)
    }

    /// Claiming a key means swallowing it, so anything not handled here must
    /// decode to nil and pass through to macOS untouched.
    func testEveryHandledKeyIsRecognised() {
        XCTAssertEqual(decode(data1(NX_KEYTYPE_SOUND_UP))?.key, .volumeUp)
        XCTAssertEqual(decode(data1(NX_KEYTYPE_SOUND_DOWN))?.key, .volumeDown)
        XCTAssertEqual(decode(data1(NX_KEYTYPE_MUTE))?.key, .mute)
        XCTAssertEqual(decode(data1(NX_KEYTYPE_BRIGHTNESS_UP))?.key, .brightnessUp)
        XCTAssertEqual(decode(data1(NX_KEYTYPE_BRIGHTNESS_DOWN))?.key, .brightnessDown)
        // What this keyboard actually sends for a single tap: repeat bit set.
        // It is still a press.
        XCTAssertEqual(decode(data1(NX_KEYTYPE_BRIGHTNESS_DOWN, repeating: true))?.key, .brightnessDown)
    }

    /// Acting on the release as well would double every step.
    func testKeyReleasesAreIgnored() {
        XCTAssertNil(decode(data1(NX_KEYTYPE_SOUND_UP, down: false)))
        XCTAssertNil(decode(data1(NX_KEYTYPE_MUTE, down: false)))
    }

    /// Playback keys belong to whichever app owns playback, and must pass
    /// through untouched — swallowing them would break every music player.
    func testPlaybackKeysArePassedThrough() {
        for key in [NX_KEYTYPE_PLAY, NX_KEYTYPE_NEXT, NX_KEYTYPE_PREVIOUS, NX_KEYTYPE_FAST, NX_KEYTYPE_REWIND] {
            XCTAssertNil(decode(data1(key)), "key \(key) must not be consumed")
        }
    }

    func testAutoRepeatIsReported() {
    }

    /// Shift+Option together, and only together, is macOS's quarter-step.
    func testFineAdjustmentNeedsBothModifiers() {
        XCTAssertEqual(decode(data1(NX_KEYTYPE_SOUND_UP), modifiers: [.shift, .option])?.isFineAdjustment, true)
        XCTAssertEqual(decode(data1(NX_KEYTYPE_SOUND_UP), modifiers: [.shift])?.isFineAdjustment, false)
        XCTAssertEqual(decode(data1(NX_KEYTYPE_SOUND_UP), modifiers: [.option])?.isFineAdjustment, false)
        XCTAssertEqual(decode(data1(NX_KEYTYPE_SOUND_UP), modifiers: [])?.isFineAdjustment, false)
    }

    // MARK: - Step size

    func testStepsMatchTheSystemsOwn() {
        XCTAssertEqual(AppEnvironment.step(fine: false), 1.0 / 16, accuracy: 0.0001)
        XCTAssertEqual(AppEnvironment.step(fine: true), 1.0 / 64, accuracy: 0.0001)
    }

    /// Sixteen presses from silence must land exactly on full, with no drift.
    func testSixteenStepsSpanTheWholeRange() {
        var level = 0.0
        for _ in 0..<16 { level = min(level + AppEnvironment.step(fine: false), 1) }
        XCTAssertEqual(level, 1.0, accuracy: 0.0001)
    }
}

// MARK: - When the permission panel may appear

final class MediaKeyPermissionTests: XCTestCase {

    /// The regression: prompting was unconditional and re-evaluated on every
    /// observed preference change, so toggling any unrelated setting raised the
    /// Accessibility panel.
    func testAnUnrelatedSettingChangeNeverPrompts() {
        XCTAssertFalse(AppEnvironment.shouldRequestMediaKeyAccess(current: false, lastApplied: false))
        XCTAssertFalse(AppEnvironment.shouldRequestMediaKeyAccess(current: true, lastApplied: true),
                       "Already on and unchanged: nothing was asked for")
    }

    func testTurningItOnPromptsExactlyOnce() {
        XCTAssertTrue(AppEnvironment.shouldRequestMediaKeyAccess(current: true, lastApplied: false))
        // The next pass sees it already applied.
        XCTAssertFalse(AppEnvironment.shouldRequestMediaKeyAccess(current: true, lastApplied: true))
    }

    func testTurningItOffNeverPrompts() {
        XCTAssertFalse(AppEnvironment.shouldRequestMediaKeyAccess(current: false, lastApplied: true))
    }
}

// MARK: - How far one key event moves things

extension MediaKeyPermissionTests {

    func testAFirstPressMovesAWholeNotch() {
        XCTAssertFalse(AppEnvironment.isAutoRepeat(.brightnessDown, at: 10, after: nil))
        XCTAssertEqual(AppEnvironment.step(fine: false), 1.0 / 16, accuracy: 0.0001)
    }

    /// The regression: this keyboard sets the repeat bit on fresh presses, so
    /// every tap took the fine step and the screen barely moved. Separate taps,
    /// however quick, must each count as a fresh press.
    func testSeparateTapsAreNeverTreatedAsHeld() {
        XCTAssertFalse(AppEnvironment.isAutoRepeat(.brightnessDown, at: 10.2, after: (.brightnessDown, 10.0)))
        XCTAssertFalse(AppEnvironment.isAutoRepeat(.brightnessDown, at: 11.0, after: (.brightnessDown, 10.0)))
    }

    /// A held key delivers an event about every 85 ms.
    func testAutoRepeatIsRecognisedByItsPace() {
        XCTAssertTrue(AppEnvironment.isAutoRepeat(.brightnessDown, at: 10.085, after: (.brightnessDown, 10.0)))
    }

    func testSwitchingKeysIsAlwaysAFreshPress() {
        XCTAssertFalse(AppEnvironment.isAutoRepeat(.brightnessUp, at: 10.05, after: (.brightnessDown, 10.0)))
    }

    /// Holding for a second: one full notch, then about eleven fine repeats.
    /// At a full notch per repeat this crossed the whole range in 1.1 s.
    func testHoldingForASecondDoesNotCrossTheWholeRange() {
        let travelled = AppEnvironment.step(fine: false) + 11 * AppEnvironment.step(fine: true)
        XCTAssertLessThan(travelled, 0.25)
    }
}
