//
//  OverlayMetricsTests.swift
//  ApertureTests
//

import XCTest
@testable import Aperture

final class OverlayMetricsTests: XCTestCase {

    private var notched: OverlayMetrics {
        OverlayMetrics(layout: PreviewData.notchedScreen.layout(scale: 1), scale: 1)
    }

    private var plain: OverlayMetrics {
        OverlayMetrics(layout: PreviewData.plainScreen.layout(scale: 1), scale: 1)
    }

    // MARK: - Housing band

    func testNotchBandIsReservedOnlyOnNotchedDisplays() {
        XCTAssertEqual(notched.notchBand, PreviewData.notchedScreen.notch.height, accuracy: 0.001)
        XCTAssertEqual(plain.notchBand, 0, accuracy: 0.001)
    }

    func testMessageHUDHeightIncludesTheHousingBand() {
        XCTAssertEqual(notched.hudSize(for: .message).height,
                       notched.notchBand + Tokens.Size.hud.height, accuracy: 0.001)
    }

    func testPeekKeepsTheRestingWidth() {
        // The whole point: the peek drops open, it does not spread sideways.
        for metrics in [notched, plain] {
            XCTAssertEqual(metrics.compactSize.width,
                           metrics.minimalSize(isHovering: false).width, accuracy: 0.001)
        }
    }

    func testPeekAddsExactlyOneNameRow() {
        for metrics in [notched, plain] {
            XCTAssertEqual(
                metrics.compactSize.height,
                metrics.minimalSize(isHovering: false).height + Tokens.Size.peekTitleRow,
                accuracy: 0.001
            )
        }
    }

    func testPeekIsTheSmallestGrowthTheOverlayMakes() {
        // It announces and retracts, so it must stay the least intrusive of the
        // states that grow at all.
        XCTAssertLessThan(notched.compactSize.height, notched.hudSize(for: .message).height)
        XCTAssertLessThan(notched.compactSize.height, notched.hubSize(for: .nowPlaying).height)
    }






    func testHubHeightExcludesTheHousingBandBecauseItAbsorbsIt() {
        // The hub is tall enough that the housing sits inside it; adding a band
        // on top would push its content off the bottom.
        XCTAssertEqual(notched.hubSize(for: .nowPlaying).height, Tokens.Size.hub.height, accuracy: 0.001)
        XCTAssertEqual(plain.hubSize(for: .nowPlaying).height, Tokens.Size.hub.height, accuracy: 0.001)
    }

    func testEachTabGetsItsOwnHeight() {
        // Now Playing is three tight rows; the list panes need more room. Only
        // the height varies — a slab that changed width mid-switch would slosh.
        let nowPlaying = notched.hubSize(for: .nowPlaying)
        let schedule = notched.hubSize(for: .schedule)
        let controls = notched.hubSize(for: .controls)
        let mirror = notched.hubSize(for: .mirror)

        XCTAssertLessThan(nowPlaying.height, schedule.height)
        XCTAssertLessThan(schedule.height, controls.height)
        XCTAssertLessThan(controls.height, mirror.height, "A mirror is only useful if the preview is big enough")
        XCTAssertEqual(nowPlaying.width, schedule.width, accuracy: 0.001)
        XCTAssertEqual(schedule.width, controls.width, accuracy: 0.001)
        XCTAssertEqual(controls.width, mirror.width, accuracy: 0.001)
    }

    func testNowPlayingHubIsWiderThanItIsTall() {
        let size = notched.hubSize(for: .nowPlaying)
        XCTAssertGreaterThan(size.width, size.height,
                             "The compact playback panel should read wide and short")
    }

    func testPresentationSizeFollowsTheSelectedTab() {
        XCTAssertEqual(notched.slabSize(for: .expanded(.schedule), isHovering: false),
                       notched.hubSize(for: .schedule))
        XCTAssertEqual(notched.slabSize(for: .expanded(.controls), isHovering: false),
                       notched.hubSize(for: .controls))
        XCTAssertEqual(notched.slabSize(for: .expanded(.mirror), isHovering: false),
                       notched.hubSize(for: .mirror))
    }

    func testExpandedSizeIsNeverTheNowPlayingHeightForOtherPanes() {
        // Guards a bug that shipped: the hover hit-region hardcoded
        // `Tokens.Size.hub.height`, which is the *Now Playing* height, so the
        // lower part of the taller panes stopped responding to the swipe.
        // Anything sizing the expanded overlay must go through `slabSize`.
        for tab in HubTab.allCases where tab != .nowPlaying {
            let size = notched.slabSize(for: .expanded(tab), isHovering: false)
            XCTAssertNotEqual(size.height, Tokens.Size.hub.height,
                              "\(tab.title) must not fall back to the Now Playing height")
            XCTAssertEqual(size, notched.hubSize(for: tab))
        }
    }

