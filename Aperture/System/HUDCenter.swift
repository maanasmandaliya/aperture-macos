//
//  HUDCenter.swift
//  Aperture
//

import Observation
import SwiftUI

/// Owns the single temporary HUD slot: presentation, coalescing and dismissal.
@MainActor
@Observable
final class HUDCenter {

    private(set) var current: HUDEvent?

    /// Raised whenever the HUD slot changes shape — occupied, empty, or the
    /// same slot taken over by a HUD of a different style — so the overlay state
    /// machine can react without observing the whole object.
    var onPresentationChange: ((HUDStyle?) -> Void)?

    private var dismissTask: Task<Void, Never>?

    /// Presents `event`. A repeat of the same coalescing key (holding the volume
    /// key, say) replaces the content and restarts the dwell instead of queueing
    /// a second HUD.
    func present(_ event: HUDEvent) {
        // Compared by style, not by visibility: a notification landing on top of
        // a volume readout keeps the slot occupied but changes the slab's shape.
        let previousStyle = current?.style
        current = event
        if previousStyle != event.style { onPresentationChange?(event.style) }

        dismissTask?.cancel()
        let dwell = event.dwell
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(dwell))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        guard current != nil else { return }
        current = nil
        onPresentationChange?(nil)
    }

    func invalidate() {
        dismissTask?.cancel()
        dismissTask = nil
        current = nil
    }
}
