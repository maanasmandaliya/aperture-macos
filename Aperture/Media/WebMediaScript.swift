//
//  WebMediaScript.swift
//  Aperture
//
//  The snippet browsers are asked to run, and the parsing of what comes back.
//
//  Shared between Safari and the Chromium browsers because the interesting part
//  — what a *page* can tell you about its playback — is identical; only the
//  AppleScript wrapper differs. Kept out of both controllers so the JavaScript
//  and its field order live in exactly one place: they have to agree, and a
//  silently reordered column would mean artists showing up as albums.
//

import Foundation

enum WebMediaScript {

    /// Finds the element actually carrying playback: the first unpaused one,
    /// else the first that has been played at all.
    private static let elementHelper = """
    function __ap_el(){var n=document.querySelectorAll('video,audio');\
    for(var i=0;i<n.length;i++){if(!n[i].paused&&!n[i].ended)return n[i];}\
    for(var j=0;j<n.length;j++){if(n[j].currentTime>0)return n[j];}return null;}
    """

    /// Returns tab-delimited fields, or an empty string when the page has no
    /// media.
    ///
    /// Media Session metadata is preferred over the document title, which is
    /// usually decorated — "(1) Artist - Title - YouTube" — and would put the
    /// notification count in the pill.
    static let reader = elementHelper + """
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

    static let togglePlayback = elementHelper + "var e=__ap_el();if(e){e.paused?e.play():e.pause();}''"

    static func seek(to position: TimeInterval) -> String {
        elementHelper + "var e=__ap_el();if(e){e.currentTime=\(position.rounded());}''"
    }

    /// What the reader returned, split out. Nil when the page has no media.
    struct Reading: Equatable, Sendable {
        var title: String
        var artist: String
        var album: String
        var isPlaying: Bool
        var duration: TimeInterval?
        var elapsed: TimeInterval
        var artworkURL: URL?
    }

    /// Pure, so the field order is pinned by tests rather than by hope.
    nonisolated static func parse(_ raw: String) -> Reading? {
        let fields = raw.components(separatedBy: "\t")
        guard fields.count >= 6 else { return nil }

        let title = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        let duration = Double(fields[4]) ?? 0
        var artwork: URL?
        if fields.count > 6 {
            let trimmed = fields[6].trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { artwork = URL(string: trimmed) }
        }

        return Reading(
            title: title,
            artist: fields[2],
            album: fields[3],
            isPlaying: fields[0].localizedCaseInsensitiveContains("playing"),
            duration: duration > 0 ? duration : nil,
            elapsed: Double(fields[5]) ?? 0,
            artworkURL: artwork
        )
    }

    /// Marks a failure the AppleScript caught itself.
    ///
    /// The wrapper has to keep its `try`, because a tab that simply cannot run
    /// a snippet — a PDF, the start page — is ordinary and must not be reported
    /// as a broken browser. But returning "" for *every* failure also hid the
    /// one that matters: a browser refusing Apple Events entirely. So the
    /// reason is carried back instead of discarded, and Swift decides.
    static let errorPrefix = "__APERTURE_ERR__"

    /// What a wrapper returned: either the snippet's output, or the reason the
    /// browser refused to run it.
    enum Outcome: Equatable, Sendable {
        case output(String)
        case refused(reason: String)
    }

    nonisolated static func classify(_ raw: String) -> Outcome {
        guard raw.hasPrefix(errorPrefix) else { return .output(raw) }
        return .refused(reason: String(raw.dropFirst(errorPrefix.count)))
    }

    /// Whether a browser's error means it refuses Apple Events outright, as
    /// opposed to a tab that just has nothing to run.
    nonisolated static func indicatesJavaScriptBlocked(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("javascript")
            || lowered.contains("not allowed")
            || lowered.contains("apple events")
    }

    /// Escapes the snippet for embedding in an AppleScript string literal.
    nonisolated static func escapedForAppleScript(_ body: String) -> String {
        body
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
