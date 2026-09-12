//
//  MediaSourceTests.swift
//  ApertureTests
//

import XCTest
@testable import Aperture

final class MediaSourceTests: XCTestCase {

    // MARK: - Spotify units

    /// Spotify reports track length in milliseconds where Music uses seconds.
    /// Missing this puts a 3-minute track at 205,000 "seconds": the scrubber
    /// would sit frozen at zero and the remaining time would read in days.
    func testSpotifyDurationsConvertFromMilliseconds() {
        XCTAssertEqual(SpotifyMediaController.durationSeconds(fromMilliseconds: 205_000) ?? 0,
                       205, accuracy: 0.001)
        XCTAssertEqual(SpotifyMediaController.durationSeconds(fromMilliseconds: 1_000) ?? 0,
                       1, accuracy: 0.001)
    }

    /// A track with no length reported must read as unknown, not as zero — the
    /// UI shows "--:--" for nil and a finished track for 0.
    func testAnAbsentSpotifyDurationIsNil() {
        XCTAssertNil(SpotifyMediaController.durationSeconds(fromMilliseconds: 0))
        XCTAssertNil(SpotifyMediaController.durationSeconds(fromMilliseconds: -1))
    }

    // MARK: - Source catalogue

    func testEverySourceIsSelectableAndNamed() {
        let sources = MediaSourceChoice.allCases
        XCTAssertTrue(sources.contains(.spotify))
        XCTAssertTrue(sources.contains(.safari))
        for source in sources {
            XCTAssertFalse(source.displayName.isEmpty)
            XCTAssertFalse(source.explanation.isEmpty, "\(source) needs to say what it costs the user")
        }
    }

    /// Raw values are persisted in defaults, so renaming one silently resets the
    /// user's choice to the default source.
    func testSourceRawValuesAreStable() {
        XCTAssertEqual(MediaSourceChoice.demo.rawValue, "demo")
        XCTAssertEqual(MediaSourceChoice.musicApp.rawValue, "musicApp")
        XCTAssertEqual(MediaSourceChoice.spotify.rawValue, "spotify")
        XCTAssertEqual(MediaSourceChoice.safari.rawValue, "safari")
        XCTAssertEqual(MediaSourceChoice.tv.rawValue, "tv")
    }

    @MainActor
    func testAnUnknownStoredSourceFallsBackToTheDefault() {
        let store = InMemoryPreferenceStore(seed: [PreferenceKey.mediaSource: "winamp"])
        let source = Preferences(store: store).mediaSource
        XCTAssertEqual(source, .demo)
    }

    // MARK: - Capabilities

    /// Safari can only drive the media element it found: there is no general way
    /// to press "next" on an arbitrary page, and advertising it would leave a
    /// live-looking button that does nothing.
    func testSafariAdvertisesOnlyWhatAPageCanDo() {
        let safari = SafariMediaController()
        XCTAssertTrue(safari.capabilities.contains(.transport))
        XCTAssertTrue(safari.capabilities.contains(.seek))
        XCTAssertFalse(safari.capabilities.contains(.skip))
        XCTAssertFalse(safari.capabilities.contains(.shuffle))
    }

    func testSpotifyAdvertisesFullTransport() {
        let spotify = SpotifyMediaController()
        for capability in [MediaCapabilities.transport, .skip, .seek, .shuffle] {
            XCTAssertTrue(spotify.capabilities.contains(capability))
        }
        XCTAssertFalse(spotify.capabilities.contains(.volume),
                       "The hub's slider drives system output, not one app's level")
    }
}

// MARK: - Which artwork addresses Aperture is willing to request

final class ArtworkFetcherTests: XCTestCase {

    private func fetchable(_ string: String) -> Bool {
        guard let url = URL(string: string) else { return false }
        return ArtworkFetcher.isFetchable(url)
    }

    func testOrdinaryCoverArtURLsAreAllowed() {
        XCTAssertTrue(fetchable("https://i.scdn.co/image/ab67616d0000b273abcdef"))
        XCTAssertTrue(fetchable("https://is1-ssl.mzstatic.com/image/thumb/cover.jpg"))
    }

    /// A Safari source takes its URL from whatever page is playing, so a page
    /// could otherwise aim Aperture at the machine it is running on.
    func testLoopbackAndPrivateAddressesAreRefused() {
        for address in [
            "https://localhost/cover.png",
            "https://app.localhost/cover.png",
            "https://printer.local/cover.png",
            "https://127.0.0.1/cover.png",
            "https://[::1]/cover.png",
            "https://10.0.0.5/cover.png",
            "https://192.168.1.20/cover.png",
            "https://169.254.169.254/latest/meta-data",
            "https://172.16.4.4/cover.png",
            "https://172.31.255.1/cover.png",
        ] {
            XCTAssertFalse(fetchable(address), "\(address) must not be requested")
        }
    }

