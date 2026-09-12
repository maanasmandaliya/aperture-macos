//
//  DemoMediaController.swift
//  Aperture
//
//  A fully functional in-memory player. It is the default source: it needs no
//  permissions, drives every Now Playing control for real, and gives previews
//  and tests a deterministic thing to render.
//

import AppKit
import Foundation

actor DemoMediaController: MediaController {

    nonisolated let displayName = "Demo player"
    nonisolated var capabilities: MediaCapabilities { .all }

    private struct Track {
        let title: String
        let artist: String
        let album: String
        let duration: TimeInterval
        let seed: ArtworkSeed
        let isExplicit: Bool
    }

    private let tracks: [Track] = [
        Track(title: "Slow Meridian", artist: "Halden Cross", album: "Northlight",
              duration: 214, seed: ArtworkSeed(hue: 0.71, secondaryHue: 0.79, angle: 0.2),
              isExplicit: false),
        Track(title: "Paper Harbour", artist: "Ilse Verrant", album: "Tideline",
              duration: 187, seed: ArtworkSeed(hue: 0.52, secondaryHue: 0.43, angle: 0.7),
              isExplicit: true),
        Track(title: "Ferrous", artist: "Modal Atlas", album: "Field Notes",
              duration: 251, seed: ArtworkSeed(hue: 0.08, secondaryHue: 0.95, angle: 0.45),
              isExplicit: false),
    ]

    private var index = 0
    private var isShuffled = false
    private var isPlaying = true
    private var elapsed: TimeInterval = 37
    private var sampledAt = Date()
    private var lastTransportChange = Date()
    private var outputVolume: Double = 0.62
    private var artworkCache: [Int: Data] = [:]

    func snapshot() async -> MediaSnapshot {
        advancePlayhead()
        let track = tracks[index]
        return MediaSnapshot(
            title: track.title,
            artist: track.artist,
            album: track.album,
            isPlaying: isPlaying,
            duration: track.duration,
            elapsed: elapsed,
            sampledAt: sampledAt,
            lastTransportChange: lastTransportChange,
            artworkData: artwork(for: index, seed: track.seed),
            sourceName: displayName,
            isExplicit: track.isExplicit,
            isShuffled: isShuffled
        )
    }

    func availability() async -> MediaAvailability { .ready }

    func volume() async -> Double? { outputVolume }

    func send(_ command: MediaCommand) async {
        advancePlayhead()
        switch command {
        case .playPause:
            isPlaying.toggle()
            lastTransportChange = Date()
        case .next:
            index = nextIndex()
            resetPlayhead()
        case .previous:
            // Match the familiar transport behaviour: restart the track first,
            // only stepping back when already near the beginning.
            if elapsed > 4 {
                resetPlayhead()
            } else {
                index = (index - 1 + tracks.count) % tracks.count
                resetPlayhead()
            }
        case .seek(let position):
            elapsed = min(max(position, 0), tracks[index].duration)
            sampledAt = Date()
        case .setVolume(let level):
            outputVolume = min(max(level, 0), 1)
        case .toggleShuffle:
            isShuffled.toggle()
        }
    }

    /// Shuffle picks any *other* track, so "next" always actually moves.
    private func nextIndex() -> Int {
        guard isShuffled, tracks.count > 1 else { return (index + 1) % tracks.count }
        var candidate = index
        while candidate == index { candidate = Int.random(in: 0..<tracks.count) }
        return candidate
    }

    private func resetPlayhead() {
        elapsed = 0
        sampledAt = Date()
        lastTransportChange = Date()
        isPlaying = true
    }

    /// Rolls the playhead forward and wraps to the next track, so the demo
    /// source behaves like a real queue over a long session.
    private func advancePlayhead() {
        let now = Date()
        guard isPlaying else {
            sampledAt = now
            return
        }
        elapsed += now.timeIntervalSince(sampledAt)
        sampledAt = now
        if elapsed >= tracks[index].duration {
            index = nextIndex()
            elapsed = 0
            lastTransportChange = now
        }
    }

    private func artwork(for index: Int, seed: ArtworkSeed) -> Data? {
        if let cached = artworkCache[index] { return cached }
        guard let data = ArtworkGenerator.makeArtwork(seed: seed, side: 320) else { return nil }
        artworkCache[index] = data
        return data
    }
}
