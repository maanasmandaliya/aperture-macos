//
//  AutomaticMediaController.swift
//  Aperture
//
//  Follows whatever is playing, rather than making the user name a source.
//
//  macOS has no public way to ask "what is playing on this Mac". That answer
//  lives in `MediaRemote`, a private framework, and Aperture will not link it.
//  What it can do is ask every app it knows how to talk to and take whichever
//  one is actually playing — which covers the same ground for the apps people
//  use, without a private API.
//
//  Cost is the thing to get right: asking five apps every second would be five
//  Apple events per second, several of them to browsers running a snippet in a
//  tab. So the winner is remembered and asked alone while it keeps playing, and
//  the others are swept only when it goes quiet, and then no faster than once a
//  couple of seconds.
//

import AppKit
import Foundation
import OSLog

actor AutomaticMediaController: MediaController {

    nonisolated let displayName = "Whatever is playing"
    /// The union is never advertised: capabilities follow the source that is
    /// actually playing, through ``activeCapabilities()``. A Safari track must
    /// not light up a skip button that no page can honour.
    nonisolated var capabilities: MediaCapabilities { [.transport, .skip, .seek, .artwork, .shuffle] }

    private let log = Logger(subsystem: ApertureInfo.bundleIdentifier, category: "AutoSource")

    private let children: [any MediaController]
    /// The child that last reported playback, asked first on the next poll.
    private var active: (any MediaController)?
    private var activeCapabilitiesValue: MediaCapabilities = []
    private var lastSweep = Date.distantPast
    /// Last sweep summary that was logged, so a steady state stays quiet but a
    /// change is always visible. Without this, "nothing is playing" and "the
    /// browser refused" look identical from outside.
    private var lastLoggedSweep = ""

    /// How long to wait before re-asking every app.
    ///
    /// Two intervals, because the two situations are not alike. With nothing
    /// playing, a sweep is how playback gets noticed at all, so it stays brisk.
    /// With something already playing, a sweep only catches the user *switching*
    /// apps — rarer, and worth far less than the battery it costs, since each
    /// sweep wakes every running player and makes browsers run a snippet.
    private static let idleSweepInterval: TimeInterval = 2
    private static let activeSweepInterval: TimeInterval = 6

    /// Children that reported nothing, and when to bother them again.
    ///
    /// A browser with no media open is the expensive case: answering costs it a
    /// tab sweep. Backing off doubles the wait each time, to a ceiling, so idle
    /// apps fade into the background instead of being interrogated for ever.
    private var backoffUntil: [ObjectIdentifier: Date] = [:]
    private var backoffStep: [ObjectIdentifier: TimeInterval] = [:]
    private static let maximumBackoff: TimeInterval = 30

    init(children: [any MediaController] = AutomaticMediaController.defaultChildren()) {
        self.children = children
    }

    /// Every app Aperture knows how to read. Ones that are not running answer
    /// instantly and cheaply, so the list costs nothing to carry.
    static func defaultChildren() -> [any MediaController] {
        [
            AppleMediaController.music(),
            AppleMediaController.tv(),
            SpotifyMediaController(),
            SafariMediaController(),
            ChromiumMediaController.chrome(),
            ChromiumMediaController.brave(),
        ]
    }

    // MARK: - MediaController

    func activeCapabilities() async -> MediaCapabilities {
        activeCapabilitiesValue.isEmpty ? capabilities : activeCapabilitiesValue
    }

    func availability() async -> MediaAvailability {
        if let active { return await active.availability() }
        return .idle(reason: "Nothing is playing in an app Aperture can read.")
    }

    func volume() async -> Double? { nil }

    func snapshot() async -> MediaSnapshot {
        // Between sweeps the incumbent is asked alone, so the steady state costs
        // one Apple event per poll.
        let playing = activeCapabilitiesValue.isEmpty == false
        let interval = playing ? Self.activeSweepInterval : Self.idleSweepInterval
        if let active, Date().timeIntervalSince(lastSweep) < interval {
            let snapshot = await active.snapshot()
            if snapshot.hasTrack {
                activeCapabilitiesValue = active.capabilities
                return snapshot
            }
        }
        lastSweep = Date()
        let now = Date()

        // Everyone is asked, even while something is already playing. Stopping
        // at the first playing app meant the one earliest in this list always
        // won, so starting a video in a browser while Spotify played changed
        // nothing on screen.
        var candidates: [(controller: any MediaController, snapshot: MediaSnapshot)] = []
        var summary: [String] = []
        for child in children {
            let id = ObjectIdentifier(child)
            // The incumbent is never backed off; it is the one most likely to
            // still matter.
            if child !== active, let until = backoffUntil[id], until > now { continue }

            let snapshot = await child.snapshot()
            guard snapshot.hasTrack else {
                let step = min((backoffStep[id] ?? Self.idleSweepInterval) * 2, Self.maximumBackoff)
                backoffStep[id] = step
                backoffUntil[id] = now.addingTimeInterval(step)
                continue
            }
            backoffStep[id] = nil
            backoffUntil[id] = nil
            summary.append("\(child.displayName)=\(snapshot.isPlaying ? "playing" : "paused")")
            candidates.append((child, snapshot))
        }
        logSweep(summary)

        // Playing beats paused; among equals, whichever changed most recently
        // wins. That is the one the user just pressed play on, which is the
        // only defensible answer when two apps are both making noise.
        let best = candidates
            .sorted { lhs, rhs in
                if lhs.snapshot.isPlaying != rhs.snapshot.isPlaying { return lhs.snapshot.isPlaying }
                return lhs.snapshot.lastTransportChange > rhs.snapshot.lastTransportChange
            }
            .first

        guard let best else {
            active = nil
            activeCapabilitiesValue = []
            return .empty
        }

        if active !== best.controller {
            log.notice("Now following \(best.controller.displayName, privacy: .public)")
        }
        active = best.controller
        activeCapabilitiesValue = best.controller.capabilities
        return best.snapshot
    }

    private func logSweep(_ summary: [String]) {
        let line = summary.isEmpty ? "nothing playing anywhere" : summary.joined(separator: ", ")
        guard line != lastLoggedSweep else { return }
        lastLoggedSweep = line
        log.notice("Swept sources: \(line, privacy: .public)")
    }

    func send(_ command: MediaCommand) async {
        await active?.send(command)
    }

    @discardableResult
    func refreshArtworkIfNeeded() async -> Data? {
        switch active {
        case let apple as AppleMediaController: return await apple.refreshArtworkIfNeeded()
        case let spotify as SpotifyMediaController: return await spotify.refreshArtworkIfNeeded()
        case let safari as SafariMediaController: return await safari.refreshArtworkIfNeeded()
        case let chromium as ChromiumMediaController: return await chromium.refreshArtworkIfNeeded()
        default: return nil
        }
    }
}
