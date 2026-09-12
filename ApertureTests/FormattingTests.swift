//
//  FormattingTests.swift
//  ApertureTests
//

import XCTest
@testable import Aperture

final class FormattingTests: XCTestCase {

    func testClockUsesMinutesAndSeconds() {
        XCTAssertEqual(DurationFormatter.clock(0), "0:00")
        XCTAssertEqual(DurationFormatter.clock(9), "0:09")
        XCTAssertEqual(DurationFormatter.clock(83), "1:23")
        XCTAssertEqual(DurationFormatter.clock(214), "3:34")
    }

    func testClockAddsHoursOnlyWhenNeeded() {
        XCTAssertEqual(DurationFormatter.clock(3599), "59:59")
        XCTAssertEqual(DurationFormatter.clock(3600), "1:00:00")
        XCTAssertEqual(DurationFormatter.clock(7325), "2:02:05")
    }

    func testClockClampsNegativeIntervals() {
        XCTAssertEqual(DurationFormatter.clock(-42), "0:00")
    }

    func testCountdownPhrasing() {
        XCTAssertEqual(DurationFormatter.countdown(5), "now")
        XCTAssertEqual(DurationFormatter.countdown(30), "now")
        XCTAssertEqual(DurationFormatter.countdown(240), "in 4 min")
        XCTAssertEqual(DurationFormatter.countdown(59 * 60), "in 59 min")
    }

    func testCountdownDropsAPointlessDecimal() {
        XCTAssertEqual(DurationFormatter.countdown(4 * 3600), "in 4 h")
        XCTAssertEqual(DurationFormatter.countdown(90 * 60), "in 1.5 h")
        XCTAssertEqual(DurationFormatter.countdown(8 * 3600), "in 8 h")
    }

    func testCountdownSwitchesToDays() {
        XCTAssertEqual(DurationFormatter.countdown(48 * 3600), "in 2 d")
    }

    func testSpokenClockAvoidsBeingReadAsATimeOfDay() {
        XCTAssertEqual(DurationFormatter.spokenClock(0), "0 seconds")
        XCTAssertEqual(DurationFormatter.spokenClock(1), "1 second")
        XCTAssertEqual(DurationFormatter.spokenClock(60), "1 minute")
        XCTAssertEqual(DurationFormatter.spokenClock(125), "2 minutes 5 seconds")
    }

    func testHotKeyDisplayAndSpokenForms() {
        let binding = HotKeyBinding.default
        XCTAssertEqual(binding.displayString, "⇧⌘Space")
        XCTAssertEqual(binding.accessibilityString, "Shift Command Space")
        XCTAssertTrue(binding.isValid)
        XCTAssertFalse(HotKeyBinding(keyCode: 49, modifiers: 0).isValid, "A shortcut needs a modifier")
    }

    func testHUDAccessibilityDescriptions() {
        XCTAssertEqual(
            HUDEvent.volume(level: 0.5, isMuted: false).accessibilityDescription,
            "Output volume 50 percent"
        )
        XCTAssertEqual(
            HUDEvent.volume(level: 0.5, isMuted: true).accessibilityDescription,
            "Output muted"
        )
        XCTAssertEqual(
            HUDEvent.timerCompleted(title: "Steep tea").accessibilityDescription,
            "Timer finished: Steep tea"
        )
    }

    func testHUDCoalescingKeysGroupRepeatsOfTheSameKind() {
        XCTAssertEqual(
            HUDEvent.volume(level: 0.1, isMuted: false).coalescingKey,
            HUDEvent.volume(level: 0.9, isMuted: true).coalescingKey
        )
        XCTAssertNotEqual(
            HUDEvent.volume(level: 0.1, isMuted: false).coalescingKey,
            HUDEvent.brightness(level: 0.1, displayName: "Display").coalescingKey
        )
    }

