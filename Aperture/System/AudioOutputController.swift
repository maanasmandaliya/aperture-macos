//
//  AudioOutputController.swift
//  Aperture
//
//  Reads and sets the default output device's volume through CoreAudio's public
//  HAL property API, and reports honest capability so the UI can disable itself
//  rather than pretend.
//

import AudioToolbox
import CoreAudio
import Observation
import OSLog
import SwiftUI

@MainActor
@Observable
final class AudioOutputController {

    enum Capability: Equatable, Sendable {
        case readWrite
        case readOnly
        case unavailable(reason: String)

        var isUnavailable: Bool {
            if case .unavailable = self { return true }
            return false
        }

        var canRead: Bool { !isUnavailable }
        var canWrite: Bool { self == .readWrite }

        var unavailableReason: String? {
            if case .unavailable(let reason) = self { return reason }
            return nil
        }
    }

    /// One selectable output device.
    struct Device: Identifiable, Equatable, Sendable {
        var id: AudioObjectID
        var name: String
        /// Best-guess SF Symbol for the kind of device, from its transport type.
        var symbolName: String
    }

    private(set) var level: Double = 0
    private(set) var isMuted: Bool = false
    private(set) var deviceName: String = ""
    private(set) var capability: Capability = .unavailable(reason: "No output device")
    /// Every device that can play audio right now.
    private(set) var availableDevices: [Device] = []

    /// Fires when the *user* changed volume elsewhere (keyboard, Control
    /// Centre), so the app can raise a HUD without polling.
    var onExternalChange: ((Double, Bool) -> Void)?

    private let log = Logger(subsystem: ApertureInfo.bundleIdentifier, category: "Audio")
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var listeners: [AudioObjectPropertyAddress] = []
    private var isSettingLocally = false

    /// CoreAudio delivers listener callbacks on its own dispatch queue; hopping
    /// to the main actor here keeps every observable mutation on one actor.
    /// Stored (not computed) because removal requires the identical block.
    @ObservationIgnored
    private var listenerBlock: AudioObjectPropertyListenerBlock = { _, _ in }

