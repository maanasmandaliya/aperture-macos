//
//  SlabPreview.swift
//  Aperture
//
//  Preview-only scaffolding.
//
//  The overlay's state views render their interior only — the slab belongs to
//  ``OverlayRootView`` so it can persist and morph. Previews still want to see
//  the finished thing, so this puts the interior back on a slab of the right
//  silhouette for that state.
//

import SwiftUI

struct SlabPreview<Content: View>: View {

    var geometry: ScreenGeometry
    var presentation: OverlayPresentation
    var scale: CGFloat = 1
    var increaseContrast: Bool = false
    var canvasHeight: CGFloat = 200
    var canvasWidth: PreviewCanvasWidth = .standard
    @ViewBuilder var content: (ScreenGeometry.Layout) -> Content

    private var metrics: OverlayMetrics {
        OverlayMetrics(layout: geometry.layout(scale: scale), scale: scale)
    }

    var body: some View {
        OverlayPreviewStage(
            geometry: geometry,
            scale: scale,
            canvasHeight: canvasHeight,
            canvasWidth: canvasWidth
        ) { _ in
            OverlaySurface(
                bottomRadius: metrics.bottomRadius(for: presentation),
                flare: metrics.flare(for: presentation),
                isElevated: presentation.isExpanded,
                increaseContrast: increaseContrast
            ) {
                content(geometry.layout(scale: scale)).fixedSize()
            }
        }
    }
}