    func testMaxHubSizeCoversEveryTab() {
        let maximum = notched.maxHubSize
        for tab in HubTab.allCases {
            XCTAssertLessThanOrEqual(notched.hubSize(for: tab).width, maximum.width)
            XCTAssertLessThanOrEqual(notched.hubSize(for: tab).height, maximum.height)
        }
    }

    // MARK: - Sizes per presentation

    func testEveryPresentationResolvesToItsOwnSize() {
        let idle = notched.slabSize(for: .minimal, isHovering: false)
        let compact = notched.slabSize(for: .compact, isHovering: false)
        let hud = notched.slabSize(for: .hud(.message), isHovering: false)
        let meter = notched.slabSize(for: .hud(.meter), isHovering: false)
        let hub = notched.slabSize(for: .expanded(.nowPlaying), isHovering: false)

        XCTAssertEqual(idle, PreviewData.notchedScreen.layout(scale: 1).pillSize)
        XCTAssertEqual(compact, notched.compactSize)
        XCTAssertEqual(hud, notched.hudSize(for: .message))
        XCTAssertEqual(meter, notched.hudSize(for: .meter))
        XCTAssertEqual(hub, notched.hubSize(for: .nowPlaying))
    }

    func testSizesGrowMonotonicallyFromRestToHub() {
        // The spring interpolates between these, so a non-monotonic step would
        // make the slab visibly shrink partway through opening.
        let minimal = notched.slabSize(for: .minimal, isHovering: false)
        let peek = notched.slabSize(for: .compact, isHovering: false)
        let hud = notched.slabSize(for: .hud(.message), isHovering: false)
        let hub = notched.slabSize(for: .expanded(.nowPlaying), isHovering: false)

        XCTAssertLessThan(minimal.height, peek.height)
        XCTAssertLessThan(peek.height, hud.height)
        XCTAssertLessThan(hud.height, hub.height)
        XCTAssertLessThanOrEqual(minimal.width, hub.width)
    }

    // MARK: - Resting size

    /// With nothing playing the wings carry nothing, so a notched display shows
    /// the housing and only the housing — invisible against it.
    func testIdleCollapsesToTheHousingExactly() {
        let idle = notched.minimalSize(isHovering: false, hasActivity: false)
        let housing = PreviewData.notchedScreen.notch

        XCTAssertEqual(idle.width, housing.width, accuracy: 0.001)
        XCTAssertEqual(idle.height, housing.height, accuracy: 0.001)
    }

    func testAnActivityRestoresTheWings() {
        let active = notched.minimalSize(isHovering: false, hasActivity: true)
        let idle = notched.minimalSize(isHovering: false, hasActivity: false)

        XCTAssertGreaterThan(active.width, idle.width, "Artwork and a glyph need wings")
        XCTAssertEqual(active.height, idle.height, accuracy: 0.001, "Height is the housing's, either way")
    }

    /// An invisible slab still has to be findable.
    func testHoverWidensEvenWhenIdle() {
        let idle = notched.minimalSize(isHovering: false, hasActivity: false)
        let hovered = notched.minimalSize(isHovering: true, hasActivity: false)

        XCTAssertGreaterThan(hovered.width, idle.width)
        XCTAssertEqual(hovered.height, idle.height, accuracy: 0.001)
    }

    /// A display with no housing has nothing to hide inside, so it keeps its
    /// pill rather than shrinking to nothing.
    func testAPlainDisplayKeepsItsPillWhenIdle() {
        let idle = plain.minimalSize(isHovering: false, hasActivity: false)
        XCTAssertEqual(idle, PreviewData.plainScreen.layout(scale: 1).pillSize)
    }

    // MARK: - Meter HUDs

    /// The whole point of the meter style: on a notched display it may only
    /// reach sideways. Any extra height would put a black lip below the housing
    /// and give away that the slab is a separate object.
    func testAMeterHUDKeepsTheHousingsHeightAndOnlyWidens() {
        let minimal = notched.slabSize(for: .minimal, isHovering: false)
        let meter = notched.slabSize(for: .hud(.meter), isHovering: false)

        XCTAssertEqual(meter.height, minimal.height, accuracy: 0.001)
        XCTAssertGreaterThan(meter.width, minimal.width)
    }

    /// A wing either side of the housing, so nothing is ever drawn across it.
    func testAMeterHUDIsTheHousingPlusTwoEqualWings() {
        let layout = PreviewData.notchedScreen.layout(scale: 1)
        let meter = notched.slabSize(for: .hud(.meter), isHovering: false)

        XCTAssertEqual(meter.width, layout.notchRect.width + notched.meterWing * 2, accuracy: 0.001)
    }

