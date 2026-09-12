//
//  DesignTokens.swift
//  Aperture
//
//  The single source of truth for Aperture's visual language. Every view pulls
//  spacing, radii, colour and motion from here so the overlay, the HUDs and the
//  settings window stay coherent.
//

import SwiftUI

/// Aperture's design tokens.
///
/// The aesthetic: the overlay's outer silhouette is pure black so it merges
/// with the camera housing (or, on a Mac without one, with the bezel) — see
/// ``OverlaySurface``. Every graphite, hairline and accent value below is for
/// what sits *inside* that silhouette: wells, cards, the tab bar, controls.
/// Depth lives there, where it cannot give the outline away.
enum Tokens {

    // MARK: - Palette

    enum Palette {
        /// Deepest *interior* surface. The slab itself is pure black; this is
        /// for panels drawn on top of it.
        static let graphite = Color(red: 0.043, green: 0.047, blue: 0.059)
        /// Raised interior surface.
        static let slate = Color(red: 0.067, green: 0.074, blue: 0.090)
        /// Inset wells (sliders, artwork placeholder).
        static let well = Color(red: 0.106, green: 0.117, blue: 0.141)
        /// Cool-gray hairline border.
        static let hairline = Color(red: 0.204, green: 0.227, blue: 0.278)
        static let hairlineStrong = Color(red: 0.310, green: 0.341, blue: 0.412)

        static let textPrimary = Color(red: 0.937, green: 0.945, blue: 0.965)
        static let textSecondary = Color(red: 0.620, green: 0.647, blue: 0.706)
        static let textTertiary = Color(red: 0.427, green: 0.451, blue: 0.510)

        /// Playback chrome — transport, meters, timelines — is monochrome.
        ///
        /// Anything you look at *while music is playing* is white on black; the
        /// accent is reserved for state signals (which pane you are on, shuffle
        /// being latched on, a focus ring, an event about to start). Tinting the
        /// timeline and the play button as well left the accent meaning nothing
        /// in particular.
        static let meter = Color.white
        /// The played part of a timeline. Softer than a control's fill:
        /// a timeline is mostly read, not grabbed, and full white next to
        /// the artwork pulls the eye away from the track it belongs to.
        static let meterSoft = Color.white.opacity(0.62)
        static let meterTrack = Color(red: 0.180, green: 0.196, blue: 0.231)

        static let positive = Color(red: 0.353, green: 0.812, blue: 0.596)
        static let warning = Color(red: 0.973, green: 0.729, blue: 0.353)
        static let critical = Color(red: 0.949, green: 0.443, blue: 0.443)
    }

    // MARK: - Spacing

    enum Space {
        static let hair: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 22
        static let xxl: CGFloat = 30
    }

    // MARK: - Geometry

    enum Radius {
        /// Bottom-corner radii for the overlay slab. Tuned near the physical
        /// notch's own corner radius so the collapsed state reads as the camera
        /// housing having grown a little wider, not as a pill parked under it.
        static let slabMinimal: CGFloat = 12
        static let slabCompact: CGFloat = 18
        static let slabHub: CGFloat = 28

        /// Width of the concave fillet where the slab meets the display's top
        /// edge. Scales with the slab so the flare stays proportional.
        static let flareMinimal: CGFloat = 6
        static let flareCompact: CGFloat = 7
        /// The hub flares hard where it meets the top edge. This is the detail
        /// that makes the panel read as *emerging from* the menu bar rather than
        /// hanging below it, and it wants to be generous — at the hub's size a
        /// small fillet reads as a manufacturing tolerance, not a shape.
        static let flareHub: CGFloat = 22

        static let card: CGFloat = 14
        static let chip: CGFloat = 8
        static let artwork: CGFloat = 12
    }

    enum Size {
        /// Collapsed pill, at scale 1.0.
        static let pill = CGSize(width: 180, height: 34)
        /// Pill growth applied on hover. On a notched display only the width
        /// grows: changing the height would break the illusion that the slab is
        /// the housing itself.
        static let hoverGrowth = CGSize(width: 16, height: 3)
        /// The peek keeps the resting slab's width and grows *downward* by this
        /// much to reveal the track name, then retracts. Announcing without
        /// getting wider is what keeps it feeling like the notch itself.
        static let peekTitleRow: CGFloat = 26
        /// Temporary HUD — deliberately shorter than the activity strip, so a
        /// passing HUD never feels heavier than the thing it interrupts. Used by
        /// the HUDs that need a row of their own (a finished timer, a
        /// notification); volume and brightness use the meter metrics below.
        static let hud = CGSize(width: 240, height: 38)
        /// Meter HUD (volume, brightness): content width in each wing, either
        /// side of the camera housing. The slab keeps the housing's height and
        /// grows only sideways, so a level change reads as the notch itself
        /// widening rather than a panel dropping out of it.
        static let hudMeterWing: CGFloat = 96
        /// Meter HUD on a display with no housing, where there are no wings to
        /// hang the label and bar off.
        static let hudMeterPlain = CGSize(width: 250, height: 34)
        /// The level bar inside a wing, and the room the label needs beside it.
        static let hudMeterBar: CGFloat = 74
        /// Expanded hub panel, sized per tab.
        ///
        /// Each pane gets its own height rather than every pane paying for the
        /// tallest one: Now Playing is three tight rows and should read wide and
        /// short, while Schedule and Controls need room for their lists. The
        /// slab springs between these when the tab changes, which is why they
        /// live here as constants the animation can interpolate.
        static let hub = CGSize(width: 364, height: 178)
        static let hubScheduleHeight: CGFloat = 224
        static let hubControlsHeight: CGFloat = 228
        /// Extra room the overlay window keeps around the widest state so
        /// shadows and spring overshoot are never clipped.
        static let windowPadding = CGSize(width: 90, height: 70)

