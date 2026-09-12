//
//  ApertureInfo.swift
//  Aperture
//

import Foundation

enum ApertureInfo {
    static let name = "Aperture"
    static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.aperture.overlay"

    static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    static var versionDescription: String { "Version \(shortVersion) (\(buildNumber))" }

    static let tagline = "A quiet status hub for the top of your display."

    static let privacyStatement = """
        Aperture is local-first. Calendar events are read through EventKit and \
        stay on this Mac; nothing is uploaded, and there is no analytics or \
        crash reporting of any kind. Media details come only from the source you \
        pick in Settings. Aperture does not read other apps' system \
        notifications — macOS provides no public way to do that, and Aperture \
        will not use a private one for it.
        """
}