    /// Volume and brightness share the meter; a finished timer needs its own row
    /// and must still drop below the housing.
    func testMessageHUDsStillDropBelowTheHousing() {
        let minimal = notched.slabSize(for: .minimal, isHovering: false)
        let message = notched.slabSize(for: .hud(.message), isHovering: false)

        XCTAssertGreaterThan(message.height, minimal.height)
    }

    /// With no housing there are no wings, so the meter falls back to one row.
    func testAMeterHUDWithoutAHousingIsASingleRow() {
        let meter = plain.slabSize(for: .hud(.meter), isHovering: false)

        XCTAssertEqual(meter.height, Tokens.Size.hudMeterPlain.height, accuracy: 0.001)
        XCTAssertGreaterThan(meter.width, 0)
    }

    /// A meter HUD is the resting slab's height, so it must wear the resting
    /// silhouette — the compact radius would round a 33 pt slab to a capsule.
    func testAMeterHUDWearsTheRestingSilhouette() {
        XCTAssertEqual(notched.bottomRadius(for: .hud(.meter)), notched.bottomRadius(for: .minimal))
        XCTAssertEqual(notched.flare(for: .hud(.meter)), notched.flare(for: .minimal))
        XCTAssertEqual(notched.bottomRadius(for: .hud(.message)), notched.bottomRadius(for: .compact))
    }

    func testHiddenUsesTheIdleFootprintSoTheSlabHasSomewhereToReturnTo() {
        XCTAssertEqual(notched.slabSize(for: .hidden, isHovering: false),
                       notched.slabSize(for: .minimal, isHovering: false))
    }

    // MARK: - Hover

    func testHoverGrowsSidewaysOnlyOnANotchedDisplay() {
        let resting = notched.minimalSize(isHovering: false)
        let hovered = notched.minimalSize(isHovering: true)
        XCTAssertGreaterThan(hovered.width, resting.width)
        XCTAssertEqual(hovered.height, resting.height, accuracy: 0.001,
                       "Growing taller would break the illusion that the slab is the housing")
    }

    func testHoverGrowsInBothAxesWithoutAHousing() {
        let resting = plain.minimalSize(isHovering: false)
        let hovered = plain.minimalSize(isHovering: true)
        XCTAssertGreaterThan(hovered.width, resting.width)
        XCTAssertGreaterThan(hovered.height, resting.height)
    }

    func testHoverOnlyAffectsTheIdleState() {
        XCTAssertEqual(notched.slabSize(for: .compact, isHovering: true),
                       notched.slabSize(for: .compact, isHovering: false))
        XCTAssertEqual(notched.slabSize(for: .expanded(.schedule), isHovering: true),
                       notched.slabSize(for: .expanded(.schedule), isHovering: false))
    }

    // MARK: - Silhouette

    func testCornerRadiusOpensUpAsTheSlabGrows() {
        XCTAssertLessThan(notched.bottomRadius(for: .minimal), notched.bottomRadius(for: .compact))
        XCTAssertLessThan(notched.bottomRadius(for: .compact), notched.bottomRadius(for: .expanded(.controls)))
    }

    func testFlareOpensUpAsTheSlabGrows() {
        XCTAssertLessThan(notched.flare(for: .minimal), notched.flare(for: .compact))
        XCTAssertLessThan(notched.flare(for: .compact), notched.flare(for: .expanded(.controls)))
    }

    func testMessageHUDAndCompactShareASilhouetteSoTheSwapIsSizeOnly() {
        XCTAssertEqual(notched.bottomRadius(for: .hud(.message)), notched.bottomRadius(for: .compact), accuracy: 0.001)
        XCTAssertEqual(notched.flare(for: .hud(.message)), notched.flare(for: .compact), accuracy: 0.001)
    }

    // MARK: - Scale

    func testUserScaleMultipliesEveryDimensionExceptTheHousingBand() {
        let large = OverlayMetrics(layout: PreviewData.notchedScreen.layout(scale: 1.25), scale: 1.25)
        XCTAssertEqual(large.notchBand, notched.notchBand, accuracy: 0.001,
                       "The camera housing is physical and does not scale")
        XCTAssertEqual(large.hubSize(for: .nowPlaying).width,
                       notched.hubSize(for: .nowPlaying).width * 1.25, accuracy: 0.001)
        XCTAssertGreaterThan(large.bottomRadius(for: .expanded(.nowPlaying)),
                             notched.bottomRadius(for: .expanded(.nowPlaying)))
    }
}