    /// 172.x is only private in 16–31; the rest is ordinary public space and
    /// must not be swept up by an over-broad prefix check.
    func testPublic172AddressesAreStillAllowed() {
        XCTAssertTrue(fetchable("https://172.15.0.1/cover.png"))
        XCTAssertTrue(fetchable("https://172.32.0.1/cover.png"))
    }

    func testOnlyHTTPSIsRequested() {
        XCTAssertFalse(fetchable("http://i.scdn.co/image/cover.jpg"))
        XCTAssertFalse(fetchable("file:///etc/passwd"))
        XCTAssertFalse(fetchable("ftp://example.com/cover.jpg"))
        XCTAssertFalse(fetchable("data:image/png;base64,iVBORw0KGgo="))
    }

    func testAnAddressWithNoHostIsRefused() {
        XCTAssertFalse(fetchable("https:///cover.png"))
    }
}

// MARK: - Telling an image from four stray bytes

final class ArtworkContentTests: XCTestCase {

    private func data(_ bytes: [UInt8]) -> Data { Data(bytes + [UInt8](repeating: 0, count: 16)) }

    func testRealImageHeadersAreAccepted() {
        XCTAssertTrue(ArtworkFetcher.looksLikeImage(data([0x89, 0x50, 0x4E, 0x47])))            // PNG
        XCTAssertTrue(ArtworkFetcher.looksLikeImage(data([0xFF, 0xD8, 0xFF])))                  // JPEG
        XCTAssertTrue(ArtworkFetcher.looksLikeImage(data([0x47, 0x49, 0x46, 0x38])))            // GIF
        XCTAssertTrue(ArtworkFetcher.looksLikeImage(data([0x49, 0x49, 0x2A, 0x00])))            // TIFF LE
        XCTAssertTrue(ArtworkFetcher.looksLikeImage(data([0x4D, 0x4D, 0x00, 0x2A])))            // TIFF BE
        XCTAssertTrue(ArtworkFetcher.looksLikeImage(
            Data([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50])))                // WEBP
        XCTAssertTrue(ArtworkFetcher.looksLikeImage(
            Data([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63])))             // HEIC
    }

    /// The bug this exists for: Spotify's `artwork` Apple Event returns four
    /// bytes when there is no image. Accepting them as a cover meant the UI got
    /// something undecodable, drew its placeholder, and never fell back to the
    /// artwork URL — so covers silently never appeared.
    func testTheFourByteMissingValueIsRejected() {
        XCTAssertFalse(ArtworkFetcher.looksLikeImage(Data([0x6D, 0x73, 0x6E, 0x67])))
        XCTAssertFalse(ArtworkFetcher.looksLikeImage(Data()))
        XCTAssertFalse(ArtworkFetcher.looksLikeImage(Data([0x00])))
    }

    func testTextIsNotAnImage() {
        XCTAssertFalse(ArtworkFetcher.looksLikeImage(Data("<!DOCTYPE html><html>...".utf8)))
        XCTAssertFalse(ArtworkFetcher.looksLikeImage(Data("{\"error\":\"not found\"}".utf8)))
    }
}

// MARK: - Reading playback out of a web page

final class WebMediaScriptTests: XCTestCase {

    private func line(_ fields: [String]) -> String { fields.joined(separator: "\t") }

    /// Field order is a contract between the JavaScript and the parser. If it
    /// ever drifts, artists start appearing as albums.
    func testFieldsAreReadInTheAgreedOrder() {
        let reading = WebMediaScript.parse(line([
            "playing", "Cosmic Drift", "Nova Bloom", "Orbits", "212.5", "48.25",
            "https://img.example.com/cover.jpg",
        ]))

        XCTAssertEqual(reading?.title, "Cosmic Drift")
        XCTAssertEqual(reading?.artist, "Nova Bloom")
        XCTAssertEqual(reading?.album, "Orbits")
        XCTAssertEqual(reading?.isPlaying, true)
        XCTAssertEqual(reading?.duration ?? 0, 212.5, accuracy: 0.001)
        XCTAssertEqual(reading?.elapsed ?? 0, 48.25, accuracy: 0.001)
        XCTAssertEqual(reading?.artworkURL?.absoluteString, "https://img.example.com/cover.jpg")
    }

    func testAPageWithNoMediaReadsAsNothing() {
        XCTAssertNil(WebMediaScript.parse(""))
        XCTAssertNil(WebMediaScript.parse("playing"))
        XCTAssertNil(WebMediaScript.parse(line(["playing", "", "", "", "0", "0"])))
    }

