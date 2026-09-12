//
//  HapticFeedback.swift
//  Aperture
//

import AppKit
import Foundation

/// Anything that can produce a physical tap. A protocol so the rules around
/// *when* Aperture taps can be exercised without a trackpad attached.
@MainActor
protocol HapticPerforming: AnyObject, Sendable {
    func tap()
    /// Cancels any actuation still in flight. Explicit, like the app's other
    /// `@MainActor` services: `deinit` is `nonisolated` and cannot reach
    /// isolated state.
    func invalidate()
}

/// Force Touch trackpad tap, used when the cursor crosses onto the overlay.
///
/// `NSHapticFeedbackManager` is a silent no-op on hardware without a Force
/// Touch trackpad — an external mouse, or a Mac whose lid is closed — and macOS
/// exposes no public capability query, so this just asks and lets AppKit decide.
/// It also honours the user's own "Force Click and haptic feedback" setting in
/// System Settings, which is the right place for that switch to live.
@MainActor
final class HapticFeedback: HapticPerforming {

    /// `.levelChange` is the firmest of the three public patterns — `.alignment`
    /// is the crisp tick used when a guide snaps into place, `.generic` sits
    /// between them — and AppKit exposes no intensity beyond the choice of
    /// pattern.
    private static let pattern: NSHapticFeedbackManager.FeedbackPattern = .levelChange

    /// Actuations per tap, and the gap between them.
    ///
    /// Stacking is the only strength control left once the pattern is already
    /// the firmest one. The gap is the whole trick: far enough apart and the
    /// trackpad reads as two separate ticks, but at a few tens of milliseconds
    /// the two actuations fuse into a single heavier thud. Anything finer than
    /// this needs `MultitouchSupport`, which is a private framework Aperture
    /// does not link.
    private static let pulseCount = 2
    private static let pulseInterval = Duration.milliseconds(30)

    private var pulseTask: Task<Void, Never>?

    func tap() {
        NSHapticFeedbackManager.defaultPerformer.perform(Self.pattern, performanceTime: .now)
        guard Self.pulseCount > 1 else { return }

        // Restarted rather than queued: a second hover arriving mid-pulse should
        // replace the tap in progress, not stack two of them into a rattle.
        pulseTask?.cancel()
        pulseTask = Task { [weak self] in
            for _ in 1..<Self.pulseCount {
                try? await Task.sleep(for: Self.pulseInterval)
                guard !Task.isCancelled, self != nil else { return }
                NSHapticFeedbackManager.defaultPerformer.perform(Self.pattern, performanceTime: .now)
            }
        }
    }

    /// Explicit teardown, matching the rest of the app's `@MainActor` services.
    func invalidate() {
        pulseTask?.cancel()
        pulseTask = nil
    }
}

/// Enforces a floor between two taps.
///
/// A cursor resting exactly on the pill's edge flips the hover state back and
/// forth, and one tap per flip would buzz. Pure and `Sendable` so the rule is
/// testable on its own; feed it a monotonic clock (`systemUptime`) so a
/// wall-clock change cannot stall it.
struct HapticThrottle: Sendable, Equatable {

    /// Shortest gap between two taps. Long enough to swallow edge chatter,
    /// short enough that deliberately leaving and re-entering still registers.
    let minimumInterval: TimeInterval
    private var lastFired: TimeInterval?

    init(minimumInterval: TimeInterval = 0.25) {
        self.minimumInterval = minimumInterval
    }

    /// Consumes a request, reporting whether it should actually be felt.
    mutating func shouldFire(at time: TimeInterval) -> Bool {
        if let lastFired, time - lastFired < minimumInterval { return false }
        lastFired = time
        return true
    }
}
