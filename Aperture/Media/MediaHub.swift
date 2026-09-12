//
//  MediaHub.swift
//  Aperture
//
//  Observable facade in front of whichever ``MediaController`` the user picked.
//

import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class MediaHub {

    private(set) var snapshot: MediaSnapshot = .empty
    private(set) var availability: MediaAvailability = .ready
    private(set) var capabilities: MediaCapabilities = .all
    private(set) var sourceName: String = MediaSourceChoice.demo.displayName

    /// Decoded artwork, cached by track so SwiftUI does not decode per frame.
    private(set) var artwork: NSImage?
    private var artworkKey: String = ""
    /// Whether what is on screen is the generated stand-in rather than a cover.
    private var artworkIsPlaceholder = false

    private var controller: MediaController
    private var source: MediaSourceChoice
    private var refreshTask: Task<Void, Never>?
    private var isRunning = false

    /// Cadence while a track is playing. Fast enough that the progress strip
    /// stays honest, slow enough that scripting Music stays cheap; between
    /// refreshes the UI interpolates the playhead locally.
    /// The views interpolate elapsed time from `sampledAt`, so a slower poll
    /// costs smoothness nothing — only how quickly a pause made *elsewhere* is
    /// noticed, which is worth a second of latency for halved Apple-event
    /// traffic.
    private let activeInterval: Duration = .milliseconds(2200)
    /// Used while the overlay is drawing nothing. Playback still has to be
    /// noticed — the hub can be opened at any moment, and opening it refreshes
    /// immediately — but there is no readout to keep current, so the apps are
    /// left alone.
    private let hiddenInterval: Duration = .seconds(8)
    /// Set by ``AppEnvironment``; absent means "assume visible".
    var overlayIsVisible: (@MainActor () -> Bool)?
    /// Cadence while nothing is playing.
    private let idleInterval: Duration = .seconds(4)

    init(source: MediaSourceChoice = .demo) {
        self.source = source
        self.controller = Self.makeController(for: source)
        self.capabilities = controller.capabilities
        self.sourceName = controller.displayName
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        scheduleRefreshLoop()
    }

    func stop() {
        isRunning = false
        refreshTask?.cancel()
        refreshTask = nil
    }

    func setSource(_ newSource: MediaSourceChoice) {
        guard newSource != source else { return }
        source = newSource
        controller = Self.makeController(for: newSource)
        capabilities = controller.capabilities
        sourceName = controller.displayName
        snapshot = .empty
        artwork = nil
        artworkKey = ""
        if isRunning { scheduleRefreshLoop() }
    }

    // MARK: - Commands

    func send(_ command: MediaCommand) {
        let controller = self.controller
        Task {
            await controller.send(command)
            // Re-read immediately so the button feels instantaneous rather than
            // waiting out the refresh interval.
            await self.refresh()
        }
    }

    func togglePlayPause() { send(.playPause) }
    func next() { send(.next) }
    func previous() { send(.previous) }
    func seek(to position: TimeInterval) { send(.seek(position)) }
    func toggleShuffle() { send(.toggleShuffle) }

    // MARK: - Refresh

    private func scheduleRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let visible = self.overlayIsVisible?() ?? true
                let interval: Duration
                if !visible {
                    interval = self.hiddenInterval
                } else {
                    interval = self.snapshot.isPlaying ? self.activeInterval : self.idleInterval
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func refresh() async {
        let controller = self.controller
        async let newSnapshot = controller.snapshot()
        async let newAvailability = controller.availability()

        var resolved = await newSnapshot
        availability = await newAvailability

        // Pull artwork lazily, and only for scripted sources that need a second
        // (expensive) round trip. The result is merged back in: `resolved` is a
        // value taken before the fetch, so a controller storing the data on its
        // own copy would leave this one — the one the UI reads — still empty.
        if resolved.hasTrack, resolved.artworkData == nil {
            switch controller {
            case let apple as AppleMediaController: resolved.artworkData = await apple.refreshArtworkIfNeeded()
            case let spotify as SpotifyMediaController: resolved.artworkData = await spotify.refreshArtworkIfNeeded()
            case let safari as SafariMediaController: resolved.artworkData = await safari.refreshArtworkIfNeeded()
            case let chromium as ChromiumMediaController: resolved.artworkData = await chromium.refreshArtworkIfNeeded()
            case let automatic as AutomaticMediaController: resolved.artworkData = await automatic.refreshArtworkIfNeeded()
            default: break
            }
        }

        // Re-read every poll rather than once per source: the automatic source
        // follows different apps over time, and a Safari track must not leave a
        // skip button lit that no page can honour.
        capabilities = await controller.activeCapabilities()

        snapshot = resolved
        updateArtwork(for: resolved)
    }

    private func updateArtwork(for snapshot: MediaSnapshot) {
        let key = "\(snapshot.title)|\(snapshot.artist)|\(snapshot.album)"
        // Also re-evaluated when a generated stand-in is on screen and real
        // artwork has since arrived. Keying only on the track meant the
        // placeholder drawn on the first poll — before the download finished —
        // could never be replaced until the track changed.
        let realArtworkArrived = artworkIsPlaceholder && snapshot.artworkData != nil
        guard key != artworkKey || artwork == nil || realArtworkArrived else { return }
        artworkKey = key

        guard snapshot.hasTrack else {
            artwork = nil
            artworkIsPlaceholder = false
            return
        }
        if let data = snapshot.artworkData, let image = NSImage(data: data) {
            artwork = image
            artworkIsPlaceholder = false
        } else {
            // Generated stand-in keeps the Now Playing pane composed even when a
            // source cannot hand over a real cover.
            artwork = ArtworkGenerator.fallbackImage(for: key)
            artworkIsPlaceholder = true
        }
    }

    /// Preview/test seam: installs a snapshot without starting a refresh loop.
    func previewSeed(_ snapshot: MediaSnapshot, availability: MediaAvailability = .ready) {
        self.snapshot = snapshot
        self.availability = availability
        updateArtwork(for: snapshot)
    }

    private static func makeController(for source: MediaSourceChoice) -> MediaController {
        switch source {
        case .automatic: AutomaticMediaController()
        case .demo: DemoMediaController()
        case .musicApp: AppleMediaController.music()
        case .tv: AppleMediaController.tv()
        case .spotify: SpotifyMediaController()
        case .safari: SafariMediaController()
        case .chrome: ChromiumMediaController.chrome()
        case .brave: ChromiumMediaController.brave()
        }
    }
}
