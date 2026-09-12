//
//  SafariMediaController.swift
//  Aperture
//
//  Reads playback out of Safari tabs.
//
//  Safari is the awkward one. Its scripting dictionary declares no playback
//  state at all — no "now playing", no per-tab audio flag, nothing — so unlike
//  Music and Spotify there is no property to read. The single opening is
//  `do JavaScript`, which runs a snippet inside a tab and hands back a string.
//
//  That carries two costs the other sources do not have, and both are surfaced
//  to the user rather than hidden:
//
//  * It needs Safari's "Allow JavaScript from Apple Events", which lives behind
//    the Develop menu and is off until the user turns it on. Without it every
//    call fails and this source reports why.
//  * A snippet has to be run *per tab* to find the one that is playing. Tabs are
//    therefore swept sparingly and the winner is remembered, so the steady state
//    is one Apple event per poll rather than one per open tab.
//
//  What comes back is whatever the page publishes through the Media Session API
//  — the same metadata Safari shows on the Touch Bar and in Control Centre —
//  falling back to the document title and the first playing media element.
//

import AppKit
import Foundation
import OSLog

actor SafariMediaController: MediaController {

    nonisolated let displayName = "Safari"
    /// No skip and no shuffle: those are site-specific, and there is no general
    /// way to press "next" on an arbitrary page. Play/pause and seek work
    /// because they are properties of the media element itself.
    nonisolated var capabilities: MediaCapabilities { [.transport, .seek, .artwork] }

    private static let targetBundleID = "com.apple.Safari"
    private let log = Logger(subsystem: ApertureInfo.bundleIdentifier, category: "Safari")

    private let runner = AppleScriptRunner()
    private var lastSnapshot: MediaSnapshot = .empty
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
    private let artworkFetcher = ArtworkFetcher()
    private var artworkCache: [String: Data] = [:]
    /// Artwork address published by the page, kept aside so the fetch happens
    /// off the snapshot path.
    private var pendingArtworkURL: URL?
    /// Where playback was last found, so the common case costs one Apple event.
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

    // MARK: - MediaController

    func availability() async -> MediaAvailability {
        if authorizationDenied {
            return .needsAuthorization(
                reason: "Aperture needs permission to control Safari. Grant it in System Settings ▸ Privacy & Security ▸ Automation."
            )
        }
        if javaScriptBlocked {
            return .needsAuthorization(
                reason: "Turn on Safari ▸ Settings ▸ Advanced ▸ Show features for web developers, then Develop ▸ Allow JavaScript from Apple Events."
            )
        }
        guard isRunning else { return .idle(reason: "Safari isn't running.") }
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
        case .playPause:
            body = "var e=__ap_el();if(e){e.paused?e.play():e.pause();}"
        case .seek(let position):
            body = "var e=__ap_el();if(e){e.currentTime=\(position.rounded());}"
        case .next, .previous, .toggleShuffle, .setVolume:
            // Not expressible for an arbitrary page.
            return
        }

        let script = javaScript(Self.elementHelper + body + "''", at: tab)
        if case .failure(let error) = await runner.runReturningString(script) {
            handle(error)
        }
    }

    // MARK: - Scripting

    private var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.targetBundleID).isEmpty
    }

    /// Finds the element actually carrying playback: the first unpaused one,
    /// else the first that has been played at all.
    private static let elementHelper = """
    function __ap_el(){var n=document.querySelectorAll('video,audio');\
    for(var i=0;i<n.length;i++){if(!n[i].paused&&!n[i].ended)return n[i];}\
    for(var j=0;j<n.length;j++){if(n[j].currentTime>0)return n[j];}return null;}
    """

    /// Returns tab-delimited fields, or an empty string when the page has no
    /// media. Media Session metadata is preferred because a page's title is
    /// usually decorated ("(1) Artist - Title - YouTube").
    private static let readerScript = elementHelper + """
    var e=__ap_el();\
    var m=(navigator.mediaSession&&navigator.mediaSession.metadata)||null;\
    if(!e&&!m)''; else {\
    var t=(m&&m.title)?m.title:document.title;\
    var a=(m&&m.artist)?m.artist:'';\
    var b=(m&&m.album)?m.album:'';\
    var d=e?(isFinite(e.duration)?e.duration:0):0;\
    var p=e?e.currentTime:0;\
    var s=e?(e.paused?'paused':'playing'):'paused';\
    var g='';\
    if(m&&m.artwork&&m.artwork.length){g=m.artwork[m.artwork.length-1].src||'';}\
    [s,t,a,b,d,p,g].join('\\t');}
    """

    private func javaScript(_ body: String, at tab: TabAddress) -> String {
        // AppleScript string literals take backslash and quote escapes, so the
        // snippet is escaped once here rather than being hand-quoted above.
        let escaped = body
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        tell application id "\(Self.targetBundleID)"
            try
                return (do JavaScript "\(escaped)" in tab \(tab.tab) of window \(tab.window))
            on error errorMessage
                return "\(WebMediaScript.errorPrefix)" & errorMessage
            end try
        end tell
        """
    }

    private func read(at tab: TabAddress) async -> MediaSnapshot? {
        switch await runner.runReturningString(javaScript(Self.readerScript, at: tab)) {
        case .failure(let error):
            handle(error)
            return nil
        case .success(let raw):
            switch WebMediaScript.classify(raw) {
            case .refused(let message):
                if WebMediaScript.indicatesJavaScriptBlocked(message) {
                    refusedAt = Date()
                    log.notice("Safari refuses JavaScript from Apple Events: \(message, privacy: .public)")
                }
                return nil
            case .output(let body):
                return parse(body)
            }
        }
    }

    /// Walks every tab of every window until one reports media.
    ///
    /// Only reached when the remembered tab has gone quiet, so this is the cold
    /// path rather than the steady state.
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
        tell application id "\(Self.targetBundleID)"
            set fallback to ""
            repeat with w from 1 to (count of windows)
                repeat with t from 1 to (count of tabs of window w)
                    try
                        set r to (do JavaScript "\(escaped)" in tab t of window w)
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
                log.notice("Safari refuses JavaScript from Apple Events: \(message, privacy: .public)")
            }
            return nil
        case .output(let output):
            guard let reading = WebMediaScript.parse(output) else { return nil }
            return (TabAddress(window: window, tab: tab), makeSnapshot(from: reading))
        }
    }

    /// Builds a snapshot from an already-parsed reading.
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

    private func parse(_ raw: String) -> MediaSnapshot? {
        let fields = raw.components(separatedBy: "\t")
        guard fields.count >= 6 else { return nil }

        let title = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        let isPlaying = fields[0].localizedCaseInsensitiveContains("playing")
        let duration = Double(fields[4]) ?? 0
        let position = Double(fields[5]) ?? 0
        let transportChanged = lastSnapshot.title != title || lastSnapshot.isPlaying != isPlaying

        // The address comes from the page, so it is only ever noted here and
        // vetted by ``ArtworkFetcher`` before anything is requested.
        let key = "\(title)|\(fields[2])|\(fields[3])"
        if fields.count > 6, artworkCache[key] == nil {
            pendingArtworkURL = URL(string: fields[6].trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return MediaSnapshot(
            title: title,
            artist: fields[2],
            album: fields[3],
            isPlaying: isPlaying,
            duration: duration > 0 ? duration : nil,
            elapsed: position,
            sampledAt: Date(),
            lastTransportChange: transportChanged ? Date() : lastSnapshot.lastTransportChange,
            artworkData: artworkCache[key],
            sourceName: displayName,
            isExplicit: false,
            isShuffled: false
        )
    }

    /// Downloads the cover the page advertised, off the snapshot path so a slow
    /// host never delays the overlay.
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

    private func handle(_ error: AppleScriptRunner.ScriptError) {
        if error.isAuthorizationFailure {
            authorizationDenied = true
            log.notice("Automation permission for Safari is not granted.")
        } else if error.message.localizedCaseInsensitiveContains("javascript") {
            // Safari's own refusal when the Develop-menu switch is off.
            refusedAt = Date()
            log.notice("Safari refuses JavaScript from Apple Events; the Develop-menu switch is off.")
        } else {
            log.debug("Safari script failed: \(error.message, privacy: .public)")
        }
    }

    func resetAuthorizationState() {
        authorizationDenied = false
        refusedAt = nil
    }
}
