//
//  ScreenGeometry.swift
//  Aperture
//
//  Measuring the camera housing.
//
//  `NSScreen.safeAreaInsets.top` gives the height of the notched region, and
//  `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` give the usable menu-bar
//  strips either side of it — the width between them is the housing. On a
//  screen with no notch those auxiliary areas are `nil` and the safe-area inset
//  is zero, which is exactly the "non-notched" branch.
//

import AppKit
import Foundation

struct NotchMetrics: Equatable, Sendable {
    var width: CGFloat
    var height: CGFloat

    static let none = NotchMetrics(width: 0, height: 0)

    var isPresent: Bool { width > 1 && height > 1 }
}

struct ScreenGeometry: Equatable, Sendable, Identifiable {
    var id: CGDirectDisplayID
    /// Full display frame in AppKit's global (bottom-left origin) space.
    var frame: CGRect
    var notch: NotchMetrics
    var menuBarHeight: CGFloat
    var backingScale: CGFloat
    var localizedName: String

    var hasNotch: Bool { notch.isPresent }

    /// Point at the top centre of the display, where every overlay state is
    /// anchored.
    var topCenter: CGPoint { CGPoint(x: frame.midX, y: frame.maxY) }

    init(screen: NSScreen) {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        id = CGDirectDisplayID(number?.uint32Value ?? 0)
        frame = screen.frame
        backingScale = screen.backingScaleFactor
        localizedName = screen.localizedName
        menuBarHeight = max(screen.frame.maxY - screen.visibleFrame.maxY, 0)
        notch = Self.notchMetrics(for: screen)
    }

    /// Test/preview seam — lets the layout code be exercised without a display.
    init(
        id: CGDirectDisplayID,
        frame: CGRect,
        notch: NotchMetrics,
        menuBarHeight: CGFloat = 24,
        backingScale: CGFloat = 2,
        localizedName: String = "Preview Display"
    ) {
        self.id = id
        self.frame = frame
        self.notch = notch
        self.menuBarHeight = menuBarHeight
        self.backingScale = backingScale
        self.localizedName = localizedName
    }

    private static func notchMetrics(for screen: NSScreen) -> NotchMetrics {
        let inset = screen.safeAreaInsets.top
        guard inset > 0 else { return .none }

        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else {
            // Safe-area inset without auxiliary areas: a notch is present but
            // its width is unreported. Assume a conservative housing so content
            // is never placed underneath it.
            return NotchMetrics(width: 200, height: inset)
        }

        let width = max(screen.frame.width - left.width - right.width, 0)
        return NotchMetrics(width: width, height: inset)
    }
}

extension ScreenGeometry {
    /// Layout constants derived from the display, resolved once per state change
    /// rather than inside a SwiftUI body.
    struct Layout: Equatable, Sendable {
        /// Width of the collapsed pill, widened to straddle the housing.
        var pillSize: CGSize
        /// Rect the camera housing occupies inside the overlay's own coordinate
        /// space (origin top-left of the overlay content, y growing down).
        var notchRect: CGRect
        var hasNotch: Bool
    }

    /// - Parameter scale: user overlay scale from Preferences.
    func layout(scale: CGFloat) -> Layout {
        let baseHeight = Tokens.Size.pill.height * scale
        if hasNotch {
            // Straddle the housing: a wing either side wide enough for a status
            // dot and a glyph, so nothing lands on dead pixels.
            let wing = 34 * scale
            let width = notch.width + wing * 2
            // Exactly the housing's height, not a point more. Any overhang
            // would put a black lip below the notch and give away that the slab
            // is a separate object rather than the housing itself.
            let height = notch.height
            let notchOrigin = CGPoint(x: (width - notch.width) / 2, y: 0)
            return Layout(
                pillSize: CGSize(width: width, height: height),
                notchRect: CGRect(origin: notchOrigin, size: CGSize(width: notch.width, height: notch.height)),
                hasNotch: true
            )
        } else {
            return Layout(
                pillSize: CGSize(width: Tokens.Size.pill.width * scale, height: baseHeight),
                notchRect: .zero,
                hasNotch: false
            )
        }
    }
}
