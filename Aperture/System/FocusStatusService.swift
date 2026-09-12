//
//  FocusStatusService.swift
//  Aperture
//
//  Focus state via the public `INFocusStatusCenter`. Authorization is requested
//  only when the user opens the Controls tab, and a refusal (or an unsigned
//  build, where the Intents entitlement check fails) degrades to a clearly
//  labelled "unknown" row rather than a guess.
//

import Intents
import Observation
import OSLog
import SwiftUI

@MainActor
@Observable
final class FocusStatusService {

    enum State: Equatable, Sendable {
        case unknown
        case notAuthorized
        case unavailable
        case off
        case on

        var displayText: String {
            switch self {
            case .unknown: "Unknown"
            case .notAuthorized: "Permission needed"
            case .unavailable: "Not available"
            case .off: "Off"
            case .on: "On"
            }
        }

        var symbolName: String {
            switch self {
            case .on: "moon.fill"
            case .off: "moon"
            default: "questionmark.circle"
            }
        }
    }

    private(set) var state: State = .unknown

    private let log = Logger(subsystem: ApertureInfo.bundleIdentifier, category: "Focus")
    private var observer: NSObjectProtocol?

    init() {
        refresh()
        // Focus changes broadcast a distributed notification; observing it is
        // far better than polling, and harmless when it never fires.
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.donotdisturb.state"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func invalidate() {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
            self.observer = nil
        }
    }

    var needsAuthorization: Bool {
        INFocusStatusCenter.default.authorizationStatus == .notDetermined
    }

    func requestAuthorization() async {
        guard needsAuthorization else { return }
        await withCheckedContinuation { continuation in
            INFocusStatusCenter.default.requestAuthorization { _ in
                continuation.resume()
            }
        }
        refresh()
    }

    func refresh() {
        switch INFocusStatusCenter.default.authorizationStatus {
        case .notDetermined:
            state = .notAuthorized
        case .denied, .restricted:
            state = .notAuthorized
        case .authorized:
            if let focused = INFocusStatusCenter.default.focusStatus.isFocused {
                state = focused ? .on : .off
            } else {
                state = .unknown
            }
        @unknown default:
            state = .unavailable
        }
    }
}
