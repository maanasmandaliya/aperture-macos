//
//  AudioListenerTests.swift
//  ApertureTests
//

import CoreAudio
import XCTest
@testable import Aperture

// MARK: - CoreAudio listener threading

final class AudioListenerTests: XCTestCase {

    /// The regression this exists for. CoreAudio calls its listener blocks on
    /// its own thread; a main-actor-isolated closure traps there rather than
    /// returning, killing the app. If the listener is ever rebuilt inside the
    /// `@MainActor` class again, this test does not fail — it crashes, exactly
    /// as the app did.
    func testAListenerCalledOffTheMainThreadHopsToTheMainActor() {
        let ran = expectation(description: "the listener's work ran")
        let listener = AudioOutputController.makeListener {
            MainActor.assertIsolated("the hop must land on the main actor")
            ran.fulfill()
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            withUnsafePointer(to: &address) { listener(AudioObjectID(kAudioObjectSystemObject), $0) }
        }

        wait(for: [ran], timeout: 5)
    }
}
