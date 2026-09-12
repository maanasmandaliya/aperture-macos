//
//  PreferencePersistenceTests.swift
//  ApertureTests
//

import XCTest
@testable import Aperture

@MainActor
final class PreferencePersistenceTests: XCTestCase {

    func testDefaultsAreUsedForAnEmptyStore() {
        let preferences = Preferences(store: InMemoryPreferenceStore())

        XCTAssertFalse(preferences.launchAtLogin)
        XCTAssertTrue(preferences.hoverExpansion)
        XCTAssertTrue(preferences.hapticFeedback)
        XCTAssertTrue(preferences.showMedia)
        XCTAssertFalse(preferences.calendarEnabled, "Calendar must be opt-in")
        XCTAssertEqual(preferences.accent, .mono, "The overlay ships monochrome")
        XCTAssertEqual(preferences.mediaSource, .demo)
        XCTAssertEqual(preferences.hotKey, .default)
        XCTAssertEqual(preferences.overlayScale, 1.0, accuracy: 0.0001)
    }

    func testValuesRoundTripThroughTheStore() {
        let store = InMemoryPreferenceStore()

        let first = Preferences(store: store)
        first.hoverExpansion = false
        first.hapticFeedback = false
        first.overlayScale = 1.15
        first.animationIntensity = 0.2
        first.accent = .teal
        first.appearanceMode = .automatic
        first.calendarEnabled = true
        first.selectedCalendarIDs = ["cal-a", "cal-b"]
        first.lookAheadMinutes = 360
        first.reduceMotionOverride = true
        first.mediaSource = .musicApp
        first.hotKey = HotKeyBinding(keyCode: 49, modifiers: 4096)

        let second = Preferences(store: store)
        XCTAssertFalse(second.hoverExpansion)
        XCTAssertFalse(second.hapticFeedback)
        XCTAssertEqual(second.overlayScale, 1.15, accuracy: 0.0001)
        XCTAssertEqual(second.animationIntensity, 0.2, accuracy: 0.0001)
        XCTAssertEqual(second.accent, .teal)
        XCTAssertEqual(second.appearanceMode, .automatic)
        XCTAssertTrue(second.calendarEnabled)
        XCTAssertEqual(second.selectedCalendarIDs, ["cal-a", "cal-b"])
        XCTAssertEqual(second.lookAheadMinutes, 360)
        XCTAssertTrue(second.reduceMotionOverride)
        XCTAssertEqual(second.mediaSource, .musicApp)
        XCTAssertEqual(second.hotKey, HotKeyBinding(keyCode: 49, modifiers: 4096))
    }

    func testLoadingDoesNotWriteBackToTheStore() {
        let store = InMemoryPreferenceStore()
        _ = Preferences(store: store)
        XCTAssertNil(store.object(forKey: PreferenceKey.accent), "Reading defaults must not populate the store")
    }

    func testUnknownRawValueFallsBackToTheDefault() {
        let store = InMemoryPreferenceStore(seed: [PreferenceKey.accent: "chartreuse"])
        XCTAssertEqual(Preferences(store: store).accent, .mono)
    }

    func testCorruptJSONFallsBackToTheDefaultShortcut() {
        let store = InMemoryPreferenceStore(seed: [PreferenceKey.hotKey: Data("not json".utf8)])
        XCTAssertEqual(Preferences(store: store).hotKey, .default)
    }

    func testScaleIsClampedWhenTheStoreHoldsAnAbsurdValue() {
        let store = InMemoryPreferenceStore(seed: [PreferenceKey.overlayScale: 9.0])
        XCTAssertEqual(Preferences(store: store).resolvedScale, 1.30, accuracy: 0.0001)

        let tiny = InMemoryPreferenceStore(seed: [PreferenceKey.overlayScale: 0.1])
        XCTAssertEqual(Preferences(store: tiny).resolvedScale, 0.85, accuracy: 0.0001)
    }

    func testAnimationIntensityIsClamped() {
        let store = InMemoryPreferenceStore(seed: [PreferenceKey.animationIntensity: 4.0])
        XCTAssertEqual(Preferences(store: store).resolvedAnimationIntensity, 1.0, accuracy: 0.0001)
    }

    // MARK: - Derived policy

    func testActivityPolicyMirrorsToggles() {
        let preferences = Preferences(store: InMemoryPreferenceStore())
        preferences.showMedia = false
        preferences.showTimers = true
        preferences.showCalendar = true
        preferences.calendarEnabled = false

        let policy = preferences.activityPolicy
        XCTAssertFalse(policy.mediaEnabled)
        XCTAssertTrue(policy.timersEnabled)
        XCTAssertFalse(policy.calendarEnabled, "Calendar needs both the toggle and integration enabled")

        preferences.calendarEnabled = true
        XCTAssertTrue(preferences.activityPolicy.calendarEnabled)
    }

    func testSystemAccessibilityFlagsAreOrRedWithOverrides() {
        let preferences = Preferences(store: InMemoryPreferenceStore())
        XCTAssertFalse(preferences.reduceMotion)

        preferences.updateSystemAccessibilityFlags(reduceMotion: true, increaseContrast: false)
        XCTAssertTrue(preferences.reduceMotion)
        XCTAssertFalse(preferences.increaseContrast)

        preferences.increaseContrastOverride = true
        XCTAssertTrue(preferences.increaseContrast)
    }

    func testResetRestoresDefaultsButKeepsCalendarSelection() {
        let store = InMemoryPreferenceStore()
        let preferences = Preferences(store: store)
        preferences.accent = .rose
        preferences.overlayScale = 1.25
        preferences.selectedCalendarIDs = ["keep-me"]

        preferences.resetToDefaults()

        XCTAssertEqual(preferences.accent, .mono, "The overlay ships monochrome")
        XCTAssertEqual(preferences.overlayScale, 1.0, accuracy: 0.0001)
        XCTAssertEqual(preferences.selectedCalendarIDs, ["keep-me"])
    }

    func testLookAheadIntervalConvertsMinutesToSeconds() {
        let preferences = Preferences(store: InMemoryPreferenceStore())
        preferences.lookAheadMinutes = 90
        XCTAssertEqual(preferences.lookAheadInterval, 5400, accuracy: 0.0001)
    }
}
