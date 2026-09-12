//
//  ChromiumMediaController.swift
//  Aperture
//
//  Reads playback out of a Chromium browser — Chrome, Brave, and anything else
//  that ships the same `scripting.sdef`.
//
//  Structurally identical to ``SafariMediaController`` and for the same reason:
//  no browser publishes playback state as a scriptable property, so the only way
//  in is running a snippet in a tab. Chromium spells that `execute javascript`
//  where Safari spells it `do JavaScript`, which is the whole difference — the
//  snippet itself lives in ``WebMediaScript``.
//
//  Chrome and Brave each need View ▸ Developer ▸ "Allow JavaScript from Apple
//  Events" turned on, exactly as Safari does.
//

import AppKit
import Foundation
import OSLog

actor ChromiumMediaController: MediaController {

    nonisolated let displayName: String
    /// No skip, no shuffle: those belong to the site, not the media element.
    nonisolated var capabilities: MediaCapabilities { [.transport, .seek, .artwork] }

    private let bundleID: String
    private let log: Logger
    private let runner = AppleScriptRunner()
    private let artworkFetcher = ArtworkFetcher()

    private var lastSnapshot: MediaSnapshot = .empty
    private var artworkCache: [String: Data] = [:]
    private var pendingArtworkURL: URL?
    private var authorizationDenied = false
    /// When the browser last refused to run a snippet.
    ///
    /// Time-boxed rather than latched: the user can turn "Allow JavaScript from
    /// Apple Events" on at any moment, and a permanent flag meant they had to
    /// restart Aperture before it would notice. Re-checking on a slow cadence
    /// costs one Apple event a minute and saves that restart.
    private var refusedAt: Date?
    private static let refusalRetryInterval: TimeInterval = 60

    private var javaScriptBlocked: Bool {
        guard let refusedAt else { return false }
        return Date().timeIntervalSince(refusedAt) < Self.refusalRetryInterval
    }
    private var rememberedTab: TabAddress?
    /// When every tab was last examined.
    ///
    /// A sweep runs a snippet in *every* open tab, which is by far the most
    /// expensive thing this app does — measured at 20% of a core when a paused
    /// tab caused one on every poll. Trusting only a playing tab is right, but
    /// the search that follows has to be rationed.
    private var lastTabSweep = Date.distantPast
    /// Grows each time a sweep finds nothing playing, and resets the moment one
    /// does. A tab that has merely been played holds the slot indefinitely —
    /// paused Netflix, a finished video — and re-searching every few seconds for
    /// something that is not there costs a snippet in every open tab, measured
    /// at a couple of percent of a core doing nothing useful.
    private var tabSweepInterval: TimeInterval = 5
    private static let minimumTabSweepInterval: TimeInterval = 5
    private static let maximumTabSweepInterval: TimeInterval = 45

    private struct TabAddress: Equatable, Sendable {
        var window: Int
        var tab: Int
    }

    init(bundleID: String, displayName: String) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.log = Logger(subsystem: ApertureInfo.bundleIdentifier, category: "Chromium")
    }

    static func chrome() -> ChromiumMediaController {
        ChromiumMediaController(bundleID: "com.google.Chrome", displayName: "Google Chrome")
    }

    static func brave() -> ChromiumMediaController {
        ChromiumMediaController(bundleID: "com.brave.Browser", displayName: "Brave Browser")
    }

    // MARK: - MediaController

    func availability() async -> MediaAvailability {
        if authorizationDenied {
            return .needsAuthorization(
                reason: "Aperture needs permission to control \(displayName). Grant it in System Settings ▸ Privacy & Security ▸ Automation."
            )
        }
        if javaScriptBlocked {
            return .needsAuthorization(
                reason: "Turn on \(displayName) ▸ View ▸ Developer ▸ Allow JavaScript from Apple Events."
            )
        }
        guard isRunning else { return .idle(reason: "\(displayName) isn't running.") }
        return .ready
    }

    func volume() async -> Double? { nil }

    func snapshot() async -> MediaSnapshot {
        // Once the browser has said it will not run snippets, stop asking. Each
        // sweep is one Apple event per tab, and the answer will not change until
        // the user flips the setting — which `resetAuthorizationState` clears.
        guard !javaScriptBlocked else { return .empty }
        guard isRunning else {
            lastSnapshot = .empty
            rememberedTab = nil
            return .empty
        }

        // Only while it is still *playing*. A tab that has merely been played
        // reads back happily as paused, and trusting that held the slot for
        // ever: starting a video in another tab was never noticed, because the
        // sweep that would have found it never ran.
        var pausedFallback: MediaSnapshot?
        if let remembered = rememberedTab, let snapshot = await read(at: remembered) {
            if snapshot.isPlaying {
                lastSnapshot = snapshot
                return snapshot
            }
            pausedFallback = snapshot
        }

        // A paused tab is still worth showing, and showing it costs one event.
        // Hunting for a better one costs a snippet per tab, so that waits.
        if let pausedFallback, Date().timeIntervalSince(lastTabSweep) < tabSweepInterval {
            lastSnapshot = pausedFallback
            return pausedFallback
        }
        lastTabSweep = Date()

        guard let found = await sweepForPlayingTab() else {
            if let pausedFallback {
                lastSnapshot = pausedFallback
                return pausedFallback
            }
            rememberedTab = nil
            lastSnapshot = .empty
            tabSweepInterval = min(tabSweepInterval * 2, Self.maximumTabSweepInterval)
            return .empty
        }
        rememberedTab = found.address
        lastSnapshot = found.snapshot
        tabSweepInterval = found.snapshot.isPlaying
            ? Self.minimumTabSweepInterval
            : min(tabSweepInterval * 2, Self.maximumTabSweepInterval)
        return found.snapshot
    }

    func send(_ command: MediaCommand) async {
        guard let tab = rememberedTab else { return }
        let body: String
        switch command {
        case .playPause: body = WebMediaScript.togglePlayback
        case .seek(let position): body = WebMediaScript.seek(to: position)
        case .next, .previous, .toggleShuffle, .setVolume: return
        }
        if case .failure(let error) = await runner.runReturningString(script(body, at: tab)) {
            handle(error)
        }
    }

    @discardableResult
    func refreshArtworkIfNeeded() async -> Data? {
        let key = "\(lastSnapshot.title)|\(lastSnapshot.artist)|\(lastSnapshot.album)"
        if let cached = artworkCache[key] { return cached }
        guard lastSnapshot.hasTrack, let url = pendingArtworkURL else { return nil }

        pendingArtworkURL = nil
        guard let data = await artworkFetcher.data(for: url) else { return nil }
        if artworkCache.count > 8 { artworkCache.removeAll(keepingCapacity: true) }
        artworkCache[key] = data
        lastSnapshot.artworkData = data
        return data
    }

    // MARK: - Scripting

    private var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private func script(_ body: String, at tab: TabAddress) -> String {
        """
        tell application id "\(bundleID)"
            try
                return (execute tab \(tab.tab) of window \(tab.window) javascript "\(WebMediaScript.escapedForAppleScript(body))")
            on error errorMessage
                return "\(WebMediaScript.errorPrefix)" & errorMessage
            end try
        end tell
        """
    }

    private func read(at tab: TabAddress) async -> MediaSnapshot? {
        switch await runner.runReturningString(script(WebMediaScript.reader, at: tab)) {
        case .failure(let error):
            handle(error)
            return nil
        case .success(let raw):
            switch WebMediaScript.classify(raw) {
            case .refused(let message):
                if WebMediaScript.indicatesJavaScriptBlocked(message) {
                    refusedAt = Date()
                    log.notice("\(self.displayName, privacy: .public) refuses JavaScript from Apple Events: \(message, privacy: .public)")
                }
                return nil
            case .output(let body):
                guard let reading = WebMediaScript.parse(body) else { return nil }
                return makeSnapshot(from: reading)
            }
        }
    }

    /// Finds the tab that is playing, in a single Apple event.
    ///
    /// This used to run one script per tab. Because the tab index is baked into
    /// the script text, every tab meant a *different* source string — a
    /// separate compile, and a separate XProtect malware scan of the buffer.
    /// With a browser full of tabs that was the app's largest cost in both CPU
    /// and memory. One script that walks the tabs itself compiles once and
    /// costs one round trip however many tabs are open.
    private func sweepForPlayingTab() async -> (address: TabAddress, snapshot: MediaSnapshot)? {
        let escaped = WebMediaScript.escapedForAppleScript(WebMediaScript.reader)
        let script = """
        set delim to (ASCII character 9)
        tell application id "\(bundleID)"
            set fallback to ""
            repeat with w from 1 to (count of windows)
                repeat with t from 1 to (count of tabs of window w)
                    try
                        set r to (execute tab t of window w javascript "\(escaped)")
                        if r is not "" then
                            set rowText to (w as text) & delim & (t as text) & delim & r
                            if r starts with "playing" then return rowText
                            if fallback is "" then set fallback to rowText
                        end if
                    end try
                end repeat
            end repeat
            return fallback
        end tell
        """

        guard case .success(let raw) = await runner.runReturningString(script) else { return nil }
        let fields = raw.components(separatedBy: "\t")
        guard fields.count > 3, let window = Int(fields[0]), let tab = Int(fields[1]) else { return nil }

        // Fields 2 onward are the reader's own output, re-joined.
        let body = fields.dropFirst(2).joined(separator: "\t")
        switch WebMediaScript.classify(body) {
        case .refused(let message):
            if WebMediaScript.indicatesJavaScriptBlocked(message) {
                refusedAt = Date()
                log.notice("\(self.displayName, privacy: .public) refuses JavaScript from Apple Events: \(message, privacy: .public)")
            }
            return nil
        case .output(let output):
            guard let reading = WebMediaScript.parse(output) else { return nil }
            return (TabAddress(window: window, tab: tab), makeSnapshot(from: reading))
        }
    }

    private func makeSnapshot(from reading: WebMediaScript.Reading) -> MediaSnapshot {
        let key = "\(reading.title)|\(reading.artist)|\(reading.album)"
        if artworkCache[key] == nil { pendingArtworkURL = reading.artworkURL }

        let transportChanged = lastSnapshot.title != reading.title
            || lastSnapshot.isPlaying != reading.isPlaying

        return MediaSnapshot(
            title: reading.title,
            artist: reading.artist,
            album: reading.album,
            isPlaying: reading.isPlaying,
            duration: reading.duration,
            elapsed: reading.elapsed,
            sampledAt: Date(),
            lastTransportChange: transportChanged ? Date() : lastSnapshot.lastTransportChange,
            artworkData: artworkCache[key],
            sourceName: displayName,
            isExplicit: false,
            isShuffled: false
        )
    }

    private func handle(_ error: AppleScriptRunner.ScriptError) {
        if error.isAuthorizationFailure {
            authorizationDenied = true
            log.notice("Automation permission for \(self.displayName, privacy: .public) is not granted.")
        } else if error.message.localizedCaseInsensitiveContains("javascript") {
            refusedAt = Date()
            log.notice("\(self.displayName, privacy: .public) refuses JavaScript from Apple Events.")
        } else {
            log.debug("\(self.displayName, privacy: .public) script failed: \(error.message, privacy: .public)")
        }
    }

    func resetAuthorizationState() {
        authorizationDenied = false
        refusedAt = nil
    }
}
