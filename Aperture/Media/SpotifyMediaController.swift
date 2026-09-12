//
//  SpotifyMediaController.swift
//  Aperture
//
//  Reads and drives Spotify through AppleScript.
//
//  Same reasoning as ``AppleMediaController``: the system-wide "now playing"
//  framework is private, so the only public route to another app's playback is
//  its own scripting interface. Spotify ships one — `Spotify.sdef` declares
//  `player state`, `player position`, the current track's metadata and the
//  transport commands — and macOS gates it behind an Automation prompt the user
//  can revoke.
//
//  Two differences from Music are worth knowing, because both are silent
//  corruption if missed:
//
//  * Spotify reports track `duration` in **milliseconds**, where Music uses
//    seconds. `player position` is in seconds in both.
//  * Spotify has no "shuffle enabled" separate from `shuffling`, and older
//    builds throw on `shuffling` entirely, so it is read defensively.
//

import AppKit
import Foundation
import OSLog

actor SpotifyMediaController: MediaController {

    nonisolated let displayName = "Spotify"
    /// Volume is deliberately absent: the hub's slider drives *system* output,
    /// as it does for Music, rather than one app's internal level.
    nonisolated var capabilities: MediaCapabilities { [.transport, .skip, .seek, .artwork, .shuffle] }

    private static let targetBundleID = "com.spotify.client"
    private let log = Logger(subsystem: ApertureInfo.bundleIdentifier, category: "Spotify")

    private let runner = AppleScriptRunner()
    private var lastSnapshot: MediaSnapshot = .empty
    private var artworkCache: [String: Data] = [:]
    private var authorizationDenied = false
    /// Set once `artwork` has been seen to fail, so a source that cannot supply
    /// image data over Apple Events is asked only once rather than every track.
    private var artworkUnavailable = false
    private let artworkFetcher = ArtworkFetcher()

    // MARK: - MediaController

    func availability() async -> MediaAvailability {
        if authorizationDenied {
            return .needsAuthorization(
                reason: "Aperture needs permission to control Spotify. Grant it in System Settings ▸ Privacy & Security ▸ Automation."
            )
        }
        guard isRunning else { return .idle(reason: "Spotify isn't running.") }
        return .ready
    }

    func volume() async -> Double? { nil }

    func snapshot() async -> MediaSnapshot {
        guard isRunning else {
            lastSnapshot = .empty
            return .empty
        }

        // One round trip for everything: each Apple event is expensive and can
        // stall on a busy Spotify process.
        let script = """
        tell application id "\(Self.targetBundleID)"
            if player state is stopped then return "stopped"
            set trackName to ""
            set trackArtist to ""
            set trackAlbum to ""
            set trackDuration to 0
            try
                set trackName to name of current track
                set trackArtist to artist of current track
                set trackAlbum to album of current track
                set trackDuration to duration of current track
            end try
            set stateText to (player state as text)
            set positionValue to player position
            set shuffleState to "false"
            try
                set shuffleState to (shuffling as text)
            end try
            return stateText & "\t" & trackName & "\t" & trackArtist & "\t" & trackAlbum & "\t" & (trackDuration as text) & "\t" & (positionValue as text) & "\t" & shuffleState
        end tell
        """

        switch await runner.runReturningString(script) {
        case .failure(let error):
            handle(error)
            return lastSnapshot
        case .success(let raw):
            guard let parsed = parse(raw) else {
                lastSnapshot = .empty
                return .empty
            }
            lastSnapshot = parsed
            return parsed
        }
    }

    func send(_ command: MediaCommand) async {
        let body: String
        switch command {
        case .playPause: body = "playpause"
        case .next: body = "next track"
        case .previous: body = "previous track"
        case .seek(let position): body = "set player position to \(position.rounded())"
        case .toggleShuffle: body = "set shuffling to not shuffling"
        case .setVolume: return // Handled by the system audio controller.
        }

        let script = "tell application id \"\(Self.targetBundleID)\" to \(body)"
        if case .failure(let error) = await runner.runReturningString(script) {
            handle(error)
        }
    }

    // MARK: - Helpers

    /// Checked through NSWorkspace, never by scripting: addressing a non-running
    /// app would *launch* Spotify, which a background poll must never do.
    private var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.targetBundleID).isEmpty
    }

    /// Spotify's own units, converted to Aperture's.
    ///
    /// `duration` arrives in milliseconds. Treating it as seconds would put a
    /// three-minute track at three thousand, so the scrubber would sit frozen
    /// near zero and the remaining time would read in hours.
    nonisolated static func durationSeconds(fromMilliseconds raw: Double) -> Double? {
        guard raw > 0 else { return nil }
        return raw / 1000
    }

    private func parse(_ raw: String) -> MediaSnapshot? {
        guard raw != "stopped" else { return nil }
        let fields = raw.components(separatedBy: "\t")
        guard fields.count >= 6 else { return nil }

        let title = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        let isPlaying = fields[0].localizedCaseInsensitiveContains("playing")
        let duration = Self.durationSeconds(fromMilliseconds: Double(fields[4]) ?? 0)
        let position = Double(fields[5]) ?? 0
        let artist = fields[2]
        let album = fields[3]
        let shuffled = fields.count > 6 && fields[6].localizedCaseInsensitiveContains("true")

        let transportChanged = lastSnapshot.title != title || lastSnapshot.isPlaying != isPlaying

        return MediaSnapshot(
            title: title,
            artist: artist,
            album: album,
            isPlaying: isPlaying,
            duration: duration,
            elapsed: position,
            sampledAt: Date(),
            lastTransportChange: transportChanged ? Date() : lastSnapshot.lastTransportChange,
            artworkData: artworkCache["\(title)|\(artist)|\(album)"],
            sourceName: displayName,
            // Spotify's scripting interface exposes no explicit-content flag.
            isExplicit: false,
            isShuffled: shuffled
        )
    }

    /// Fetched only when the track changes; pulling image data on every snapshot
    /// would make the round trip far too slow.
    ///
    /// Tries the Apple Event `artwork` property first, since image data arriving
    /// over the existing scripting connection costs nothing extra. Current
    /// Spotify builds return nothing there, so the published `artwork url` is
    /// downloaded instead — the one network request Aperture makes, described in
    /// Privacy.md.
    @discardableResult
    func refreshArtworkIfNeeded() async -> Data? {
        guard lastSnapshot.hasTrack else { return nil }
        let key = "\(lastSnapshot.title)|\(lastSnapshot.artist)|\(lastSnapshot.album)"
        if let cached = artworkCache[key] { return cached }

        if !artworkUnavailable,
           let data = await artworkFromAppleEvent(),
           ArtworkFetcher.looksLikeImage(data) {
            store(data, for: key)
            return data
        }
        if let data = await artworkFromURL() {
            log.notice("Artwork came from Spotify's published URL.")
            store(data, for: key)
            return data
        }
        return nil
    }

    private func store(_ data: Data, for key: String) {
        if artworkCache.count > 8 { artworkCache.removeAll(keepingCapacity: true) }
        artworkCache[key] = data
        lastSnapshot.artworkData = data
    }

    private func artworkFromAppleEvent() async -> Data? {
        let script = """
        tell application id "\(Self.targetBundleID)"
            try
                return artwork of current track
            on error
                return missing value
            end try
        end tell
        """

        switch await runner.runReturningData(script) {
        case .success(let data):
            // Judged by content, not by emptiness: `missing value` still has
            // bytes, and treating those as a cover is what stops the URL
            // fallback from ever being reached.
            if let data, ArtworkFetcher.looksLikeImage(data) { return data }
            artworkUnavailable = true
            log.notice("Spotify's artwork property returned \(data?.count ?? 0, privacy: .public) non-image bytes; using its artwork URL instead.")
            return nil
        case .failure(let error):
            handle(error)
            if !error.isAuthorizationFailure { artworkUnavailable = true }
            return nil
        }
    }

    private func artworkFromURL() async -> Data? {
        let script = """
        tell application id "\(Self.targetBundleID)"
            try
                return artwork url of current track
            on error
                return ""
            end try
        end tell
        """

        guard case .success(let raw) = await runner.runReturningString(script) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        return await artworkFetcher.data(for: url)
    }

    private func handle(_ error: AppleScriptRunner.ScriptError) {
        if error.isAuthorizationFailure {
            authorizationDenied = true
            log.notice("Automation permission for Spotify is not granted.")
        } else {
            log.debug("Spotify script failed: \(error.message, privacy: .public)")
        }
    }

    func resetAuthorizationState() {
        authorizationDenied = false
        artworkUnavailable = false
    }
}
