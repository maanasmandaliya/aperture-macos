//
//  PreferenceStore.swift
//  Aperture
//
//  A thin abstraction over UserDefaults so preference reading/writing can be
//  exercised in tests without touching the user's real defaults domain.
//

import Foundation

protocol PreferenceStoring: AnyObject, Sendable {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: PreferenceStoring {}

/// Test double. Also used by SwiftUI previews so previews never mutate the
/// user's saved settings.
final class InMemoryPreferenceStore: PreferenceStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Any]

    init(seed: [String: Any] = [:]) { storage = seed }

    func object(forKey key: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    func set(_ value: Any?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        if let value { storage[key] = value } else { storage.removeValue(forKey: key) }
    }

    func removeObject(forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: key)
    }
}

// MARK: - Typed access

extension PreferenceStoring {

    func bool(_ key: String, default fallback: Bool) -> Bool {
        object(forKey: key) as? Bool ?? fallback
    }

    func double(_ key: String, default fallback: Double) -> Double {
        object(forKey: key) as? Double ?? fallback
    }

    func int(_ key: String, default fallback: Int) -> Int {
        object(forKey: key) as? Int ?? fallback
    }

    func string(_ key: String, default fallback: String) -> String {
        object(forKey: key) as? String ?? fallback
    }

    func stringSet(_ key: String, default fallback: Set<String>) -> Set<String> {
        guard let raw = object(forKey: key) as? [String] else { return fallback }
        return Set(raw)
    }

    func set(_ value: Set<String>, forKey key: String) {
        set(Array(value).sorted(), forKey: key)
    }

    /// Raw-representable enums round-trip through their raw value so a defaults
    /// plist stays human-readable (and survives a value being renamed away).
    func decode<T: RawRepresentable>(_ key: String, default fallback: T) -> T where T.RawValue == String {
        guard let raw = object(forKey: key) as? String, let value = T(rawValue: raw) else { return fallback }
        return value
    }

    func encode<T: RawRepresentable>(_ value: T, forKey key: String) where T.RawValue == String {
        set(value.rawValue, forKey: key)
    }

    func decodeJSON<T: Decodable>(_ key: String, as type: T.Type, default fallback: T) -> T {
        guard let data = object(forKey: key) as? Data,
              let value = try? JSONDecoder().decode(T.self, from: data) else { return fallback }
        return value
    }

    func encodeJSON<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        set(data, forKey: key)
    }
}

/// Every defaults key Aperture owns, in one place.
enum PreferenceKey {
    static let launchAtLogin = "general.launchAtLogin"
    static let showInFullscreen = "general.showInFullscreen"
    static let hoverExpansion = "general.hoverExpansion"
    static let hapticFeedback = "general.hapticFeedback"
    static let hideInFullscreen = "general.hideInFullscreen"
    static let interceptMediaKeys = "general.interceptMediaKeys"
    static let showMedia = "general.showMedia"
    static let showCalendar = "general.showCalendar"
    static let showTimers = "general.showTimers"
    static let isPaused = "general.isPaused"
    static let autoCollapseHub = "general.autoCollapseHub"

    static let overlayScale = "appearance.overlayScale"
    static let animationIntensity = "appearance.animationIntensity"
    static let accent = "appearance.accent"
    static let appearanceMode = "appearance.mode"

    static let calendarEnabled = "calendar.enabled"
    static let selectedCalendarIDs = "calendar.selectedIdentifiers"
    static let lookAheadMinutes = "calendar.lookAheadMinutes"

    static let reduceMotion = "accessibility.reduceMotion"
    static let increaseContrast = "accessibility.increaseContrast"
    static let hotKey = "accessibility.hotKey"

    static let mediaSource = "media.source"
}
