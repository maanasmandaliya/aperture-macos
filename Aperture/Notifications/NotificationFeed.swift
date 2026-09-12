//
//  NotificationFeed.swift
//  Aperture
//
//  Aperture's own notification stream.
//
//  macOS provides no public API for mirroring other apps' Notification Center
//  alerts, and Aperture will not use a private one, so this feed carries only
//  what Aperture itself knows about: its own events, a demo generator, and
//  anything an integrator pushes in through ``publish(_:)`` or the
//  ``NotificationSource`` extension point below.
//

import Observation
import SwiftUI

/// Extension point for app-owned notification producers.
///
/// Conform a type, hand it to ``NotificationFeed/attach(_:)``, and call the
/// supplied `emit` closure whenever you have something worth surfacing — a
/// build finishing, a webhook landing, a download completing. Aperture routes
/// it straight to a HUD.
@MainActor
protocol NotificationSource: AnyObject {
    var identifier: String { get }
    /// Called once when attached. Retain `emit` and call it from any actor hop
    /// back onto the main actor.
    func activate(emit: @escaping @MainActor (NotificationActivity) -> Void)
    func deactivate()
}

@MainActor
@Observable
final class NotificationFeed {

    /// Most recent first, capped so the feed cannot grow without bound.
    private(set) var recent: [NotificationActivity] = []

    var onPublish: ((NotificationActivity) -> Void)?

    private var sources: [String: any NotificationSource] = [:]
    private var demoTask: Task<Void, Never>?
    private let historyLimit = 20

    // MARK: - Publishing

    func publish(_ activity: NotificationActivity) {
        recent.insert(activity, at: 0)
        if recent.count > historyLimit { recent.removeLast(recent.count - historyLimit) }
        onPublish?(activity)
    }

    func clearHistory() { recent.removeAll() }

    // MARK: - Extension point

    func attach(_ source: any NotificationSource) {
        guard sources[source.identifier] == nil else { return }
        sources[source.identifier] = source
        source.activate { [weak self] activity in
            self?.publish(activity)
        }
    }

    func detach(identifier: String) {
        sources.removeValue(forKey: identifier)?.deactivate()
    }

    func detachAll() {
        for source in sources.values { source.deactivate() }
        sources.removeAll()
    }

    // MARK: - Demo generator

    var isDemoRunning: Bool { demoTask != nil }

    /// Emits a rotating set of sample notifications so the HUD path can be seen
    /// end-to-end without wiring a real producer.
    func startDemoGenerator(interval: Duration = .seconds(25)) {
        guard demoTask == nil else { return }
        demoTask = Task { [weak self] in
            var index = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                self.publish(Self.demoSamples[index % Self.demoSamples.count])
                index += 1
            }
        }
    }

    func stopDemoGenerator() {
        demoTask?.cancel()
        demoTask = nil
    }

    /// Emits one sample immediately — wired to the Controls tab's demo button.
    func emitSample() {
        publish(Self.demoSamples.randomElement() ?? Self.demoSamples[0])
    }

    static let demoSamples: [NotificationActivity] = [
        NotificationActivity(
            id: UUID(), sourceName: "Aperture", title: "Sample alert",
            body: "This is Aperture's own notification feed.",
            symbolName: "bell.badge", date: .now,
            tint: RGBColor(red: 0.486, green: 0.420, blue: 1.0)
        ),
        NotificationActivity(
            id: UUID(), sourceName: "Aperture", title: "Build finished",
            body: "Release configuration succeeded in 42s.",
            symbolName: "hammer.fill", date: .now,
            tint: RGBColor(red: 0.353, green: 0.812, blue: 0.596)
        ),
        NotificationActivity(
            id: UUID(), sourceName: "Aperture", title: "Backup complete",
            body: "Snapshot written to the external volume.",
            symbolName: "externaldrive.badge.checkmark", date: .now,
            tint: RGBColor(red: 0.325, green: 0.596, blue: 1.0)
        ),
    ]
}
