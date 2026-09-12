//
//  Preferences.swift
//  Aperture
//
//  Observable settings model. Reads once at init, writes through on every
//  mutation, so there is exactly one source of truth for the whole app.
//

import Observation
import SwiftUI

/// Which provider feeds the Now Playing surfaces.
enum MediaSourceChoice: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Follows whichever supported app is actually playing.
    case automatic
    /// Scripted, self-contained playback used for development and demos.
    case demo
    /// Apple Music via user-authorised AppleScript (Automation permission).
    case musicApp
    /// The TV app, which shares Music's scripting suite.
    case tv
    /// Spotify via its own scripting interface (Automation permission).
    case spotify
    /// Whatever is playing in a Safari tab, read through `do JavaScript`.
    case safari
    /// Chromium browsers, read the same way.
    case chrome
    case brave

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: "Whatever is playing"
        case .demo: "Demo player"
        case .musicApp: "Apple Music"
        case .tv: "Apple TV"
        case .spotify: "Spotify"
        case .safari: "Safari"
        case .chrome: "Google Chrome"
        case .brave: "Brave Browser"
        }
    }

    var explanation: String {
        switch self {
        case .automatic:
            "Follows whichever app is actually playing — Music, Spotify, Safari, Chrome or Brave — and switches as you do. macOS has no way to report playback for *any* app without a private framework, so this asks each one Aperture can talk to; apps that are not running cost nothing. Each app it reaches for prompts once for Automation, and the browsers additionally need their \u{201C}Allow JavaScript from Apple Events\u{201D} setting."
        case .demo:
            "A built-in sample track. Nothing leaves your Mac and no permissions are needed."
        case .musicApp:
            "Reads the Music app's current track using AppleScript. macOS will ask for Automation permission the first time."
        case .tv:
            "Reads what the TV app is playing, through the same scripting suite as Music. Shows the episode name with its series; there is no shuffle to offer."
        case .spotify:
            "Reads Spotify's current track using its scripting interface. macOS will ask for Automation permission the first time. Artwork appears only if Spotify hands it over directly — Aperture will not fetch it from the network."
        case .chrome, .brave:
            "Reads whatever a tab is playing, through the browser's scripting interface. Needs Automation permission and View ▸ Developer ▸ \u{201C}Allow JavaScript from Apple Events\u{201D}. Play/pause and seek work; next and shuffle do not exist for an arbitrary page."
        case .safari:
            "Reads whatever a Safari tab is playing. As well as Automation permission, this needs Safari ▸ Settings ▸ Advanced ▸ \u{201C}Show features for web developers\u{201D}, then Develop ▸ \u{201C}Allow JavaScript from Apple Events\u{201D}: Safari publishes no playback state, so the only way in is running a snippet in the tab. Play/pause and seek work; next and shuffle do not exist for an arbitrary page."
        }
    }
}

@MainActor
@Observable
final class Preferences {

    private let store: PreferenceStoring
    /// Suppresses write-back while `init` seeds the observable properties.
    private var isLoading = true

    // MARK: General

    var launchAtLogin: Bool { didSet { persist(launchAtLogin, PreferenceKey.launchAtLogin) } }
    /// Whether the overlay joins every Space (`.canJoinAllSpaces`) or stays on
    /// the one it was created on. It does *not* keep the overlay out of
    /// full-screen apps — see ``OverlayPanel/setSpaceBehavior(showInFullscreen:)``.
    var showInFullscreen: Bool { didSet { persist(showInFullscreen, PreferenceKey.showInFullscreen) } }
    var hoverExpansion: Bool { didSet { persist(hoverExpansion, PreferenceKey.hoverExpansion) } }
    /// Tap the trackpad when the cursor arrives on the overlay. Silently
    /// does nothing on hardware without a Force Touch trackpad.
    var hapticFeedback: Bool { didSet { persist(hapticFeedback, PreferenceKey.hapticFeedback) } }
    /// Keep the pill out of full-screen apps. The hub still opens on
    /// request — this suppresses only what Aperture shows on its own.
    var hideInFullscreen: Bool { didSet { persist(hideInFullscreen, PreferenceKey.hideInFullscreen) } }
    /// Take the volume and brightness keys so only Aperture's readout
    /// appears. Off by default: it is the one feature that needs a
    /// permission, so it is never switched on behind the user's back.
    var interceptMediaKeys: Bool { didSet { persist(interceptMediaKeys, PreferenceKey.interceptMediaKeys) } }
    var showMedia: Bool { didSet { persist(showMedia, PreferenceKey.showMedia) } }
    var showCalendar: Bool { didSet { persist(showCalendar, PreferenceKey.showCalendar) } }
    var showTimers: Bool { didSet { persist(showTimers, PreferenceKey.showTimers) } }
    /// User-facing "Pause Aperture" — withdraws the overlay without quitting.
    var isPaused: Bool { didSet { persist(isPaused, PreferenceKey.isPaused) } }
    /// Close the hub again once the user stops interacting with it.
    var autoCollapseHub: Bool { didSet { persist(autoCollapseHub, PreferenceKey.autoCollapseHub) } }

