//
//  demo.swift
//  Aperture — Scripts
//
//  Records the animated GIF README.md shows.
//
//  The frames are real: the app's own state views sit on the app's own
//  ``OverlaySurface``, sized by ``OverlayMetrics`` and moved by the springs in
//  ``Tokens/Motion`` — the same silhouette, layout and timing the overlay uses
//  on screen. Captured out of the window server with ScreenCaptureKit, so what
//  the GIF shows is what macOS drew.
//
//  What belongs to this script, and only this script, is the sequencing: which
//  state comes next and how long it holds. `OverlayRootView` cannot be driven
//  from here — it asks `OverlayManager` what a given display should show, and
//  the manager answers "resting" for any display that is not the focused one,
//  which requires `start(…)` and real overlay panels on a real screen. So the
//  presentation is held here instead and the slab mirrors `OverlayRootView`'s
//  own morph: one surface across every state, layers cross-fading over it.
//
//  A harness window rather than the running overlay, for the same reason
//  screenshots.swift renders instead of capturing: recording the real overlay
//  would also record whatever was on the display behind it, and `PreviewData`'s
//  fixtures keep the content identical from one run to the next.
//
//  Capture timestamps are kept per frame and written as each frame's GIF delay,
//  so playback runs at the speed it was recorded even though the capture cadence
//  is not perfectly even.
//
//  Run it through Scripts/demo.sh, which compiles it against the app sources;
//  it is not part of the app target.
//

import AppKit
import ImageIO
import Observation
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

/// The presentation the harness is showing, mutated from `main` while the
/// capture runs.
@MainActor
@Observable
final class DemoDriver {
    var presentation: OverlayPresentation = .minimal
}

@main
struct Demo {

    /// Staged on a 14-inch MacBook Pro's geometry, housing included.
    static let screen = PreviewData.notchedScreen

    /// Tall enough for the hub, wide enough for the meter's wings.
    static let size = CGSize(width: 620, height: 236)

    /// Fast enough to read as motion, slow enough to keep the GIF small.
    static let frameRate = 14.0

    /// Idle, a track starting, the hub, then a brightness key — and back.
    static let script: [(hold: Double, presentation: OverlayPresentation)] = [
        (0.9, .minimal),
        (1.9, .compact),
        (2.4, .expanded(.nowPlaying)),
        (0.9, .compact),
        (1.7, .hud(.meter)),
        (0.9, .minimal),
    ]

    static var duration: Double { script.reduce(0) { $0 + $1.hold } + 0.3 }

    @MainActor
    static func main() async {
        let app = NSApplication.shared
        // No Dock icon and no activation: the harness window must not take
        // focus from whoever is running this.
        app.setActivationPolicy(.accessory)

        var directory = FileManager.default.currentDirectoryPath
        var contactSheet: String?
        for argument in CommandLine.arguments.dropFirst() {
            if argument.hasPrefix("--contact-sheet=") {
                contactSheet = String(argument.dropFirst("--contact-sheet=".count))
            } else if !argument.hasPrefix("--") {
                directory = argument
            }
        }

        let environment = AppEnvironment.preview(activity: .media(PreviewData.playingMedia))
        let driver = DemoDriver()
        let window = makeWindow(DemoStage(environment: environment, driver: driver))
        defer { window.close() }

        // Let the window map and draw its first frame before capture starts.
        try? await Task.sleep(for: .milliseconds(700))

        guard let target = await shareableWindow() else {
            print("could not find the harness window to capture")
            exit(1)
        }

        async let captured = capture(target, duration: duration)
        await run(driver)
        let frames = await captured

        guard frames.count > 4 else {
            print("captured only \(frames.count) frames")
            exit(1)
        }

        write(frames, to: "\(directory)/demo.gif")
        if let contactSheet { writeContactSheet(frames, to: contactSheet) }
    }

    @MainActor
    static func run(_ driver: DemoDriver) async {
        for step in script {
            driver.presentation = step.presentation
            try? await Task.sleep(for: .seconds(step.hold))
        }
    }

    // MARK: - The harness window

