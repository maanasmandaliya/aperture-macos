//
//  MediaKeyTap.swift
//  Aperture
//
//  Taking the volume and brightness keys before macOS sees them.
//
//  macOS draws its own volume/brightness panel from `OSDUIHelper` whenever the
//  *system* handles one of these keys, and exposes no public way to silence it.
//  The only way to show Aperture's readout alone is to consume the key first and
//  perform the change here, which is what this does.
//
//  That needs an event tap that can swallow events, and macOS gates those behind
//  Accessibility permission. Without it `CGEvent.tapCreate` returns nil, the tap
//  is simply never installed, and the keys keep working exactly as they always
//  did — the failure mode is "macOS handles it", never "nothing happens".
//
//  Everything here is public API: `CGEvent`, and the `NX_KEYTYPE_*` constants
//  from IOKit's public `ev_keymap.h`.
//

import AppKit
import CoreGraphics
import IOKit.hid
import IOKit.hidsystem
import OSLog

/// A key Aperture is willing to take over.
enum MediaKey: Equatable, Sendable {
    case volumeUp
    case volumeDown
    case mute
    case brightnessUp
    case brightnessDown
}

/// One decoded press.
struct MediaKeyPress: Equatable, Sendable {
    var key: MediaKey
    /// Shift+Option, macOS's quarter-step modifier.
    var isFineAdjustment: Bool
}

@MainActor
final class MediaKeyTap {

    /// Raised for a key Aperture has consumed. Whatever handles this is now
    /// responsible for the change itself — macOS will not make it.
    var onPress: ((MediaKeyPress) -> Void)?

    /// Whether the tap is installed and swallowing keys right now.
    private(set) var isActive = false

    private let log = Logger(subsystem: ApertureInfo.bundleIdentifier, category: "MediaKeys")
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// `NSEvent.EventType.systemDefined`. `CGEventType` has no case for it —
    /// the AppKit and CoreGraphics event enumerations only partly overlap — so
    /// the raw value is used for both the mask and the comparison.
    private static let systemDefinedType: UInt32 = 14

    /// Whether macOS will let this process create a consuming event tap.
    ///
    /// - Parameter prompting: shows the system's permission dialog. Only ever
    ///   true as the direct result of the user asking, never at launch.
    static func isPermitted(prompting: Bool = false) -> Bool {
        // Spelled out rather than read from `kAXTrustedCheckOptionPrompt`: that
        // symbol is a mutable global, which Swift 6 will not let a concurrent
        // context touch. The string is the documented key.
        let options = ["AXTrustedCheckOptionPrompt": prompting]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Whether macOS will let this process read keyboard-derived events.
    ///
    /// Separate from Accessibility, and both are needed: Input Monitoring to
    /// *see* the key, Accessibility to *swallow* it.
    static func canListenToInput() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Asks for Input Monitoring.
    ///
    /// This is also the only way the app ever appears in System Settings -
    /// Privacy & Security - Input Monitoring: that list has no "+" button and
    /// nothing populates it but the request itself, so an app that never asks
    /// simply is not there to be ticked.
    @discardableResult
    static func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    static func openAccessibilitySettings() {
        open("Privacy_Accessibility")
    }

    /// Consuming keyboard-derived events needs Input Monitoring as well as
    /// Accessibility on recent macOS; granting only one leaves `tapCreate`
    /// refused with no indication of which is missing.
    static func openInputMonitoringSettings() {
        open("Privacy_ListenEvent")
    }

    private static func open(_ anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Lifecycle

    @discardableResult
    func start() -> Bool {
        guard !isActive else { return true }

        // System-defined events only. An earlier diagnostic widened this to
        // `keyDown`, which meant the tap saw every keystroke on the machine —
        // far too much reach for an overlay, and not something to leave in place
        // once the question it answered was settled.
        let mask = CGEventMask(1 << Self.systemDefinedType)
        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // Not `.listenOnly`: the whole point is to swallow the event so the
            // system never draws its own panel.
            options: .defaultTap,
            eventsOfInterest: mask,
            // Decoding happens out here, before hopping to the main actor:
            // `CGEvent` and `NSEvent` are not `Sendable`, so only the decoded
            // `MediaKeyPress` — which is — may cross the isolation boundary.
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let tap = { Unmanaged<MediaKeyTap>.fromOpaque(context).takeUnretainedValue() }

                // The system disables a tap that takes too long, or when the
                // user's own input needs priority. Re-enabling is the
                // documented recovery; without it the keys would quietly stop
                // reaching Aperture.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    MainActor.assumeIsolated { tap().reenable() }
                    return Unmanaged.passUnretained(event)
                }

                guard type.rawValue == MediaKeyTap.systemDefinedType,
                      let nsEvent = NSEvent(cgEvent: event) else {
                    return Unmanaged.passUnretained(event)
                }
                guard let press = MediaKeyTap.decode(nsEvent) else {
                    return Unmanaged.passUnretained(event)
                }

                MainActor.assumeIsolated { tap().onPress?(press) }
                // Swallowed: macOS never handles it, so no system panel appears.
                return nil
            },
            userInfo: context
        ) else {
            // Almost always missing Accessibility permission. Nothing is
            // installed, so the keys keep behaving normally.
            log.notice("Media key tap not created; Accessibility permission is required")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        runLoopSource = source
        isActive = true
        return true
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CFMachPortInvalidate(tap)
        self.tap = nil
        runLoopSource = nil
        isActive = false
    }

    // MARK: - Event handling

    private func reenable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Decodes a system-defined event into a media key press.
    ///
    /// The keyboard packs the key, its state and its repeat flag into `data1`:
    /// the key in the high 16 bits, `0x0A` in the state byte for a press and
    /// `0x0B` for a release, and a low bit documented as auto-repeat. That bit
    /// is ignored: this keyboard sets it on fresh presses too, so held keys are
    /// told apart by pace instead — see `AppEnvironment.isAutoRepeat`. Only
    /// presses are reported — acting on the release too would double every step.
    nonisolated static func decode(_ event: NSEvent) -> MediaKeyPress? {
        guard event.type == .systemDefined,
              event.subtype.rawValue == Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS) else { return nil }

        return decode(
            data1: event.data1,
            modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        )
    }

    /// The rule on its own, so it can be tested without an `NSEvent`.
    nonisolated static func decode(data1: Int, modifiers: NSEvent.ModifierFlags) -> MediaKeyPress? {
        let keyCode = Int32((data1 & 0xFFFF_0000) >> 16)
        let flags = data1 & 0x0000_FFFF
        let isDown = ((flags & 0xFF00) >> 8) == 0x0A
        guard isDown else { return nil }

        let key: MediaKey
        switch keyCode {
        case NX_KEYTYPE_SOUND_UP: key = .volumeUp
        case NX_KEYTYPE_SOUND_DOWN: key = .volumeDown
        case NX_KEYTYPE_MUTE: key = .mute
        case NX_KEYTYPE_BRIGHTNESS_UP: key = .brightnessUp
        case NX_KEYTYPE_BRIGHTNESS_DOWN: key = .brightnessDown
        // Play/pause and track keys are left to whichever app owns playback.
        // Anything unrecognised returns nil and passes through untouched.
        default: return nil
        }

        return MediaKeyPress(
            key: key,
            isFineAdjustment: modifiers.contains(.shift) && modifiers.contains(.option)
        )
    }
}