        static let artworkCompact: CGFloat = 24

        /// How far the cover shrinks while playback is paused.
        static let artworkPausedScale: CGFloat = 0.87
        /// Colour left in the cover while paused. Deliberately not zero — a
        /// fully grey cover reads as broken artwork rather than paused
        /// playback, and the album should still be recognisable at a glance.
        static let artworkPausedSaturation: Double = 0.3
        static let artworkExpanded: CGFloat = 44

        /// Transport buttons in the playback pane, as the button's frame side —
        /// the glyph is drawn as a fraction of it. The primary action leads on
        /// size alone: with no wells or circles anywhere, scale is the only
        /// emphasis left.
        static let transportPrimary: CGFloat = 42
        static let transportSecondary: CGFloat = 32
        /// Shuffle and output: present, but not competing with the transport.
        static let transportAuxiliary: CGFloat = 22
        static let statusDot: CGFloat = 6
    }

    // MARK: - Elevation

    enum Shadow {
        static let ambient = ShadowStyle(color: .black.opacity(0.45), radius: 18, y: 8)
        static let key = ShadowStyle(color: .black.opacity(0.30), radius: 4, y: 1)

        struct ShadowStyle: Sendable {
            var color: Color
            var radius: CGFloat
            var y: CGFloat
        }
    }

    // MARK: - Typography

    enum Text {
        static let title = Font.system(size: 13, weight: .semibold, design: .rounded)
        static let titleLarge = Font.system(size: 16, weight: .semibold, design: .rounded)
        static let body = Font.system(size: 12, weight: .medium, design: .rounded)
        static let caption = Font.system(size: 11, weight: .medium, design: .rounded)
        static let micro = Font.system(size: 9.5, weight: .semibold, design: .rounded)
        static let numeric = Font.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit()
        static let numericLarge = Font.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit()
    }

    // MARK: - Motion

    /// Motion constants. `intensity` (0…1, from Preferences) scales the spring's
    /// bounce and duration; Reduce Motion collapses everything to a short fade.
    enum Motion {

        // Base durations. Every spring below is derived from one of these and
        // then scaled by the user's animation-intensity preference, so the whole
        // app can be re-timed from here rather than from a dozen call sites.
        static let expandDuration: TimeInterval = 0.50
        static let collapseDuration: TimeInterval = 0.40
        static let hudDuration: TimeInterval = 0.36
        static let artworkDuration: TimeInterval = 0.54
        static let trackChangeDuration: TimeInterval = 0.40
        static let hoverDuration: TimeInterval = 0.26
        /// Small state changes on a single control — hover, latched-on.
        static let controlStateDuration: TimeInterval = 0.20
        /// How long a meter HUD keeps showing the number after the last change
        /// before falling back to the name of what changed.
        static let hudReadoutDwell: TimeInterval = 0.75

        /// Default on-screen dwell for a temporary HUD.
        static let hudDwell: TimeInterval = 1.9
        /// Dwell for HUDs carrying text a user has to read.
        static let hudDwellVerbose: TimeInterval = 3.4

        /// Opening the hub.
        ///
        /// Expressed with `duration`/`bounce` rather than `response`/`damping`:
        /// the pair maps directly onto what is being tuned here — how long the
        /// slab takes to settle, and how much it overshoots on the way. Enough
        /// bounce to feel like it has mass, not so much that a surface this
        /// large visibly wobbles.
        static func spring(intensity: Double, reduceMotion: Bool) -> Animation {
            guard !reduceMotion else { return .easeOut(duration: 0.16) }
            let clamped = min(max(intensity, 0), 1)
            return .spring(
                duration: expandDuration * (1 + 0.5 * clamped),
                bounce: 0.20 + 0.20 * clamped
            )
        }

        /// Closing settles rather than overshooting. Bounce on the way out
        /// reads as hesitation, and the user has already moved on.
        static func collapse(intensity: Double, reduceMotion: Bool) -> Animation {
            guard !reduceMotion else { return .easeOut(duration: 0.16) }
            let clamped = min(max(intensity, 0), 1)
            return .spring(
                duration: collapseDuration * (1 + 0.42 * clamped),
                bounce: 0.07 + 0.10 * clamped
            )
        }