    @MainActor
    static func makeWindow<V: View>(_ stage: V) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.title = "Aperture demo"
        window.contentView = NSHostingView(rootView: stage)
        window.isOpaque = true
        window.backgroundColor = .black
        window.center()
        // Visible without activating: the window server cannot capture a window
        // it is not compositing.
        window.orderFrontRegardless()
        return window
    }

    // MARK: - Capture

    /// This process's own largest window, which is the harness.
    static func shareableWindow() async -> SCWindow? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true
        ) else { return nil }
        return content.windows
            .filter { $0.owningApplication?.processID == getpid() }
            .max { ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height) }
    }

    struct Frame {
        var image: CGImage
        /// Seconds since capture began.
        var at: Double
    }

    static func capture(_ window: SCWindow, duration: Double) async -> [Frame] {
        let configuration = SCStreamConfiguration()
        configuration.width = Int(size.width)
        configuration.height = Int(size.height)
        configuration.showsCursor = false
        let filter = SCContentFilter(desktopIndependentWindow: window)

        var frames: [Frame] = []
        let start = Date()
        while Date().timeIntervalSince(start) < duration {
            let at = Date().timeIntervalSince(start)
            if let image = try? await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration
            ) {
                frames.append(Frame(image: image, at: at))
            }
            // Only pad the remainder of the frame's slot: the capture itself
            // already took part of it.
            let pause = 1.0 / frameRate - (Date().timeIntervalSince(start) - at)
            if pause > 0 { try? await Task.sleep(for: .seconds(pause)) }
        }
        return frames
    }

    // MARK: - Output

    static func write(_ frames: [Frame], to path: String) {
        guard let destination = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: path) as CFURL,
            UTType.gif.identifier as CFString,
            frames.count,
            nil
        ) else {
            print("could not create \(path)")
            exit(1)
        }

        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)

        for (index, frame) in frames.enumerated() {
            let nextAt = index + 1 < frames.count ? frames[index + 1].at : frame.at + 1.0 / frameRate
            // GIF stores delays in hundredths of a second, and viewers treat
            // anything under 0.02 s as "as fast as possible" — so that is the
            // floor.
            let delay = max(0.02, nextAt - frame.at)
            CGImageDestinationAddImage(destination, frame.image, [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay
                ]
            ] as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            print("could not write \(path)")
            exit(1)
        }

        let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int
        let weight = bytes.map { ", \($0 / 1024) KB" } ?? ""
        let length = frames.last.map { String(format: ", %.1f s", $0.at) } ?? ""
        print("wrote demo.gif — \(frames.count) frames\(weight)\(length)")
    }

    /// Every eighth frame in a column, so the motion can be checked without a
    /// GIF viewer. Diagnostic only — written outside Docs so it is never
    /// committed by accident.
    static func writeContactSheet(_ frames: [Frame], to path: String) {
        let sampled = frames.enumerated().filter { $0.offset % 8 == 0 }.map(\.element)
        guard !sampled.isEmpty,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: Int(size.width),
                height: Int(size.height) * sampled.count,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return }

        for (index, frame) in sampled.enumerated() {
            // CoreGraphics' origin is bottom-left, so the first frame goes on top.
            let y = CGFloat(sampled.count - 1 - index) * size.height
            context.draw(frame.image, in: CGRect(origin: CGPoint(x: 0, y: y), size: size))
        }

        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil
              ) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        _ = CGImageDestinationFinalize(destination)
        print("wrote \(path) — every 8th of \(frames.count) frames")
    }
}

// MARK: - The stage

/// The slab, on a plain backdrop with the camera housing drawn in black.
///
/// Mirrors ``OverlayRootView``'s `slab`: one ``OverlaySurface`` across every
/// state, whose size and silhouette change while layers cross-fade over it, so
/// the spring runs on the shape rather than swapping one view for another.
private struct DemoStage: View {

    let environment: AppEnvironment
    let driver: DemoDriver

    private var presentation: OverlayPresentation { driver.presentation }
    private var layout: ScreenGeometry.Layout { Demo.screen.layout(scale: 1) }
    private var metrics: OverlayMetrics { OverlayMetrics(layout: layout, scale: 1) }
    private var intensity: Double { environment.preferences.resolvedAnimationIntensity }

    private var slabSize: CGSize {
        metrics.slabSize(for: presentation, isHovering: false, hasActivity: true)
    }

    private var slabAnimation: Animation {
        switch presentation {
        case .expanded: Tokens.Motion.spring(intensity: intensity, reduceMotion: false)
        case .hud: Tokens.Motion.hud(intensity: intensity, reduceMotion: false)
        case .hidden, .minimal, .compact: Tokens.Motion.collapse(intensity: intensity, reduceMotion: false)
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
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
                .frame(width: Demo.screen.notch.width, height: Demo.screen.notch.height)

            OverlaySurface(
                bottomRadius: metrics.bottomRadius(for: presentation),
                flare: metrics.flare(for: presentation),
                isElevated: presentation.isExpanded
            ) {
                ZStack(alignment: .top) {
                    layer(resting, visible: presentation == .minimal || presentation == .compact)
                    layer(hud, visible: presentation.isHUD)
                    layer(hub, visible: presentation.isExpanded)
                }
                // Each layer keeps its natural size and is clipped by the slab,
                // so nothing reflows while the slab is in motion.
                .frame(width: slabSize.width, height: slabSize.height, alignment: .top)
            }
            .frame(width: slabSize.width, height: slabSize.height)
            .animation(slabAnimation, value: presentation)
        }
        .frame(width: Demo.size.width, height: Demo.size.height)
        .environment(\.colorScheme, .dark)
    }

    /// Layers cross-fade on their own short curve rather than riding the spring.
    private func layer<Layer: View>(_ content: Layer, visible: Bool) -> some View {
        content
            .fixedSize()
            .opacity(visible ? 1 : 0)
            .animation(
                visible
                    ? Tokens.Motion.contentIn(reduceMotion: false)
                    : Tokens.Motion.contentOut(reduceMotion: false),
                value: presentation
            )
    }

    @ViewBuilder
    private var resting: some View {
        if presentation == .compact {
            CompactActivityView(
                activity: .media(PreviewData.playingMedia), layout: layout, accent: .mono,
                artwork: Self.artwork, now: PreviewData.referenceDate,
                reduceMotion: false, increaseContrast: false, scale: 1
            )
        } else {
            MinimalPillView(
                layout: layout, accent: .mono, activity: .media(PreviewData.playingMedia),
                artwork: Self.artwork, isHovering: false, reduceMotion: false,
                increaseContrast: false, scale: 1
            )
        }
    }

    private var hud: some View {
        HUDView(
            event: .brightness(level: 0.62, displayName: "Built-in Display"),
            layout: layout, accent: .mono, increaseContrast: false, scale: 1
        )
    }

    private var hub: some View {
        ExpandedHubView(layout: layout, scale: 1, onClose: {})
            .environment(environment)
    }

    private static let artwork = ArtworkGenerator.fallbackImage(
        for: "Slow Meridian|Halden Cross", side: 320
    )
}
