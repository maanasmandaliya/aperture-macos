//
//  OverlaySurface.swift
//  Aperture
//
//  The slab every overlay state is drawn on.
//

import SwiftUI

/// The silhouette Aperture draws at the top of the display.
///
/// The shape is deliberately *not* a rounded rectangle. Three details decide
/// whether the overlay reads as part of the camera housing or as a separate
/// panel hanging below it:
///
/// * **The top edge is square and overshoots the screen.** A rounded top corner
///   leaves a sliver of desktop between the slab and the bezel, which is what
///   makes an overlay look like it is dangling. Extending past `minY` also means
///   a half-point rounding error can never open a seam.
/// * **Only the bottom corners are rounded**, so the slab reads as the housing
///   continuing downward.
/// * **The top corners flare outward with a concave curve.** Where the slab
///   meets the bezel it widens instead of stopping square, which is what sells
///   it as one moulded shape rather than a rectangle butted against an edge.
struct NotchSlabShape: Shape {

    /// Radius of the two bottom corners.
    var bottomRadius: CGFloat
    /// Width of the concave fillet where the slab meets the top edge.
    var flare: CGFloat
    /// How far above the top edge to extend. Off-screen, purely anti-seam.
    var topOverhang: CGFloat = 8

    /// Lets the silhouette morph smoothly as the overlay changes state.
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, flare) }
        set {
            bottomRadius = newValue.first
            flare = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let radius = max(min(bottomRadius, min(rect.width / 2, rect.height)), 0)
        let flare = max(min(flare, rect.height / 2), 0)
        let top = rect.minY - topOverhang

        var path = Path()
        path.move(to: CGPoint(x: rect.minX - flare, y: top))
        path.addLine(to: CGPoint(x: rect.minX - flare, y: rect.minY))
        // Concave fillet: curves *into* the slab, so the bezel appears to swell
        // outward into it.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + flare),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.maxY),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY - radius),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + flare))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX + flare, y: rect.minY),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX + flare, y: top))
        path.closeSubpath()
        return path
    }
}

/// Aperture's surface: a pure-black slab that continues the camera housing.
///
/// The fill is `Color.black`, not the graphite from the palette. That is the
/// whole trick — the housing is an absence of pixels, so anything even
/// fractionally lighter draws a visible rectangle exactly where the notch is.
/// For the same reason there is no border and no top highlight by default:
/// every stroke that crosses the top edge becomes a seam. Depth comes from the
/// inset wells and cards *inside* the slab instead, which is where it can exist
/// without giving the silhouette away.
struct OverlaySurface<Content: View>: View {

    /// Radius of the bottom corners.
    var bottomRadius: CGFloat
    var flare: CGFloat = 6
    var isElevated: Bool = false
    var increaseContrast: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background {
                shape
                    .fill(Color.black)
                    // Cast downward only; a symmetric shadow would halo the top
                    // edge and undo the seam.
                    .shadow(
                        color: Tokens.Shadow.ambient.color,
                        radius: isElevated ? Tokens.Shadow.ambient.radius : Tokens.Shadow.ambient.radius * 0.5,
                        y: isElevated ? Tokens.Shadow.ambient.y : Tokens.Shadow.ambient.y * 0.5
                    )
            }
            .overlay {
                // Increase Contrast asks for a discernible boundary, which is
                // worth more than seamlessness to anyone who turns it on. The
                // outline traces the visible silhouette only — the top edge is
                // off-screen, so it never crosses the housing.
                if increaseContrast {
                    shape.stroke(Tokens.Palette.hairlineStrong, lineWidth: 1.4)
                }
            }
            .clipShape(shape)
    }

    private var shape: NotchSlabShape {
        NotchSlabShape(bottomRadius: bottomRadius, flare: flare)
    }
}

/// A soft accent bloom used behind artwork and active glyphs.
struct AccentBloom: View {
    var accent: AccentChoice
    var intensity: Double = 0.5

    var body: some View {
        RadialGradient(
            colors: [Tokens.Palette.meter.opacity(0.16 * intensity), .clear],
            center: .center,
            startRadius: 0,
            endRadius: 60
        )
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }
}

#Preview("Slab silhouette against a light desktop") {
    ZStack(alignment: .top) {
        LinearGradient(
            colors: [Color(red: 0.82, green: 0.84, blue: 0.88), Color(red: 0.55, green: 0.60, blue: 0.68)],
            startPoint: .top, endPoint: .bottom
        )
        VStack(spacing: 40) {
            OverlaySurface(bottomRadius: Tokens.Radius.slabMinimal, flare: 6) {
                Color.clear.frame(width: 253, height: 32)
            }
            OverlaySurface(bottomRadius: Tokens.Radius.slabCompact, flare: 7) {
                Color.clear.frame(width: 340, height: 74)
            }
            OverlaySurface(bottomRadius: Tokens.Radius.slabHub, flare: 8, isElevated: true) {
                Color.clear.frame(width: 420, height: 200)
            }
        }
    }
    .frame(width: 640, height: 460)
}