    // MARK: Appearance

    /// 0.85…1.30. Multiplies every overlay dimension.
    var overlayScale: Double { didSet { persist(overlayScale, PreferenceKey.overlayScale) } }
    /// 0…1. 0 is nearly linear, 1 is springy.
    var animationIntensity: Double { didSet { persist(animationIntensity, PreferenceKey.animationIntensity) } }
    var accent: AccentChoice { didSet { persistEnum(accent, PreferenceKey.accent) } }
    var appearanceMode: AppearanceMode { didSet { persistEnum(appearanceMode, PreferenceKey.appearanceMode) } }

    // MARK: Calendar

    /// Calendar integration is opt-in; EventKit is not touched until this is on.
    var calendarEnabled: Bool { didSet { persist(calendarEnabled, PreferenceKey.calendarEnabled) } }
    var selectedCalendarIDs: Set<String> { didSet { persistSet(selectedCalendarIDs, PreferenceKey.selectedCalendarIDs) } }
    var lookAheadMinutes: Int { didSet { persist(lookAheadMinutes, PreferenceKey.lookAheadMinutes) } }

    // MARK: Accessibility

    /// User override, OR-ed with the system's Reduce Motion setting.
    var reduceMotionOverride: Bool { didSet { persist(reduceMotionOverride, PreferenceKey.reduceMotion) } }
    var increaseContrastOverride: Bool { didSet { persist(increaseContrastOverride, PreferenceKey.increaseContrast) } }
    var hotKey: HotKeyBinding { didSet { persistJSON(hotKey, PreferenceKey.hotKey) } }

    // MARK: Media

    var mediaSource: MediaSourceChoice { didSet { persistEnum(mediaSource, PreferenceKey.mediaSource) } }

    // MARK: System-derived accessibility state

    /// Mirrors `NSWorkspace.accessibilityDisplayShouldReduceMotion`, refreshed
    /// from the workspace notification rather than polled.
    private(set) var systemReduceMotion: Bool = false
    private(set) var systemIncreaseContrast: Bool = false

    var reduceMotion: Bool { reduceMotionOverride || systemReduceMotion }
    var increaseContrast: Bool { increaseContrastOverride || systemIncreaseContrast }

    // MARK: - Init

    init(store: PreferenceStoring = UserDefaults.standard) {
        self.store = store

        launchAtLogin = store.bool(PreferenceKey.launchAtLogin, default: false)
        showInFullscreen = store.bool(PreferenceKey.showInFullscreen, default: false)
        hoverExpansion = store.bool(PreferenceKey.hoverExpansion, default: true)
        hapticFeedback = store.bool(PreferenceKey.hapticFeedback, default: true)
        hideInFullscreen = store.bool(PreferenceKey.hideInFullscreen, default: false)
        interceptMediaKeys = store.bool(PreferenceKey.interceptMediaKeys, default: false)
        showMedia = store.bool(PreferenceKey.showMedia, default: true)
        showCalendar = store.bool(PreferenceKey.showCalendar, default: true)
        showTimers = store.bool(PreferenceKey.showTimers, default: true)
        isPaused = store.bool(PreferenceKey.isPaused, default: false)
        autoCollapseHub = store.bool(PreferenceKey.autoCollapseHub, default: true)

        overlayScale = store.double(PreferenceKey.overlayScale, default: 1.0)
        animationIntensity = store.double(PreferenceKey.animationIntensity, default: 0.6)
        accent = store.decode(PreferenceKey.accent, default: AccentChoice.mono)
        appearanceMode = store.decode(PreferenceKey.appearanceMode, default: AppearanceMode.alwaysDark)

        calendarEnabled = store.bool(PreferenceKey.calendarEnabled, default: false)
        selectedCalendarIDs = store.stringSet(PreferenceKey.selectedCalendarIDs, default: [])
        lookAheadMinutes = store.int(PreferenceKey.lookAheadMinutes, default: 12 * 60)

        reduceMotionOverride = store.bool(PreferenceKey.reduceMotion, default: false)
        increaseContrastOverride = store.bool(PreferenceKey.increaseContrast, default: false)
        hotKey = store.decodeJSON(PreferenceKey.hotKey, as: HotKeyBinding.self, default: .default)

        mediaSource = store.decode(PreferenceKey.mediaSource, default: MediaSourceChoice.demo)

        isLoading = false
    }

