//
//  OverlayPreviewStage.swift
//  Aperture
//
//  Shared preview chrome: a slice of desktop with the display's top edge at the
//  top of the canvas, so overlay states are previewed the way they are seen.
//

import SwiftUI

/// How wide a preview stage should be.
///
/// Deliberately not nested inside the generic ``OverlayPreviewStage``, so a
/// caller can name the type without naming its `Content`.
enum PreviewCanvasWidth {
    /// A fixed slice of the modelled display — what a standalone preview wants,
    /// since it has the whole canvas to itself.
    case standard
    /// Whatever the container offers. Required anywhere the stage sits in a
    /// column it does not control, such as a Settings form: a fixed canvas
    /// wider than the column does not shrink, it overflows.
    case fill
}

struct OverlayPreviewStage<Content: View>: View {

    var geometry: ScreenGeometry
    var scale: CGFloat = 1
    var canvasHeight: CGFloat = 420
    var canvasWidth: PreviewCanvasWidth = .standard
    @ViewBuilder var content: (ScreenGeometry.Layout) -> Content

    private var fixedWidth: CGFloat? {
        canvasWidth == .standard ? min(geometry.frame.width * 0.62, 760) : nil
    }

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [Color(red: 0.14, green: 0.15, blue: 0.19), Color(red: 0.06, green: 0.07, blue: 0.09)],
                startPoint: .top,
                endPoint: .bottom
            )

            // Stand-in for the physical camera housing, so the nesting is
            // visible in the canvas the way it is on a real display.
            if geometry.hasNotch {
                Rectangle()
                    .fill(Color.black)
                    .frame(width: geometry.notch.width * scale, height: geometry.notch.height * scale)
            }

            content(geometry.layout(scale: scale))
        }
        .frame(width: fixedWidth, height: canvasHeight)
        .environment(\.colorScheme, .dark)
    }
}
