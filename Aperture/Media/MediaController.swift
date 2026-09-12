//
//  MediaController.swift
//  Aperture
//
//  The boundary every playback source sits behind.
//

import Foundation

enum MediaCommand: Sendable, Equatable {
    case playPause
    case next
    case previous
    case seek(TimeInterval)
    case setVolume(Double)
    case toggleShuffle
}

/// Capabilities differ sharply between sources (the demo player can do
/// everything; a scripted app may refuse seeking), so the UI asks rather than
/// assumes, and disables controls it cannot drive.
struct MediaCapabilities: OptionSet, Sendable {
    let rawValue: Int
    static let transport = MediaCapabilities(rawValue: 1 << 0)
    static let skip = MediaCapabilities(rawValue: 1 << 1)
    static let seek = MediaCapabilities(rawValue: 1 << 2)
    static let volume = MediaCapabilities(rawValue: 1 << 3)
    static let artwork = MediaCapabilities(rawValue: 1 << 4)
    static let shuffle = MediaCapabilities(rawValue: 1 << 5)

    static let all: MediaCapabilities = [.transport, .skip, .seek, .volume, .artwork, .shuffle]
}

enum MediaAvailability: Equatable, Sendable {
    case ready
    /// Source app is not running, or has no track loaded.
    case idle(reason: String)
    /// Blocked on a permission the user has to grant.
    case needsAuthorization(reason: String)
    /// Cannot work on this system at all.
    case unavailable(reason: String)

    var isReady: Bool { self == .ready }
}

/// A playback source. Conformers are actors or `@MainActor` types; the protocol
/// is async so an AppleScript round trip never blocks the overlay.
protocol MediaController: AnyObject, Sendable {
    var displayName: String { get }
    var capabilities: MediaCapabilities { get }

    /// Best-effort current state. Returning `.empty` means "nothing playing".
    func snapshot() async -> MediaSnapshot
    func availability() async -> MediaAvailability
    func send(_ command: MediaCommand) async
    /// Output volume 0…1 if the source manages its own, otherwise `nil`.
    func volume() async -> Double?
}

extension MediaController {
    /// What the source can drive *right now*.
    ///
    /// Identical to ``capabilities`` for a source that talks to one app. The
    /// automatic source overrides it, because what it can do changes with
    /// whichever app it is currently following.
    func activeCapabilities() async -> MediaCapabilities { capabilities }
}