    // MARK: - Derived

    var activityPolicy: ActivityPolicy {
        ActivityPolicy(
            mediaEnabled: showMedia,
            calendarEnabled: showCalendar && calendarEnabled,
            timersEnabled: showTimers
        )
    }

    /// Clamped so a hand-edited defaults plist cannot produce a 4× overlay.
    var resolvedScale: CGFloat { CGFloat(min(max(overlayScale, 0.85), 1.30)) }

    var resolvedAnimationIntensity: Double { min(max(animationIntensity, 0), 1) }

    var lookAheadInterval: TimeInterval { TimeInterval(lookAheadMinutes) * 60 }

    func updateSystemAccessibilityFlags(reduceMotion: Bool, increaseContrast: Bool) {
        systemReduceMotion = reduceMotion
        systemIncreaseContrast = increaseContrast
    }

    /// Restores factory defaults without dropping unrelated keys in the domain.
    func resetToDefaults() {
        for key in [
            PreferenceKey.showInFullscreen, PreferenceKey.hoverExpansion,
            PreferenceKey.hapticFeedback, PreferenceKey.hideInFullscreen,
            PreferenceKey.interceptMediaKeys,
            PreferenceKey.autoCollapseHub,
            PreferenceKey.showMedia, PreferenceKey.showCalendar, PreferenceKey.showTimers,
            PreferenceKey.overlayScale, PreferenceKey.animationIntensity,
            PreferenceKey.accent, PreferenceKey.appearanceMode,
            PreferenceKey.lookAheadMinutes, PreferenceKey.reduceMotion,
            PreferenceKey.increaseContrast, PreferenceKey.hotKey,
        ] {
            store.removeObject(forKey: key)
        }

        isLoading = true
        showInFullscreen = false
        hoverExpansion = true
        hapticFeedback = true
        hideInFullscreen = false
        interceptMediaKeys = false
        autoCollapseHub = true
        showMedia = true
        showCalendar = true
        showTimers = true
        overlayScale = 1.0
        animationIntensity = 0.6
        accent = .mono
        appearanceMode = .alwaysDark
        lookAheadMinutes = 12 * 60
        reduceMotionOverride = false
        increaseContrastOverride = false
        hotKey = .default
        isLoading = false
    }

    // MARK: - Write-through

    private func persist(_ value: Any, _ key: String) {
        guard !isLoading else { return }
        store.set(value, forKey: key)
    }

    private func persistSet(_ value: Set<String>, _ key: String) {
        guard !isLoading else { return }
        store.set(value, forKey: key)
    }

    private func persistEnum<T: RawRepresentable>(_ value: T, _ key: String) where T.RawValue == String {
        guard !isLoading else { return }
        store.encode(value, forKey: key)
    }

    private func persistJSON<T: Encodable>(_ value: T, _ key: String) {
        guard !isLoading else { return }
        store.encodeJSON(value, forKey: key)
    }
}

extension Preferences {
    /// Preview/test instance backed by memory.
    static func preview(configure: (Preferences) -> Void = { _ in }) -> Preferences {
        let preferences = Preferences(store: InMemoryPreferenceStore())
        configure(preferences)
        return preferences
    }
}
