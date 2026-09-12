//
//  FullScreenDetector.swift
//  Aperture
//
//  Deciding whether a display is showing a full-screen app.
//
//  macOS exposes no public "is this space full screen" call — that lives in
//  private SkyLight (`CGSSpaceGetType`), which Aperture does not use. What it
//  does expose is `CGWindowListCopyWindowInfo`, undeprecated on the macOS 26
//  SDK and needing no permission for the fields used here (layer and bounds;
//  only window *titles* are gated behind Screen Recording).
//
//  The rule below came out of measuring the window list in each state rather
//  than reasoning about it, because the obvious signals are all wrong:
//
//  * Geometry alone is not enough. A full-screen window on this Mac is
//    (0, 33, 1728×1084) — and so is an ordinary window the user has zoomed,
//    byte for byte.
//  * The menu bar's own window stays listed, on-screen, at alpha 1 while an
//    app is full screen, so its presence says nothing.
//  * `NSScreen.visibleFrame` does not budge when another process goes full
//    screen; it describes the caller's own space.
//
//  What does change is the desktop: in a full-screen space the Finder's
//  desktop window and the wallpaper are simply not in the list. Crucially the
//  list does *not* cull occluded windows — a window covering the entire display
//  leaves both of them present — so their absence means the space itself has no
//  desktop, which is exactly what a full-screen space is.
//

import AppKit
import Foundation

/// The two fields of a window this decision needs, lifted out of Core
/// Graphics' dictionaries so the rule can be tested with plain values.
struct WindowSample: Equatable, Sendable {
    /// `kCGWindowLayer`, comparable against `CGWindowLevelForKey`.
    var layer: Int
    /// `kCGWindowBounds`, in Core Graphics' top-left-origin global space.
    var bounds: CGRect
}

enum FullScreenDetector {

    /// Where the Finder draws the desktop. A public constant, so this is not a
    /// magic number lifted from a window dump.
    static let desktopLayer = Int(CGWindowLevelForKey(.desktopIconWindow))

    /// Whether `display` is showing a full-screen app.
    ///
    /// Both halves have to hold: the desktop is missing *and* something at the
    /// normal window level covers the display. Requiring the second is what
    /// keeps the answer sane if the first ever stops being reliable — a Mac
    /// with desktop icons switched off entirely, say — because then the worst
    /// case degrades to "a window is covering the screen" rather than "always".
    nonisolated static func isFullScreen(
        display: CGRect,
        windows: [WindowSample],
        menuBarHeight: CGFloat
    ) -> Bool {
        guard !display.isEmpty else { return false }

        let hasDesktop = windows.contains { $0.layer == desktopLayer && covers(display, $0.bounds, allowingTopInset: 0) }
        guard !hasDesktop else { return false }

        return windows.contains {
            $0.layer == Int(CGWindowLevelForKey(.normalWindow))
                && covers(display, $0.bounds, allowingTopInset: menuBarHeight)
        }
    }

    /// Whether `window` spans the display's full width and reaches from the top
    /// (or from just under the menu bar) all the way down.
    ///
    /// A point of slack absorbs the half-pixel rounding that shows up on
    /// scaled displays.
    private nonisolated static func covers(
        _ display: CGRect,
        _ window: CGRect,
        allowingTopInset topInset: CGFloat
    ) -> Bool {
        window.minX <= display.minX + 1
            && window.maxX >= display.maxX - 1
            && window.minY <= display.minY + topInset + 1
            && window.maxY >= display.maxY - 1
    }

    /// Current on-screen windows, reduced to the fields the rule uses.
    ///
    /// `optionOnScreenOnly` reports the *active* space, which is what makes
    /// this work: in a full-screen space the desktop is genuinely not there.
    @MainActor
    static func snapshot() -> [WindowSample] {
        // Deliberately *not* `.excludeDesktopElements`: the desktop windows are
        // the whole signal, and excluding them would make every space look
        // full-screen.
        guard let raw = CGWindowListCopyWindowInfo(
            .optionOnScreenOnly,
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        return raw.compactMap { entry in
            guard let layer = entry[kCGWindowLayer as String] as? Int,
                  let raw = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: raw) else { return nil }
            return WindowSample(layer: layer, bounds: bounds)
        }
    }
}