        static func hud(intensity: Double, reduceMotion: Bool) -> Animation {
            guard !reduceMotion else { return .easeOut(duration: 0.14) }
            let clamped = min(max(intensity, 0), 1)
            return .spring(
                duration: hudDuration * (1 + 0.42 * clamped),
                bounce: 0.17 + 0.17 * clamped
            )
        }

        /// A cover turning over to reveal the next track's.
        static let artworkFlipDuration: TimeInterval = 0.46

        /// Half a flip: edge-on is the midpoint, and each half is animated
        /// separately so the incoming face is never shown mirrored.
        static func artworkFlipHalf(intensity: Double) -> TimeInterval {
            let clamped = min(max(intensity, 0), 1)
            return artworkFlipDuration * (1 + 0.35 * clamped) / 2
        }

        /// One track cross-fading into the next.
        ///
        /// Flat on purpose. Every other motion here is a spring, but a spring
        /// on opacity overshoots past fully-opaque and clips, which reads as a
        /// flicker rather than a fade.
        static func trackChange(reduceMotion: Bool) -> Animation {
            reduceMotion ? .easeOut(duration: 0.14) : .easeInOut(duration: trackChangeDuration)
        }

        /// The cover settling between playing and paused.
        ///
        /// Bouncier than the panel springs on purpose: it is a small element
        /// with nothing depending on where it lands, so it can afford to
        /// overshoot properly and give the pause some physicality.
        static func artwork(intensity: Double, reduceMotion: Bool) -> Animation {
            guard !reduceMotion else { return .easeOut(duration: 0.18) }
            let clamped = min(max(intensity, 0), 1)
            return .spring(
                duration: artworkDuration * (1 + 0.45 * clamped),
                bounce: 0.26 + 0.23 * clamped
            )
        }

        /// Content cross-fading inside the slab as it changes state. The
        /// incoming layer waits for the slab to have opened a little, so the two
        /// never double-expose.
        static func contentIn(reduceMotion: Bool) -> Animation {
            reduceMotion ? .easeOut(duration: 0.16) : .easeOut(duration: 0.28).delay(0.13)
        }

        static func contentOut(reduceMotion: Bool) -> Animation {
            reduceMotion ? .easeOut(duration: 0.16) : .easeIn(duration: 0.16)
        }

        /// Hover and latched-on changes on an individual control.
        static func controlState(reduceMotion: Bool) -> Animation {
            .easeOut(duration: reduceMotion ? 0.1 : controlStateDuration)
        }

        static func hover(reduceMotion: Bool) -> Animation {
            reduceMotion ? .easeOut(duration: 0.1) : .spring(duration: hoverDuration, bounce: 0.22)
        }
    }
}

// MARK: - Accent

/// Accent colours offered in Settings ▸ Appearance. Blue-violet is the default
/// and the one the rest of the visual language is tuned against.
enum AccentChoice: String, CaseIterable, Codable, Sendable, Identifiable {
    /// The default. Keeps the whole overlay monochrome, so state signals read
    /// as brightness rather than hue and nothing competes with album artwork.
    case mono
    case violet
    case azure
    case teal
    case amber
    case rose

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mono: "Mono"
        case .violet: "Violet"
        case .azure: "Azure"
        case .teal: "Teal"
        case .amber: "Amber"
        case .rose: "Rose"
        }
    }

    var color: Color {
        switch self {
        case .mono: Color(red: 0.925, green: 0.937, blue: 0.957)
        case .violet: Color(red: 0.486, green: 0.420, blue: 1.000)
        case .azure: Color(red: 0.325, green: 0.596, blue: 1.000)
        case .teal: Color(red: 0.243, green: 0.784, blue: 0.729)
        case .amber: Color(red: 0.980, green: 0.686, blue: 0.290)
        case .rose: Color(red: 0.965, green: 0.435, blue: 0.588)
        }
    }

    /// Slightly desaturated partner used for gradient tails and glows.
    var secondaryColor: Color {
        switch self {
        case .mono: Color(red: 0.741, green: 0.769, blue: 0.816)
        case .violet: Color(red: 0.647, green: 0.416, blue: 0.976)
        case .azure: Color(red: 0.376, green: 0.827, blue: 0.980)
        case .teal: Color(red: 0.400, green: 0.851, blue: 0.596)
        case .amber: Color(red: 0.973, green: 0.518, blue: 0.310)
        case .rose: Color(red: 0.831, green: 0.404, blue: 0.831)
        }
    }

    var gradient: LinearGradient {
        LinearGradient(
            colors: [color, secondaryColor],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

/// How the overlay reacts to the system appearance.
enum AppearanceMode: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Always the graphite treatment — the overlay lives against the bezel, so
    /// a light variant is rarely what people want. Contrast still adapts.
    case alwaysDark
    /// Lift surface luminance and border contrast when the system is in Light.
    case automatic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .alwaysDark: "Always graphite"
        case .automatic: "Match system"
        }
    }
}
