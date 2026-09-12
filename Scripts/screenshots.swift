//
//  screenshots.swift
//  Aperture — Scripts
//
//  Renders the images README.md shows, from the app's own SwiftUI views.
//
//  Deliberately not a screen capture, for two reasons. A capture of the real
//  overlay also publishes whatever happened to be on the display behind it. And
//  `PreviewData`'s fixtures are fixed — including a fixed reference date — so
//  the output is identical from one run to the next, which keeps regenerating
//  after a UI change to a diff of the pixels that actually changed.
//
//  Run it through Scripts/screenshots.sh, which compiles it against the app
//  sources; it is not part of the app target.
//

import AppKit
import SwiftUI

@main
struct Screenshots {

    /// Staged on a 14-inch MacBook Pro's geometry, housing included.
    static let screen = PreviewData.notchedScreen

    /// Wide enough for the hub, so every image crops to the same width.
    static let width: CGFloat = 620

    @MainActor
    static func main() {
        _ = NSApplication.shared

        let directory = CommandLine.arguments.count > 1
            ? CommandLine.arguments[1]
            : FileManager.default.currentDirectoryPath
        let layout = screen.layout(scale: 1)
        let metrics = OverlayMetrics(layout: layout, scale: 1)
        let artwork = ArtworkGenerator.fallbackImage(for: "Slow Meridian|Halden Cross", side: 320)

        // Each height is cropped to just below the slab it holds, so the images
        // are mostly overlay rather than backdrop.
        write("01-resting", into: directory, height: 96) {
            OverlaySurface(
                bottomRadius: Tokens.Radius.slabMinimal,
                flare: Tokens.Radius.flareMinimal
            ) {
                MinimalPillView(
                    layout: layout, accent: .mono, activity: .media(PreviewData.playingMedia),
                    artwork: artwork, isHovering: false, reduceMotion: false,
                    increaseContrast: false, scale: 1
                )
            }
        }

        write("02-activity", into: directory, height: 130) {
            OverlaySurface(
                bottomRadius: Tokens.Radius.slabCompact,
                flare: Tokens.Radius.flareCompact
            ) {
                CompactActivityView(
                    activity: .media(PreviewData.playingMedia), layout: layout, accent: .mono,
                    artwork: artwork, now: PreviewData.referenceDate,
                    reduceMotion: false, increaseContrast: false, scale: 1
                )
            }
        }

        write("03-hub", into: directory, height: 210) {
            OverlaySurface(
                bottomRadius: metrics.bottomRadius(for: .expanded(.nowPlaying)),
                flare: metrics.flare(for: .expanded(.nowPlaying)),
                isElevated: true
            ) {
                ExpandedHubView(layout: layout, scale: 1, onClose: {})
                    .environment(AppEnvironment.preview(activity: .media(PreviewData.playingMedia)))
                    .fixedSize()
            }
        }

        write("04-brightness", into: directory, height: 96) {
            OverlaySurface(
                bottomRadius: metrics.bottomRadius(for: .hud(.meter)),
                flare: metrics.flare(for: .hud(.meter))
            ) {
                HUDView(
                    event: .brightness(level: 0.62, displayName: "Built-in Display"),
                    layout: layout, accent: .mono, increaseContrast: false, scale: 1
                )
                .fixedSize()
            }
        }
    }

    // MARK: - Staging

    /// Puts `slab` on a plain backdrop with the camera housing drawn in black,
    /// so the seam between the two is the real rendering rather than a mock-up,
    /// and writes it to `directory` as a Retina PNG.
    @MainActor
    static func write<V: View>(
        _ name: String,
        into directory: String,
        height: CGFloat,
        @ViewBuilder _ slab: () -> V
    ) {
        let stage = ZStack(alignment: .top) {
            LinearGradient(
                colors: [
                    Color(red: 0.35, green: 0.38, blue: 0.46),
                    Color(red: 0.11, green: 0.12, blue: 0.16)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Rectangle()
                .fill(.black)
                .frame(width: screen.notch.width, height: screen.notch.height)
            slab()
        }
        .frame(width: width, height: height)
        .clipped()

        // Dark explicitly: the renderer has no window to inherit an appearance
        // from, and the overlay is a dark surface in either appearance.
        let renderer = ImageRenderer(content: stage.environment(\.colorScheme, .dark))
        renderer.scale = 2

        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            // Loud rather than silent: an empty image would otherwise be
            // committed as a screenshot.
            print("failed to render \(name)")
            exit(1)
        }

        do {
            try png.write(to: URL(fileURLWithPath: "\(directory)/\(name).png"))
            print("wrote \(name).png \(Int(image.size.width))x\(Int(image.size.height))")
        } catch {
            print("failed to write \(name).png: \(error)")
            exit(1)
        }
    }
}
