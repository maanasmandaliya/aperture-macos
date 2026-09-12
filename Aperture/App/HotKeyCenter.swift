//
//  HotKeyCenter.swift
//  Aperture
//
//  Global shortcut registration via Carbon's `RegisterEventHotKey`.
//
//  This is deliberately not an `NSEvent` global monitor: monitoring key events
//  globally requires Accessibility permission, whereas a Carbon hot key needs no
//  permission at all and is still the only public API for a system-wide
//  shortcut in a non-sandboxed menu-bar app.
//

import AppKit
import Carbon.HIToolbox
import OSLog

/// Callback storage shared with the C event handler. The handler runs on the
/// main run loop, but Swift cannot prove that, so access is lock-guarded and the
/// hop back onto the main actor is explicit.
private final class HotKeyRegistry: @unchecked Sendable {
    static let shared = HotKeyRegistry()
    private let lock = NSLock()
    private var actions: [UInt32: @Sendable @MainActor () -> Void] = [:]

    func set(_ action: (@Sendable @MainActor () -> Void)?, for id: UInt32) {
        lock.lock(); defer { lock.unlock() }
        actions[id] = action
    }

    func action(for id: UInt32) -> (@Sendable @MainActor () -> Void)? {
        lock.lock(); defer { lock.unlock() }
        return actions[id]
    }
}

private let apertureHotKeySignature: OSType = 0x41505254 // 'APRT'
private let toggleHotKeyID: UInt32 = 1

private func apertureHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == apertureHotKeySignature else { return status }

    if let action = HotKeyRegistry.shared.action(for: hotKeyID.id) {
        Task { @MainActor in action() }
    }
    return noErr
}

@MainActor
final class HotKeyCenter {

    private let log = Logger(subsystem: ApertureInfo.bundleIdentifier, category: "HotKey")
    private var handlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private(set) var currentBinding: HotKeyBinding?
    private(set) var lastRegistrationFailed = false

    /// `true` once the Carbon event handler is installed.
    private var isHandlerInstalled = false

    func register(_ binding: HotKeyBinding, action: @escaping @Sendable @MainActor () -> Void) {
        unregister()
        guard binding.isValid else {
            lastRegistrationFailed = true
            return
        }

        installHandlerIfNeeded()
        HotKeyRegistry.shared.set(action, for: toggleHotKeyID)

        let id = EventHotKeyID(signature: apertureHotKeySignature, id: toggleHotKeyID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            binding.keyCode,
            binding.modifiers,
            id,
            GetEventDispatcherTarget(),
            0,
            &ref
        )

        if status == noErr, let ref {
            hotKeyRef = ref
            currentBinding = binding
            lastRegistrationFailed = false
        } else {
            // Most often means another app already owns the combination.
            lastRegistrationFailed = true
            log.notice("Hot key registration failed with status \(status)")
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        HotKeyRegistry.shared.set(nil, for: toggleHotKeyID)
        currentBinding = nil
    }

    func invalidate() {
        unregister()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
            isHandlerInstalled = false
        }
    }

    private func installHandlerIfNeeded() {
        guard !isHandlerInstalled else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            apertureHotKeyHandler,
            1,
            &eventType,
            nil,
            &handlerRef
        )
        isHandlerInstalled = (status == noErr)
        if status != noErr {
            log.error("Could not install hot key handler: \(status)")
        }
    }
}
