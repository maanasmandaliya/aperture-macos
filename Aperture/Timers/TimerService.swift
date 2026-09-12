//
//  TimerService.swift
//  Aperture
//
//  Aperture's own countdown timers. A single run-loop timer drives the UI at 1
//  Hz only while a countdown is actually running; the model itself is derived
//  from dates, so a missed tick never causes drift.
//

import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class TimerService {

    private(set) var active: TimerActivity?
    /// Raised once when a running timer reaches zero.
    var onCompletion: ((TimerActivity) -> Void)?

    private var ticker: Timer?
    /// Bumped every tick purely so SwiftUI re-renders countdown text.
    private(set) var tick: Date = .now

    func start(title: String, duration: TimeInterval) {
        let timer = TimerActivity(
            id: UUID(),
            title: title.isEmpty ? "Timer" : title,
            total: duration,
            fireDate: Date().addingTimeInterval(duration),
            pausedRemaining: nil
        )
        active = timer
        startTicking()
    }

    func togglePause() {
        guard var timer = active else { return }
        if let remaining = timer.pausedRemaining {
            timer.fireDate = Date().addingTimeInterval(remaining)
            timer.pausedRemaining = nil
            active = timer
            startTicking()
        } else {
            timer.pausedRemaining = timer.remaining(at: Date())
            timer.fireDate = nil
            active = timer
            stopTicking()
        }
    }

    func stop() {
        active = nil
        stopTicking()
    }

    func addTime(_ interval: TimeInterval) {
        guard var timer = active else { return }
        timer.total += interval
        if let remaining = timer.pausedRemaining {
            timer.pausedRemaining = remaining + interval
        } else if let fireDate = timer.fireDate {
            timer.fireDate = fireDate.addingTimeInterval(interval)
        }
        active = timer
        startTicking()
    }

    func invalidate() { stopTicking() }

    /// Preview/test seam: installs a timer without starting the run-loop clock.
    func previewSeed(_ timer: TimerActivity?) {
        active = timer
    }

    // MARK: - Ticking

    private func startTicking() {
        guard ticker == nil, let timer = active, !timer.isPaused else { return }
        let runLoopTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        runLoopTimer.tolerance = 0.1
        RunLoop.main.add(runLoopTimer, forMode: .common)
        ticker = runLoopTimer
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    private func step() {
        let now = Date()
        tick = now
        guard let timer = active else {
            stopTicking()
            return
        }
        if timer.hasCompleted(at: now) {
            active = nil
            stopTicking()
            onCompletion?(timer)
        }
    }
}
