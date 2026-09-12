//
//  AppleMediaController.swift
//  Aperture
//
//  Reads and drives Apple's own players — Music and the TV app — through
//  AppleScript. Both expose the same scripting suite, so one implementation
//  covers them; where they differ, the script asks for whichever field exists.
//
//  Why AppleScript: the framework that reports "now playing" for arbitrary apps
//  (MediaRemote) is private, and Aperture uses only public API. Scripting a
//  running app is a documented, user-authorised path — macOS shows an Automation
//  prompt the first time, and the user can revoke it in System Settings.
//

import AppKit
import Foundation
import OSLog

actor AppleMediaController: MediaController {

    nonisolated let displayName: String
    /// No volume in either: Aperture drives system output volume instead, which
    /// is what the hub's slider is wired to. The TV app has no shuffle, so it
    /// does not advertise one — a dead button is worse than an absent one.
    nonisolated let capabilities: MediaCapabilities

    private let targetBundleID: String
    private let log = Logger(subsystem: ApertureInfo.bundleIdentifier, category: "AppleMedia")

    init(bundleID: String, displayName: String, capabilities: MediaCapabilities) {
        self.targetBundleID = bundleID
        self.displayName = displayName
        self.capabilities = capabilities
    }

    static func music() -> AppleMediaController {
        AppleMediaController(
            bundleID: "com.apple.Music",
            displayName: "Apple Music",
            capabilities: [.transport, .skip, .seek, .artwork, .shuffle]
        )
    }

    static func tv() -> AppleMediaController {
        AppleMediaController(
            bundleID: "com.apple.TV",
            displayName: "Apple TV",
            capabilities: [.transport, .skip, .seek, .artwork]
        )
    }

    private let runner = AppleScriptRunner()
    private var lastSnapshot: MediaSnapshot = .empty
    private var artworkCache: [String: Data] = [:]
    private var authorizationDenied = false

    // MARK: - MediaController

    func availability() async -> MediaAvailability {
        if authorizationDenied {
            return .needsAuthorization(
                reason: "Aperture needs permission to control \(displayName). Grant it in System Settings ▸ Privacy & Security ▸ Automation."
            )
        }
        guard isRunning else {
            return .idle(reason: "\(displayName) isn't running.")
        }
        return .ready
    }

    func volume() async -> Double? { nil }

    func snapshot() async -> MediaSnapshot {
        guard isRunning else {
            lastSnapshot = .empty
            return .empty
        }

        // One round trip for everything; each AppleScript call is expensive and
        // can block on a busy Music process.
        let script = """
        tell application id "\(targetBundleID)"
            if player state is stopped then return "stopped"
            set trackName to ""
            set trackArtist to ""
            set trackAlbum to ""
            set trackDuration to 0
            try
                set currentItem to current track
                set trackName to name of currentItem
                set trackAlbum to album of currentItem
                set trackDuration to duration of currentItem
            end try
            -- Music tracks have an artist; TV episodes have a show instead.
            try
                set trackArtist to artist of currentItem
            on error
                try
                    set trackArtist to show of currentItem
                end try
            end try
            set stateText to (player state as text)
            set positionValue to player position
            set shuffleState to "false"
            try
                set shuffleState to (shuffle enabled as text)
            end try
            return stateText & "\t" & trackName & "\t" & trackArtist & "\t" & trackAlbum & "\t" & (trackDuration as text) & "\t" & (positionValue as text) & "\t" & shuffleState
        end tell
        """

        let result = await runner.runReturningString(script)
        switch result {
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
        case .previous: body = "back track"
        case .seek(let position): body = "set player position to \(Int(position.rounded()))"
        case .toggleShuffle: body = "set shuffle enabled to not (shuffle enabled)"
        case .setVolume: return // Handled by the system audio controller.
        }

        let script = "tell application id \"\(targetBundleID)\" to \(body)"
        if case .failure(let error) = await runner.runReturningString(script) {
            handle(error)
        }
    }

    // MARK: - Helpers

    /// Checked via NSWorkspace rather than by scripting, because scripting a
    /// non-running app would *launch* Music — never acceptable from a poll.
    private var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: targetBundleID).isEmpty
    }

    private func parse(_ raw: String) -> MediaSnapshot? {
        guard raw != "stopped" else { return nil }
        let fields = raw.components(separatedBy: "\t")
        guard fields.count >= 6 else { return nil }

        let title = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        let isPlaying = fields[0].localizedCaseInsensitiveContains("playing")
        let duration = Double(fields[4]) ?? 0
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
            duration: duration > 0 ? duration : nil,
            elapsed: position,
            sampledAt: Date(),
            lastTransportChange: transportChanged ? Date() : lastSnapshot.lastTransportChange,
            artworkData: artworkCache["\(title)|\(artist)|\(album)"],
            sourceName: displayName,
            // Neither app exposes an explicit-content flag, so the badge stays
            // off for these sources rather than being guessed at.
            isExplicit: false,
            isShuffled: shuffled
        )
    }

    /// Artwork is fetched separately and only when the track changes — pulling
    /// image data on every snapshot would make the round trip far too slow.
    @discardableResult
    func refreshArtworkIfNeeded() async -> Data? {
        guard lastSnapshot.hasTrack else { return nil }
        let key = "\(lastSnapshot.title)|\(lastSnapshot.artist)|\(lastSnapshot.album)"
        if let cached = artworkCache[key] { return cached }

        let script = """
        tell application id "\(targetBundleID)"
            try
                return raw data of artwork 1 of current track
            on error
                return missing value
            end try
        end tell
        """

        if case .success(let data) = await runner.runReturningData(script),
           let data, ArtworkFetcher.looksLikeImage(data) {
            if artworkCache.count > 8 { artworkCache.removeAll(keepingCapacity: true) }
            artworkCache[key] = data
            lastSnapshot.artworkData = data
            return data
        }
        return nil
    }

    private func handle(_ error: AppleScriptRunner.ScriptError) {
        if error.isAuthorizationFailure {
            authorizationDenied = true
            log.notice("Automation permission for \(self.displayName, privacy: .public) is not granted.")
        } else {
            log.debug("\(self.displayName, privacy: .public) script failed: \(error.message, privacy: .public)")
        }
    }

    /// Clears the denied flag so the user can retry after granting permission.
    func resetAuthorizationState() { authorizationDenied = false }
}
