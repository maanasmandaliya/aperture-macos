//
//  OverlayMouseTracker.swift
//  Aperture
//

import AppKit
import Foundation

/// Watches the cursor so the overlay can stay genuinely click-through while
/// collapsed.
///
/// A borderless window either swallows clicks or passes them on — there is no
/// per-region middle ground, because a `hitTest` returning `nil` drops the event
/// instead of forwarding it to the app underneath. So the panel keeps
/// `ignoresMouseEvents = true` and only drops the shield for the instant the
/// cursor is actually over the pill. Mouse-moved global monitors need no
/// Accessibility permission (unlike key events), which is what makes this
/// workable.
@MainActor
final class OverlayMouseTracker {

    /// Called with the current cursor location in global screen coordinates.
    var onMove: ((CGPoint) -> Void)?

    /// Called for scroll events, reduced to a `Sendable` sample so the gesture
    /// rules can live in ``SwipeRecognizer`` and be tested without AppKit.
    var onScroll: ((ScrollSample) -> Void)?

    private var moveMonitors: [Any] = []
    private var scrollMonitors: [Any] = []

    func start() {
        guard moveMonitors.isEmpty else { return }

        let moveMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]

        // Parenthesised rather than trailing closures: inside an `if let`
        // condition a trailing closure reads as the statement body.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: moveMask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.onMove?(NSEvent.mouseLocation) }
        }) {
            moveMonitors.append(global)
        }

        // The global monitor does not see events already routed to Aperture's
        // own panel, so a local monitor covers the window we just un-shielded.
        if let local = NSEvent.addLocalMonitorForEvents(matching: moveMask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.onMove?(NSEvent.mouseLocation) }
            return event
        }) {
            moveMonitors.append(local)
        }

        // Scroll events are mouse events, so a global monitor needs no
        // Accessibility permission — the same reason the move monitor works.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.report(event) }
        }) {
            scrollMonitors.append(global)
        }

        if let local = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.report(event) }
            return event
        }) {
            scrollMonitors.append(local)
        }
    }

    func stop() {
        for monitor in moveMonitors + scrollMonitors { NSEvent.removeMonitor(monitor) }
        moveMonitors.removeAll()
        scrollMonitors.removeAll()
    }

    private func report(_ event: NSEvent) {
        onScroll?(Self.sample(from: event))
    }

    static func sample(from event: NSEvent) -> ScrollSample {
        ScrollSample(
            fingerDownDelta: fingerDownDelta(for: event),
            fingerRightDelta: fingerRightDelta(for: event),
            isGestureStart: event.phase.contains(.began) || event.phase.contains(.mayBegin),
            isGestureEnd: event.phase.contains(.ended) || event.phase.contains(.cancelled),
            isMomentum: !event.momentumPhase.isEmpty,
            hasPhase: !event.phase.isEmpty,
            timestamp: event.timestamp
        )
    }

    /// Converts a scroll event into "how far the fingers moved down".
    ///
    /// `scrollingDeltaY`'s sign describes content movement, which flips with the
    /// system's natural-scrolling setting, so it is un-inverted here against
    /// `isDirectionInvertedFromDevice`. A wheel mouse reports a handful of
    /// coarse units per click rather than points, so those are scaled up to sit
    /// on the same footing as a trackpad's precise deltas.
    static func fingerDownDelta(for event: NSEvent) -> CGFloat {
        normalised(event.scrollingDeltaY, event: event)
    }

    static func fingerRightDelta(for event: NSEvent) -> CGFloat {
        normalised(event.scrollingDeltaX, event: event)
    }

    /// Positive means the fingers moved in the *positive* direction of the axis
    /// (down, or right), whatever the natural-scrolling setting is doing to the
    /// raw sign. Coarse wheel units are scaled onto the same footing as a
    /// trackpad's precise deltas.
    private static func normalised(_ raw: CGFloat, event: NSEvent) -> CGFloat {
        guard raw != 0 else { return 0 }
        let movedPositive = event.isDirectionInvertedFromDevice ? raw > 0 : raw < 0
        let magnitude = abs(raw) * (event.hasPreciseScrollingDeltas ? 1 : 10)
        return movedPositive ? magnitude : -magnitude
    }
}