    func testVolumeSymbolTracksLevel() {
        XCTAssertEqual(HUDEvent.volume(level: 0, isMuted: false).symbolName, "speaker.slash.fill")
        XCTAssertEqual(HUDEvent.volume(level: 0.2, isMuted: false).symbolName, "speaker.wave.1.fill")
        XCTAssertEqual(HUDEvent.volume(level: 0.5, isMuted: false).symbolName, "speaker.wave.2.fill")
        XCTAssertEqual(HUDEvent.volume(level: 0.9, isMuted: false).symbolName, "speaker.wave.3.fill")
        XCTAssertEqual(HUDEvent.volume(level: 0.9, isMuted: true).symbolName, "speaker.slash.fill")
    }

    func testMediaPlayheadInterpolatesOnlyWhilePlaying() {
        let start = Date(timeIntervalSinceReferenceDate: 780_000_000)
        var snapshot = PreviewData.playingMedia
        snapshot.sampledAt = start
        snapshot.elapsed = 100

        XCTAssertEqual(snapshot.elapsed(at: start.addingTimeInterval(10)), 110, accuracy: 0.001)
        XCTAssertEqual(snapshot.progress(at: start.addingTimeInterval(7))!, 107.0 / 214.0, accuracy: 0.001)

        snapshot.isPlaying = false
        XCTAssertEqual(snapshot.elapsed(at: start.addingTimeInterval(10)), 100, accuracy: 0.001)
    }

    func testMediaPlayheadNeverRunsPastTheTrack() {
        let start = Date(timeIntervalSinceReferenceDate: 780_000_000)
        var snapshot = PreviewData.playingMedia
        snapshot.sampledAt = start
        snapshot.elapsed = 210
        XCTAssertEqual(snapshot.elapsed(at: start.addingTimeInterval(60)), 214, accuracy: 0.001)
    }

    func testTimerProgressAndCompletion() {
        let now = Date(timeIntervalSinceReferenceDate: 780_000_000)
        let timer = TimerActivity(id: UUID(), title: "T", total: 300, fireDate: now.addingTimeInterval(75), pausedRemaining: nil)

        XCTAssertEqual(timer.remaining(at: now), 75, accuracy: 0.001)
        XCTAssertEqual(timer.progress(at: now), 0.75, accuracy: 0.001)
        XCTAssertFalse(timer.hasCompleted(at: now))
        XCTAssertTrue(timer.hasCompleted(at: now.addingTimeInterval(80)))
    }

    func testPausedTimerNeverCompletes() {
        let now = Date(timeIntervalSinceReferenceDate: 780_000_000)
        let timer = TimerActivity(id: UUID(), title: "T", total: 300, fireDate: nil, pausedRemaining: 0)
        XCTAssertFalse(timer.hasCompleted(at: now), "A paused timer must not fire on its own")
    }
}

// MARK: - Slider fill

final class SliderFillTests: XCTestCase {

    /// A timeline is read more than it is dragged, so its played portion is
    /// softer than a control's.
    func testATimelineIsFadedAndAControlIsNot() {
        XCTAssertEqual(
            ApertureSlider.fillColor(style: .timeline, isEnabled: true, increaseContrast: false),
            Tokens.Palette.meterSoft
        )
        XCTAssertEqual(
            ApertureSlider.fillColor(style: .control, isEnabled: true, increaseContrast: false),
            Tokens.Palette.meter
        )
    }

    /// Deliberately reducing contrast is exactly what Increase Contrast exists
    /// to undo, so the timeline goes back to full strength.
    func testIncreaseContrastRestoresTheFullStrengthFill() {
        XCTAssertEqual(
            ApertureSlider.fillColor(style: .timeline, isEnabled: true, increaseContrast: true),
            Tokens.Palette.meter
        )
    }

    func testADisabledSliderIsNeitherColour() {
        for style in [ApertureSlider.Style.timeline, .control] {
            XCTAssertEqual(
                ApertureSlider.fillColor(style: style, isEnabled: false, increaseContrast: false),
                Tokens.Palette.hairline
            )
        }
    }
}