    /// A live stream reports an infinite duration, which the snippet turns into
    /// 0; that has to read as "unknown", not as a finished track.
    func testAStreamWithNoDurationIsUnknownRatherThanZero() {
        let reading = WebMediaScript.parse(line(["playing", "Live Set", "Station", "", "0", "930"]))
        XCTAssertNil(reading?.duration)
        XCTAssertEqual(reading?.elapsed ?? 0, 930, accuracy: 0.001)
    }

    func testPausedIsReported() {
        XCTAssertEqual(WebMediaScript.parse(line(["paused", "T", "A", "B", "10", "1"]))?.isPlaying, false)
    }

    /// Older readings have no artwork column at all.
    func testAReadingWithoutArtworkStillParses() {
        let reading = WebMediaScript.parse(line(["playing", "T", "A", "B", "10", "1"]))
        XCTAssertNotNil(reading)
        XCTAssertNil(reading?.artworkURL)
    }

    /// The snippet is embedded in an AppleScript string literal, so quotes and
    /// backslashes have to survive the trip.
    func testTheSnippetIsEscapedForAppleScript() {
        let escaped = WebMediaScript.escapedForAppleScript("var s='a\"b\\\\c';")
        XCTAssertFalse(escaped.contains("\"") && !escaped.contains("\\\""))
        XCTAssertTrue(escaped.contains("\\\""))
        XCTAssertTrue(escaped.contains("\\\\"))
    }

    func testTheReaderSnippetPrefersMediaSessionOverTheDocumentTitle() {
        XCTAssertTrue(WebMediaScript.reader.contains("mediaSession"))
        XCTAssertTrue(WebMediaScript.reader.contains("document.title"))
    }
}

// MARK: - Following whatever is playing

final class AutomaticSourceTests: XCTestCase {

    func testItIsOfferedAndExplained() {
        XCTAssertTrue(MediaSourceChoice.allCases.contains(.automatic))
        XCTAssertEqual(MediaSourceChoice.automatic.rawValue, "automatic")
        XCTAssertFalse(MediaSourceChoice.automatic.explanation.isEmpty)
    }

    func testEveryBrowserSourceIsOffered() {
        for source in [MediaSourceChoice.safari, .chrome, .brave] {
            XCTAssertTrue(MediaSourceChoice.allCases.contains(source))
            XCTAssertFalse(MediaSourceChoice(rawValue: source.rawValue)?.displayName.isEmpty ?? true)
        }
    }

    /// Browsers can only drive the element they found, so a page must never
    /// light up skip or shuffle.
    func testChromiumAdvertisesOnlyWhatAPageCanDo() {
        let chrome = ChromiumMediaController.chrome()
        XCTAssertTrue(chrome.capabilities.contains(.transport))
        XCTAssertTrue(chrome.capabilities.contains(.seek))
        XCTAssertFalse(chrome.capabilities.contains(.skip))
        XCTAssertFalse(chrome.capabilities.contains(.shuffle))
    }

    func testTheAutomaticSourceCoversEveryScriptedApp() async {
        let names = Set(AutomaticMediaController.defaultChildren().map(\.displayName))
        XCTAssertEqual(names, [
            "Apple Music", "Apple TV", "Spotify", "Safari", "Google Chrome", "Brave Browser",
        ])
    }

    /// The TV app's scripting suite has no shuffle. Advertising one would leave
    /// a button lit that nothing can honour.
    func testTheTVAppOffersNoShuffle() {
        let tv = AppleMediaController.tv()
        XCTAssertTrue(tv.capabilities.contains(.transport))
        XCTAssertTrue(tv.capabilities.contains(.skip))
        XCTAssertTrue(tv.capabilities.contains(.seek))
        XCTAssertFalse(tv.capabilities.contains(.shuffle))
        XCTAssertTrue(AppleMediaController.music().capabilities.contains(.shuffle))
    }

    func testAppleSourcesAreNamedApart() {
        XCTAssertEqual(AppleMediaController.music().displayName, "Apple Music")
        XCTAssertEqual(AppleMediaController.tv().displayName, "Apple TV")
    }

    /// With nothing playing it must report idle rather than pretending.
    func testNothingPlayingReportsIdle() async {
        let controller = AutomaticMediaController(children: [])
        let snapshot = await controller.snapshot()
        XCTAssertFalse(snapshot.hasTrack)
        if case .idle = await controller.availability() {} else {
            XCTFail("An automatic source with nothing to follow is idle")
        }
    }
}
