//
//  ArtworkFetcher.swift
//  Aperture
//
//  Downloading cover art.
//
//  This is the only place in Aperture that touches the network, and it exists
//  because two of the sources publish artwork as a URL rather than as image
//  data: Spotify's Apple Event `artwork` yields nothing on current builds, and a
//  web page's Media Session metadata is URLs by definition.
//
//  The URL therefore comes from outside — in Safari's case from whatever page
//  happens to be playing — so it is treated as untrusted input rather than as an
//  address to blindly GET:
//
//  * HTTPS only, which also keeps `http://localhost/…` and friends out. A page
//    can put anything in its Media Session metadata, and a media player has no
//    business fetching a private address on its behalf.
//  * A hard size ceiling and a short timeout, so a hostile or broken URL cannot
//    hold a slot open or exhaust memory.
//  * An ephemeral session: no cookies, no credentials, no on-disk cache, so a
//    request carries nothing about the user and leaves nothing behind.
//

import Foundation
import OSLog

actor ArtworkFetcher {

    /// Cover art is small. Anything larger is not cover art.
    private static let maximumBytes = 4 * 1024 * 1024
    private static let timeout: TimeInterval = 5

    private let log = Logger(subsystem: ApertureInfo.bundleIdentifier, category: "Artwork")
    private var cache: [URL: Data] = [:]
    /// URLs already known to be unusable, so a broken cover is not re-requested
    /// on every poll.
    private var failed: Set<URL> = []

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    /// Whether this is an address Aperture is willing to request.
    ///
    /// Deliberately strict and deliberately pure, so the rule can be tested
    /// without a network.
    nonisolated static func isFetchable(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        // Not exhaustive against DNS pointing at a private address, but it
        // removes the obvious ways a page could aim Aperture at its own machine.
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return false }
        if host == "127.0.0.1" || host == "::1" || host == "[::1]" { return false }
        if host.hasPrefix("10.") || host.hasPrefix("192.168.") || host.hasPrefix("169.254.") { return false }
        if let second = host.split(separator: ".").dropFirst().first,
           host.hasPrefix("172."), let octet = Int(second), (16...31).contains(octet) { return false }
        return true
    }

    /// Whether these bytes are an image, by magic number.
    ///
    /// Needed because an Apple Event that has no artwork does not necessarily
    /// come back empty — `missing value` still carries bytes — so "non-empty"
    /// is not the same as "an image". Storing those bytes yields a cover that
    /// silently fails to decode, which looks exactly like having no artwork at
    /// all and hides the fact that a fallback was never tried.
    nonisolated static func looksLikeImage(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(12))
        guard bytes.count >= 12 else { return false }

        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return true }           // PNG
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return true }                 // JPEG
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return true }           // GIF
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00]) { return true }           // TIFF, little-endian
        if bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return true }           // TIFF, big-endian
        if bytes.starts(with: [0x52, 0x49, 0x46, 0x46]),                          // WEBP
           Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50] { return true }
        if Array(bytes[4..<8]) == [0x66, 0x74, 0x79, 0x70] { return true }        // HEIC/AVIF
        return false
    }

    func data(for url: URL) async -> Data? {
        if let cached = cache[url] { return cached }
        guard !failed.contains(url) else { return nil }

        guard Self.isFetchable(url) else {
            failed.insert(url)
            log.notice("Refusing artwork URL that is not a public https address.")
            return nil
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = Self.timeout
            request.httpShouldHandleCookies = false
            let (data, response) = try await session.data(for: request)

            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                failed.insert(url)
                return nil
            }
            // A cover that is not an image is not a cover.
            if let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
               !type.hasPrefix("image/") {
                failed.insert(url)
                return nil
            }
            guard !data.isEmpty, data.count <= Self.maximumBytes, Self.looksLikeImage(data) else {
                failed.insert(url)
                return nil
            }

            if cache.count > 8 { cache.removeAll(keepingCapacity: true) }
            cache[url] = data
            // Host only, never the full path: the path identifies the track.
            log.notice("Fetched \(data.count, privacy: .public) bytes of artwork from \(url.host() ?? "?", privacy: .public)")
            return data
        } catch {
            failed.insert(url)
            log.debug("Artwork fetch failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
