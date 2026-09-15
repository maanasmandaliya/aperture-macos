//
//  OverlayState.swift
//  Aperture
//
//  The overlay's presentation state and the pure state machine that drives it.
//

import Foundation

enum HubTab: String, CaseIterable, Codable, Sendable, Identifiable {
    case nowPlaying
    case schedule
    case mirror
    case controls

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nowPlaying: "Now Playing"
        case .schedule: "Schedule"
        case .mirror: "Mirror"
        case .controls: "Controls"
        }
    }

    var symbolName: String {
        switch self {
        case .nowPlaying: "play.circle"
        case .schedule: "calendar"
        case .mirror: "camera"
        case .controls: "slider.horizontal.3"
        }
    }

    /// The panes form a vertical stack the user swipes through. `nil` at either
    /// end is meaningful: swiping past the top closes the hub, and swiping past
    /// the bottom does nothing rather than wrapping — wrapping would make it
    /// impossible to tell where you are without looking.
    var deeper: HubTab? {
        let all = HubTab.allCases
        guard let index = all.firstIndex(of: self), index + 1 < all.count else { return nil }
        return all[index + 1]
    }

    var shallower: HubTab? {
        let all = HubTab.allCases
        guard let index = all.firstIndex(of: self), index > 0 else { return nil }
        return all[index - 1]
    }

    var depth: Int { HubTab.allCases.firstIndex(of: self) ?? 0 }
}

enum OverlayPresentation: Equatable, Sendable {
    /// Overlay withdrawn entirely (paused, or no eligible screen).
    case hidden
    /// The resting state: a slab no wider than the camera housing needs,
    /// carrying artwork and a track glyph in its wings when something is live.
    /// This is where the overlay sits unless the user asks for more.
    case minimal
    /// A transient wide strip, shown for a few seconds when an activity starts
    /// or changes, then retiring back to ``minimal``.
    case compact
    /// Temporary HUD, layered over the resting or peeking state. The style is
    /// carried here so the slab's size is a function of the presentation alone.
    case hud(HUDStyle)
    /// Expanded hub panel.
    case expanded(HubTab)

    var isExpanded: Bool {
        if case .expanded = self { return true }
        return false
    }

    var isHUD: Bool {
        if case .hud = self { return true }
        return false
    }

    /// Only the expanded hub accepts clicks, drags and keyboard focus; every
    /// other state leaves the window click-through outside the pill's own rect.
    var isInteractive: Bool { isExpanded }

    /// Transient states retire on a timer rather than on user action.
    var isTransient: Bool { self == .compact || isHUD }

    var tab: HubTab? {
        if case .expanded(let tab) = self { return tab }
        return nil
    }
}

enum OverlayEvent: Equatable, Sendable {
    case pauseChanged(Bool)
    case screenAvailabilityChanged(Bool)
    case activityChanged(Bool)
    case toggleExpanded
    case expand(HubTab)
    case selectTab(HubTab)
    case collapse
    /// A live activity started or changed; show the wide strip briefly.
    case peekBegan
    case peekEnded
    case hudBegan(HUDStyle)
    case hudEnded
}

/// Deterministic transitions for the overlay.
///
/// Rules that matter:
/// * Pause and "no usable screen" always win and force `.hidden`.
/// * The overlay always *rests* at `.minimal`. A live activity no longer
///   promotes it to the wide strip and leaves it there — that state is a peek
///   with a deadline, so the overlay stays out of the way unless asked.
/// * A HUD may interrupt `.minimal`/`.compact` but never the expanded hub, so a
///   volume tap while the user is dragging the seek slider changes nothing.
/// * A HUD outranks a peek; a peek never displaces a HUD.
/// * Leaving any transient state resolves back to `.minimal`.
struct OverlayStateMachine: Equatable, Sendable {
    private(set) var presentation: OverlayPresentation
    private(set) var isPaused: Bool
    private(set) var hasScreen: Bool
    private(set) var hasActivity: Bool
    /// Tab restored the next time the hub opens without an explicit tab.
    private(set) var lastTab: HubTab

    init(
        isPaused: Bool = false,
        hasScreen: Bool = true,
        hasActivity: Bool = false,
        lastTab: HubTab = .nowPlaying
    ) {
        self.isPaused = isPaused
        self.hasScreen = hasScreen
        self.hasActivity = hasActivity
        self.lastTab = lastTab
        self.presentation = Self.restingPresentation(
            isPaused: isPaused, hasScreen: hasScreen, hasActivity: hasActivity
        )
    }

    /// Applies `event`, returning `true` when the presentation actually moved.
    @discardableResult
    mutating func apply(_ event: OverlayEvent) -> Bool {
        let before = presentation

        switch event {
        case .pauseChanged(let paused):
            isPaused = paused
            presentation = resting()

        case .screenAvailabilityChanged(let available):
            hasScreen = available
            presentation = resting()

        case .activityChanged(let active):
            hasActivity = active
            // Losing the activity retires a peek early; nothing else moves,
            // because an activity appearing must not yank the user out of the
            // hub or truncate a HUD that is mid-flight.
            if !active, presentation == .compact {
                presentation = resting()
            }

        case .toggleExpanded:
            guard isPresentable else { break }
            presentation = presentation.isExpanded ? resting() : .expanded(lastTab)

        case .expand(let tab):
            guard isPresentable else { break }
            lastTab = tab
            presentation = .expanded(tab)

        case .selectTab(let tab):
            lastTab = tab
            if presentation.isExpanded { presentation = .expanded(tab) }

        case .collapse:
            if presentation.isExpanded { presentation = resting() }

        case .peekBegan:
            // A peek is the lowest-priority interruption: it never displaces a
            // HUD the user is actually reading, nor the hub.
            guard isPresentable, hasActivity, !presentation.isExpanded, !presentation.isHUD else { break }
            presentation = .compact

        case .peekEnded:
            if presentation == .compact { presentation = resting() }

        case .hudBegan(let style):
            guard isPresentable, !presentation.isExpanded else { break }
            // Re-applied whenever the style changes too, not only when the HUD
            // first appears: a notification arriving over a volume readout
            // changes the slab's shape, and the size has to follow.
            presentation = .hud(style)

        case .hudEnded:
            if presentation.isHUD { presentation = resting() }
        }

        return before != presentation
    }

    private var isPresentable: Bool { !isPaused && hasScreen }

    private func resting() -> OverlayPresentation {
        Self.restingPresentation(isPaused: isPaused, hasScreen: hasScreen, hasActivity: hasActivity)
    }

    /// The overlay's resting presentation. Independent of `hasActivity`: what a
    /// live activity changes is the *content* of the minimal slab (artwork and a
    /// track glyph in the wings), not how much room it takes.
    private static func restingPresentation(
        isPaused: Bool, hasScreen: Bool, hasActivity: Bool
    ) -> OverlayPresentation {
        guard !isPaused, hasScreen else { return .hidden }
        return .minimal
    }
}
