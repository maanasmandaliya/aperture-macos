//
//  SwipeRecognizer.swift
//  Aperture
//
//  Turns a stream of scroll events into at most one swipe per gesture.
//

import Foundation

/// A scroll event reduced to what the recogniser needs.
///
/// Deliberately free of `NSEvent` so the gesture rules can be tested directly;
/// ``OverlayMouseTracker`` does the translation.
struct ScrollSample: Equatable, Sendable {
    /// Distance the user's fingers moved *down*, sign-normalised against the
    /// system's natural-scrolling setting.
    var fingerDownDelta: CGFloat
    /// Distance the user's fingers moved *right*, normalised the same way.
    var fingerRightDelta: CGFloat = 0
    var isGestureStart: Bool = false
    var isGestureEnd: Bool = false
    /// Trackpad coasting after the fingers have lifted.
    var isMomentum: Bool = false
    /// Wheel mice report no phase at all, which changes how a gesture's
    /// boundaries have to be inferred.
    var hasPhase: Bool = true
    var timestamp: TimeInterval = 0
}

/// Accumulates finger travel and reports a swipe once per gesture.
///
/// Four rules earn their keep here:
/// * **One action per gesture.** Without a latch, a long flick keeps clearing
///   the threshold and would page through every pane in one go.
/// * **The dominant axis wins.** Real two-finger swipes are never perfectly
///   straight, so both axes accumulate and whichever has travelled further when
///   the threshold falls decides the gesture. A slightly diagonal page-swipe
///   must not also skip a track.
/// * **Momentum is ignored.** After the fingers lift the trackpad keeps sending
///   events; acting on them makes a single flick behave like several.
/// * **Wheel mice get an idle gap.** They report no phase, so a pause longer
///   than ``gestureGap`` is what separates one gesture from the next.
struct SwipeRecognizer: Equatable, Sendable {

    enum Outcome: Equatable, Sendable {
        case none
        case swipedDown
        case swipedUp
        case swipedLeft
        case swipedRight
    }

    /// Finger travel, in points, needed to commit to a swipe.
    var threshold: CGFloat
    /// Quiet period that ends a phaseless gesture.
    var gestureGap: TimeInterval = 0.4

    private var travelDown: CGFloat = 0
    private var travelRight: CGFloat = 0
    private var hasFired = false
    private var lastTimestamp: TimeInterval = -.greatestFiniteMagnitude

    init(threshold: CGFloat, gestureGap: TimeInterval = 0.4) {
        self.threshold = threshold
        self.gestureGap = gestureGap
    }

    mutating func reset() {
        travelDown = 0
        travelRight = 0
        hasFired = false
    }

    mutating func consume(_ sample: ScrollSample) -> Outcome {
        guard !sample.isMomentum else { return .none }

        let startsGesture = sample.isGestureStart
            || (!sample.hasPhase && sample.timestamp - lastTimestamp > gestureGap)
        if startsGesture { reset() }
        lastTimestamp = sample.timestamp

        if sample.isGestureEnd {
            reset()
            return .none
        }

        travelDown += sample.fingerDownDelta
        travelRight += sample.fingerRightDelta
        guard !hasFired else { return .none }

        let vertical = abs(travelDown)
        let horizontal = abs(travelRight)
        guard max(vertical, horizontal) >= threshold else { return .none }

        hasFired = true
        if vertical >= horizontal {
            return travelDown > 0 ? .swipedDown : .swipedUp
        }
        return travelRight > 0 ? .swipedRight : .swipedLeft
    }
}
