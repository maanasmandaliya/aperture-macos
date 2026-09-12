//
//  MediaControlTests.swift
//  ApertureTests
//

import XCTest
@testable import Aperture

final class MediaControlTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 780_000_000)

    // MARK: - Remaining time

    func testRemainingCountsDownFromTheDuration() {
        var snapshot = PreviewData.playingMedia
        snapshot.sampledAt = now
        snapshot.elapsed = 100
        snapshot.duration = 214

        XCTAssertEqual(snapshot.remaining(at: now)!, 114, accuracy: 0.001)
        XCTAssertEqual(snapshot.remaining(at: now.addingTimeInterval(14))!, 100, accuracy: 0.001)
    }

    func testRemainingNeverGoesNegative() {
        var snapshot = PreviewData.playingMedia
        snapshot.sampledAt = now
        snapshot.elapsed = 210
        snapshot.duration = 214
        XCTAssertEqual(snapshot.remaining(at: now.addingTimeInterval(600))!, 0, accuracy: 0.001)
    }

    func testRemainingIsUnknownWithoutADuration() {
        var snapshot = PreviewData.playingMedia
        snapshot.duration = nil
        XCTAssertNil(snapshot.remaining(at: now))
    }

    func testRemainingIsFrozenWhilePaused() {
        var snapshot = PreviewData.playingMedia
        snapshot.sampledAt = now
        snapshot.elapsed = 100
        snapshot.duration = 214
        snapshot.isPlaying = false
        XCTAssertEqual(snapshot.remaining(at: now.addingTimeInterval(30))!, 114, accuracy: 0.001)
    }

    // MARK: - Flags

    func testEmptySnapshotCarriesNoFlags() {
        XCTAssertFalse(MediaSnapshot.empty.isExplicit)
        XCTAssertFalse(MediaSnapshot.empty.isShuffled)
    }

    // MARK: - Track identity

    func testIdentityCombinesTitleArtistAndAlbum() {
        // Everything that reacts to "the track changed" — the header
        // cross-fade, the cover flip, the artwork cache — keys off this, so they
        // can never disagree about when a change happened.
        var snapshot = PreviewData.playingMedia
        snapshot.title = "A"; snapshot.artist = "B"; snapshot.album = "C"
        XCTAssertEqual(snapshot.identity, "A|B|C")
    }

    func testIdentityChangesWithAnyComponent() {
        let base = PreviewData.playingMedia
        for change in [\.title, \.artist, \.album] as [WritableKeyPath<MediaSnapshot, String>] {
            var other = base
            other[keyPath: change] += " (different)"
            XCTAssertNotEqual(other.identity, base.identity)
        }
    }

    func testIdentityIgnoresPlaybackState() {
        // Pausing or seeking is not a new track and must not flip the cover.
        var paused = PreviewData.playingMedia
        paused.isPlaying = false
        paused.elapsed += 42
        XCTAssertEqual(paused.identity, PreviewData.playingMedia.identity)
    }

    func testTwoDifferentTracksHaveDifferentIdentities() {
        XCTAssertNotEqual(PreviewData.playingMedia.identity, PreviewData.explicitMedia.identity)
    }

    // MARK: - Capabilities

    func testShuffleIsAdvertisedSeparatelyFromTransport() {
        XCTAssertTrue(MediaCapabilities.all.contains(.shuffle))
        let limited: MediaCapabilities = [.transport, .skip]
        XCTAssertFalse(limited.contains(.shuffle),
                       "A source without shuffle must leave the control disabled, not hidden")
    }

    // MARK: - Demo source

    func testDemoSourceReportsATrackAndHonoursTransport() async {
        let controller = DemoMediaController()
        let first = await controller.snapshot()
        XCTAssertTrue(first.hasTrack)
        XCTAssertTrue(first.isPlaying)

        await controller.send(.playPause)
        let paused = await controller.snapshot()
        XCTAssertFalse(paused.isPlaying)
    }

    func testDemoSourceTogglesShuffle() async {
        let controller = DemoMediaController()
        // Bound before asserting: XCTAssert takes an autoclosure, which cannot
        // contain `await`.
        let initial = await controller.snapshot().isShuffled
        XCTAssertFalse(initial)

        await controller.send(.toggleShuffle)
        let enabled = await controller.snapshot().isShuffled
        XCTAssertTrue(enabled)

        await controller.send(.toggleShuffle)
        let disabled = await controller.snapshot().isShuffled
        XCTAssertFalse(disabled)
    }

    func testDemoSourceNextAlwaysChangesTrackWhenShuffled() async {
        let controller = DemoMediaController()
        await controller.send(.toggleShuffle)

        // Shuffle picks any *other* track, so "next" must always move.
        for _ in 0..<12 {
            let before = await controller.snapshot().title
            await controller.send(.next)
            let after = await controller.snapshot().title
            XCTAssertNotEqual(before, after)
        }
    }

    func testDemoSourceMarksExactlyOneTrackExplicit() async {
        let controller = DemoMediaController()
        var explicitCount = 0
        var seen = Set<String>()
        for _ in 0..<6 {
            let snapshot = await controller.snapshot()
            if seen.insert(snapshot.title).inserted, snapshot.isExplicit { explicitCount += 1 }
            await controller.send(.next)
        }
        XCTAssertEqual(explicitCount, 1)
    }

    func testDemoSourceSeekClampsToTheTrack() async {
        let controller = DemoMediaController()
        await controller.send(.seek(-50))
        let atStart = await controller.snapshot().elapsed
        XCTAssertEqual(atStart, 0, accuracy: 0.5)

        let duration = await controller.snapshot().duration ?? 0
        await controller.send(.seek(duration + 500))
        let atEnd = await controller.snapshot().elapsed
        XCTAssertLessThanOrEqual(atEnd, duration + 0.5)
    }
}
