//
//  MirrorGeometry.swift
//  Aperture
//
//  The mirror's rules, kept free of AVFoundation so they can be unit-tested:
//  when the camera may run, which part of a camera frame the preview shows, and
//  what a saved photo is called.
//

import CoreGraphics
import Foundation

enum MirrorGeometry {

    // MARK: - When the camera runs

    /// Whether the Mirror pane is what the overlay is showing.
    static func showsMirror(_ presentation: OverlayPresentation) -> Bool {
        presentation == .expanded(.mirror)
    }

    /// The camera runs only while its pane is on screen, access is granted and
    /// the display is awake. Anything else — another pane, a collapsed hub, a
    /// paused overlay, a sleeping display — turns it off, so the camera light
    /// is never left on behind the user's back.
    static func shouldRun(showsMirror: Bool, isAuthorized: Bool, isDisplayAsleep: Bool) -> Bool {
        showsMirror && isAuthorized && !isDisplayAsleep
    }

    // MARK: - Crop

    /// The part of a camera frame the preview actually shows.
    ///
    /// The preview fills a box of `viewAspect` without letterboxing, so a frame
    /// of a different shape loses its sides or its top and bottom. The crop is
    /// centred, which is also why mirroring does not change the result — a saved
    /// photo can be cropped first and flipped after.
    static func visibleRect(imageSize: CGSize, viewAspect: CGFloat) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, viewAspect > 0 else { return .zero }

        var visible = imageSize
        if imageSize.width / imageSize.height > viewAspect {
            visible.width = imageSize.height * viewAspect
        } else {
            visible.height = imageSize.width / viewAspect
        }

        let rect = CGRect(
            x: (imageSize.width - visible.width) / 2,
            y: (imageSize.height - visible.height) / 2,
            width: visible.width,
            height: visible.height
        )
        // Whole pixels, never past the frame's edge.
        return rect.integral.intersection(CGRect(origin: .zero, size: imageSize))
    }

    // MARK: - Photos

    /// Pictures ▸ Aperture. Unlike Desktop, Documents or Downloads, the
    /// Pictures folder is not privacy-protected, so saving there raises no
    /// further permission prompt.
    static var photosDirectory: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures", isDirectory: true)
        return pictures.appendingPathComponent("Aperture", isDirectory: true)
    }

    /// "Aperture 2026-09-13 at 10.42.17.jpg" — sortable, and free of the colons
    /// Finder shows as slashes.
    static func photoFileName(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Aperture \(formatter.string(from: date)).jpg"
    }

    /// `name`, or failing that `name (2)`, `name (3)`… Two photos taken inside
    /// the same second must not overwrite each other.
    static func availableURL(in directory: URL, named name: String, exists: (URL) -> Bool) -> URL {
        let base = (name as NSString).deletingPathExtension
        let pathExtension = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var index = 2
        while exists(candidate) {
            candidate = directory.appendingPathComponent("\(base) (\(index)).\(pathExtension)")
            index += 1
        }
        return candidate
    }
}
