//
//  HUDEvent.swift
//  Aperture
//

import Foundation

/// The shape the slab takes for a HUD.
///
/// It lives on the presentation rather than being read off the current event,
/// because ``OverlayMetrics`` has to be able to size every state up front —
/// a spring can only run between two sizes it can compute.
enum HUDStyle: Equatable, Sendable {
    /// Straddles the camera housing at its exact height: a label in one wing, a
    /// level bar in the other. Growing sideways keeps a passing level change
    /// reading as the housing itself rather than a panel dropping out of it.
    case meter
    /// Drops below the housing. An icon, a title and a line of detail need a
    /// row of their own, which no wing is wide enough for.
    case message
}

/// A short-lived overlay shown in place of the pill.
enum HUDEvent: Equatable, Sendable, Identifiable {
    case volume(level: Double, isMuted: Bool)
    case brightness(level: Double, displayName: String)
    case timerCompleted(title: String)
    case notification(NotificationActivity)

    var id: String {
        switch self {
        case .volume: "hud.volume"
        case .brightness: "hud.brightness"
        case .timerCompleted: "hud.timer"
        case .notification(let note): "hud.note.\(note.id.uuidString)"
        }
    }

    /// HUDs sharing a coalescing key replace one another instead of queueing,
    /// so holding the volume key produces one HUD that keeps updating.
    var coalescingKey: String {
        switch self {
        case .volume: "volume"
        case .brightness: "brightness"
        case .timerCompleted: "timer"
        case .notification: "notification"
        }
    }

    var style: HUDStyle {
        switch self {
        case .volume, .brightness: .meter
        case .timerCompleted, .notification: .message
        }
    }

    /// What a meter HUD calls itself, shown beside the housing.
    var meterName: String {
        switch self {
        case .volume: "Volume"
        case .brightness: "Brightness"
        case .timerCompleted, .notification: ""
        }
    }

    /// The level a meter HUD is showing. Muted reads as empty, which is what it
    /// sounds like.
    var meterLevel: Double {
        switch self {
        case .volume(let level, let muted): muted ? 0 : level
        case .brightness(let level, _): level
        case .timerCompleted, .notification: 0
        }
    }

    var dwell: TimeInterval {
        switch self {
        case .volume, .brightness: Tokens.Motion.hudDwell
        case .timerCompleted, .notification: Tokens.Motion.hudDwellVerbose
        }
    }

    var symbolName: String {
        switch self {
        case .volume(let level, let muted):
            if muted || level <= 0 { return "speaker.slash.fill" }
            if level < 0.34 { return "speaker.wave.1.fill" }
            if level < 0.67 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        case .brightness(let level, _):
            return level < 0.5 ? "sun.min.fill" : "sun.max.fill"
        case .timerCompleted:
            return "timer"
        case .notification(let note):
            return note.symbolName
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .volume(let level, let muted):
            return muted ? "Output muted" : "Output volume \(Int((level * 100).rounded())) percent"
        case .brightness(let level, let displayName):
            return "\(displayName) brightness \(Int((level * 100).rounded())) percent"
        case .timerCompleted(let title):
            return "Timer finished: \(title)"
        case .notification(let note):
            return "\(note.sourceName): \(note.title). \(note.body)"
        }
    }
}