    init() {
        listenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.handleExternalChange() }
        }
        attachToDefaultDevice()
        installDefaultDeviceListener()
    }

    /// Explicit teardown. `deinit` cannot do this: it is `nonisolated` on a
    /// `@MainActor` type and so cannot touch the isolated listener state, and
    /// CoreAudio needs the exact block reference to unregister.
    func invalidate() {
        removeListeners()
    }

    // MARK: - Public

    func setLevel(_ newValue: Double) {
        guard capability.canWrite, deviceID != kAudioObjectUnknown else { return }
        let clamped = Float32(min(max(newValue, 0), 1))

        isSettingLocally = true
        defer { isSettingLocally = false }

        if writeFloat(clamped, selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, element: kAudioObjectPropertyElementMain)
            || writeStereo(clamped) {
            level = Double(clamped)
            if clamped > 0, isMuted { setMuted(false) }
        }
    }

    func setMuted(_ muted: Bool) {
        guard deviceID != kAudioObjectUnknown else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = muted ? 1 : 0
        let status = AudioObjectSetPropertyData(
            deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value
        )
        if status == noErr { isMuted = muted }
    }

    func refresh() {
        guard deviceID != kAudioObjectUnknown else { return }
        level = readLevel() ?? level
        isMuted = readMuted() ?? isMuted
    }

    /// Identifier of the device currently receiving audio.
    var currentDeviceID: AudioObjectID { deviceID }

    /// SF Symbol describing the device currently playing.
    var currentDeviceSymbol: String {
        availableDevices.first { $0.id == deviceID }?.symbolName ?? "hifispeaker"
    }

    /// Re-enumerates selectable output devices.
    func reloadDevices() {
        availableDevices = Self.outputDevices()
    }

    /// Makes `device` the system's default output.
    ///
    /// `kAudioHardwarePropertyDefaultOutputDevice` is settable, which is the
    /// public equivalent of picking a device in Sound settings. It is *not* an
    /// AirPlay picker — macOS exposes no public API for that popover — so only
    /// devices already present to CoreAudio appear here.
    func selectDevice(_ device: Device) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var newID = device.id
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioObjectID>.size), &newID
        )
        if status == noErr {
            attachToDefaultDevice()
        } else {
            log.notice("Could not switch output device: \(status)")
        }
    }

    private static func outputDevices() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids
        ) == noErr else { return [] }

        return ids.compactMap { id in
            guard hasOutputStreams(id), let name = name(of: id) else { return nil }
            return Device(id: id, name: name, symbolName: symbolName(for: id))
        }
    }

    /// A device is an *output* device only if it publishes output streams;
    /// microphones and aggregate inputs otherwise show up in the list.
    private static func hasOutputStreams(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    private static func symbolName(for device: AudioObjectID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else {
            return "hifispeaker"
        }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "airpodspro"
        case kAudioDeviceTransportTypeUSB: return "hifispeaker.fill"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return "waveform"
        default: return "hifispeaker"
        }
    }

    // MARK: - Device wiring

    private func attachToDefaultDevice() {
        removeListeners()

        guard let newDevice = Self.defaultOutputDevice() else {
            deviceID = AudioObjectID(kAudioObjectUnknown)
            capability = .unavailable(reason: "No audio output device is available.")
            deviceName = ""
            return
        }

        deviceID = newDevice
        deviceName = Self.name(of: newDevice) ?? "Output"

        if let current = readLevel() {
            level = current
            capability = isVolumeSettable() ? .readWrite : .readOnly
        } else {
            // Aggregate devices and many USB interfaces expose no scalar volume
            // at all; there is no public fallback, so say so plainly.
            capability = .unavailable(
                reason: "\(deviceName) doesn't expose a software volume control."
            )
        }
        isMuted = readMuted() ?? false
        availableDevices = Self.outputDevices()

        installDeviceListeners()
    }

    private func installDeviceListeners() {
        guard deviceID != kAudioObjectUnknown else { return }
        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            kAudioDevicePropertyVolumeScalar,
            kAudioDevicePropertyMute,
        ]
        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, nil, listenerBlock)
            if status == noErr { listeners.append(address) }
        }
    }

    private func installDefaultDeviceListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, nil
        ) { [weak self] _, _ in
            Task { @MainActor in self?.attachToDefaultDevice() }
        }
    }

    private func removeListeners() {
        guard deviceID != kAudioObjectUnknown else {
            listeners.removeAll()
            return
        }
        for var address in listeners {
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, nil, listenerBlock)
        }
        listeners.removeAll()
    }

    private func handleExternalChange() {
        let previousLevel = level
        let previousMute = isMuted
        refresh()
        guard !isSettingLocally else { return }
        if abs(previousLevel - level) > 0.001 || previousMute != isMuted {
            onExternalChange?(level, isMuted)
        }
    }

    // MARK: - HAL access

    private func readLevel() -> Double? {
        if let value = readFloat(selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, element: kAudioObjectPropertyElementMain) {
            return Double(value)
        }
        // Some devices only publish per-channel scalars; average the front pair.
        let left = readFloat(selector: kAudioDevicePropertyVolumeScalar, element: 1)
        let right = readFloat(selector: kAudioDevicePropertyVolumeScalar, element: 2)
        switch (left, right) {
        case let (l?, r?): return Double((l + r) / 2)
        case let (l?, nil): return Double(l)
        case let (nil, r?): return Double(r)
        default: return nil
        }
    }

    private func readMuted() -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private func isVolumeSettable() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var settable = DarwinBoolean(false)
        if AudioObjectHasProperty(deviceID, &address),
           AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr {
            return settable.boolValue
        }
        address.mSelector = kAudioDevicePropertyVolumeScalar
        address.mElement = 1
        if AudioObjectHasProperty(deviceID, &address),
           AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr {
            return settable.boolValue
        }
        return false
    }

    private func readFloat(selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private func writeFloat(_ value: Float32, selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var mutableValue = value
        return AudioObjectSetPropertyData(
            deviceID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &mutableValue
        ) == noErr
    }

    private func writeStereo(_ value: Float32) -> Bool {
        let left = writeFloat(value, selector: kAudioDevicePropertyVolumeScalar, element: 1)
        let right = writeFloat(value, selector: kAudioDevicePropertyVolumeScalar, element: 2)
        return left || right
    }

    // MARK: - Statics

    private static func defaultOutputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func name(of device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // The HAL hands back a +1 CFString, so it is received unmanaged and
        // released here rather than being bridged straight into a `CFString`
        // variable (which would leak and confuse ARC).
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr,
              let name else { return nil }
        return name.takeRetainedValue() as String
    }
}
