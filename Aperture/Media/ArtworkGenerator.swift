//
//  ArtworkGenerator.swift
//  Aperture
//
//  Original procedural cover art for the demo source and for tracks whose real
//  source cannot supply an image. Nothing here is derived from third-party
//  assets — every pixel is generated from the seed.
//

import AppKit
import CoreGraphics
import Foundation

struct ArtworkSeed: Sendable, Equatable {
    /// 0…1 hue for the dominant field.
    var hue: Double
    /// 0…1 hue for the counter field.
    var secondaryHue: Double
    /// 0…1 rotation of the gradient axis.
    var angle: Double

    /// Stable seed derived from text, so the same track always renders the same
    /// cover across launches.
    static func derived(from text: String) -> ArtworkSeed {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        let a = Double(hash & 0xFFFF) / Double(0xFFFF)
        let b = Double((hash >> 16) & 0xFFFF) / Double(0xFFFF)
        let c = Double((hash >> 32) & 0xFFFF) / Double(0xFFFF)
        return ArtworkSeed(hue: a, secondaryHue: (a + 0.18 + b * 0.28).truncatingRemainder(dividingBy: 1), angle: c)
    }
}

enum ArtworkGenerator {

    /// Renders a square PNG: a two-stop diagonal field, a soft radial bloom and
    /// a set of concentric arcs that echo Aperture's rounded geometry.
    ///
    /// Drawn into an explicit `CGContext` rather than through `NSImage.lockFocus`,
    /// which would silently render at the current display's backing scale and
    /// produce a bitmap twice the requested size on a Retina Mac.
    static func makeArtwork(seed: ArtworkSeed, side: CGFloat) -> Data? {
        let pixels = max(Int(side.rounded()), 1)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let side = CGFloat(pixels)
        let base = NSColor(hue: seed.hue, saturation: 0.52, brightness: 0.42, alpha: 1)
        let counter = NSColor(hue: seed.secondaryHue, saturation: 0.62, brightness: 0.68, alpha: 1)
        let deep = NSColor(hue: seed.hue, saturation: 0.66, brightness: 0.16, alpha: 1)

        let colors = [deep.cgColor, base.cgColor, counter.cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.55, 1]) else { return nil }

        let theta = seed.angle * .pi * 2
        let radius = side * 0.75
        let center = CGPoint(x: side / 2, y: side / 2)
        let start = CGPoint(x: center.x - cos(theta) * radius, y: center.y - sin(theta) * radius)
        let end = CGPoint(x: center.x + cos(theta) * radius, y: center.y + sin(theta) * radius)
        context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

        // Soft bloom off-centre, positioned by the seed so covers differ.
        let bloomCenter = CGPoint(x: side * (0.28 + seed.angle * 0.44), y: side * (0.68 - seed.hue * 0.3))
        if let bloom = CGGradient(
            colorsSpace: space,
            colors: [counter.withAlphaComponent(0.55).cgColor, counter.withAlphaComponent(0).cgColor] as CFArray,
            locations: [0, 1]
        ) {
            context.drawRadialGradient(
                bloom,
                startCenter: bloomCenter, startRadius: 0,
                endCenter: bloomCenter, endRadius: side * 0.52,
                options: []
            )
        }

        // Concentric arcs — the one motif shared with the app icon.
        context.setLineCap(.round)
        for step in 0..<5 {
            let progress = Double(step) / 5
            let ringRadius = side * (0.16 + progress * 0.30)
            context.setLineWidth(side * (0.014 - progress * 0.0015))
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.16 - progress * 0.025).cgColor)
            let sweepStart = theta + progress * 1.4
            context.addArc(
                center: CGPoint(x: side * 0.5, y: side * 0.46),
                radius: ringRadius,
                startAngle: sweepStart,
                endAngle: sweepStart + .pi * (1.15 - progress * 0.32),
                clockwise: false
            )
            context.strokePath()
        }

        guard let cgImage = context.makeImage() else { return nil }
        let representation = NSBitmapImageRep(cgImage: cgImage)
        representation.size = NSSize(width: side, height: side)
        return representation.representation(using: .png, properties: [:])
    }

    /// Cheap in-memory cache so the SwiftUI body does not re-render artwork.
    @MainActor
    private static var fallbackCache: [String: NSImage] = [:]

    @MainActor
    static func fallbackImage(for text: String, side: CGFloat = 320) -> NSImage? {
        let key = "\(text)#\(Int(side))"
        if let cached = fallbackCache[key] { return cached }
        guard let data = makeArtwork(seed: .derived(from: text), side: side),
              let image = NSImage(data: data) else { return nil }
        if fallbackCache.count > 24 { fallbackCache.removeAll(keepingCapacity: true) }
        fallbackCache[key] = image
        return image
    }
}
