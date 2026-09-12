//
//  BrightnessController.swift
//  Aperture
//
//  Brightness is the least even surface on macOS, and it takes three routes to
//  cover the machines Aperture runs on, tried in this order:
//
//  * External DDC/CI displays publish a brightness parameter through
//    `IODisplayConnect`, read and written with `IODisplayGetFloatParameter` /
//    `IODisplaySetFloatParameter`. Fully documented, and preferred when present.
//
//  * Apple Silicon built-in panels go through DisplayServices, a private
//    framework — the one exception to Aperture's public-API rule, taken at the
//    user's explicit request. `DisplayServices` below records the measurement
//    that forced it.
//
//  * Should DisplayServices be missing, the backlight's I/O Registry entry
//    (`AppleARMBacklight`) is read and written through public IOKit calls with
//    undocumented key names. A fallback only: `corebrightnessd` overwrites
//    those writes, so they cannot be relied on to change the screen.
//
//  Changes made elsewhere reach the built-in panel's readout without a timer:
//  the backlight's registry entry raises `kIOGeneralInterest` messages —
//  though not for every change, so the brightness keys present their readout
//  directly rather than waiting on one. Only the external DDC/CI route polls,
//  because IOKit publishes nothing to listen to there.
//

import CoreGraphics
import IOKit
import IOKit.graphics
import Observation
import OSLog
import SwiftUI

@MainActor
@Observable
final class BrightnessController {

    enum Capability: Equatable, Sendable {
        case readWrite
        case readOnly
        case unavailable(reason: String)

        var isUnavailable: Bool {
            if case .unavailable = self { return true }
            return false
        }

        var canWrite: Bool { self == .readWrite }

        var unavailableReason: String? {
            if case .unavailable(let reason) = self { return reason }
            return nil
        }
    }

    /// Which of the two routes is in use, resolved on every refresh so
    /// plugging in a display switches route without restarting.
    private enum Route: Equatable {
        /// External display exposing a documented IOKit brightness parameter.
        case ioDisplay
        /// Apple Silicon built-in panel, through DisplayServices.
        case displayServices(CGDirectDisplayID)
        /// Apple Silicon built-in panel, via the backlight's registry entry —
        /// the fallback when DisplayServices is unavailable.
        case panel
    }

    private(set) var level: Double = 0
    private(set) var displayName: String = ""
    private(set) var capability: Capability = .unavailable(reason: "Checking…")

    var onExternalChange: ((Double, String) -> Void)?

    static let unsupportedExplanation = """
        This display publishes no brightness control Aperture can reach. \
        External displays are driven through IOKit's documented brightness \
        parameter, and Apple Silicon built-in panels through their backlight \
        registry entry, with DisplayServices tried first for the built-in \
        panel; none of these answered here.
        """

    /// Registry keys for the built-in panel's backlight.
    ///
    /// This reads `AppleARMBacklight`'s `IODisplayParameters`, which is the same
    /// `{min, max, value}` shape the documented `IODisplayGetFloatParameter`
    /// works on — that call answers `kIOReturnUnsupported` here, so the
    /// dictionary is read directly instead. The values it holds are the *user's*
    /// brightness on a fixed 0…max scale, and they agree with the slider in
    /// System Settings.
    ///
    /// The earlier route read `IOMFBBrightnessLevel` against `BLNitsCap` on
    /// `AppleCLCD2`, in nits. That was wrong twice over: the cap moves with the
    /// ambient-light sensor, so the same physical brightness reported different
    /// percentages minute to minute, and HDR content pushes the level above the
    /// cap, which read as a pinned 100%. Measured side by side, it claimed 100%
    /// while the system slider sat at 50%.
    private enum PanelKey {
        static let service = "AppleARMBacklight"
        static let parameters = "IODisplayParameters"
        /// Sub-dictionary, and the property name a write is addressed to.
        static let brightness = "brightness"
        static let value = "value"
        static let maximum = "max"
    }

    /// Never written below this. Zero appears to be accepted, and a display the
    /// user cannot see is a state they cannot get out of from inside the app.
    nonisolated static let minimumFraction = 0.05

    private let log = Logger(subsystem: ApertureInfo.bundleIdentifier, category: "Brightness")
    private var pollTimer: Timer?
    private var isSettingLocally = false
    private var lastLocalWrite = Date.distantPast
    private var route: Route?

    /// Whether the panel accepted a write, probed once when the route is
    /// resolved. Re-probing on every refresh would mean writing to the display
    /// on every notification — and each write raises another notification.
    private var panelAcceptsWrites: Bool?

    /// Live registration on the backlight's registry entry. The service is
    /// retained for as long as it is observed, unlike the read paths which
    /// resolve and release per call.
    @ObservationIgnored private var notificationPort: IONotificationPortRef?
    @ObservationIgnored private var observedService: io_service_t = 0
    @ObservationIgnored private var interestNotification: io_object_t = 0

    init() {
        refresh()
    }

    func start() {
        guard !capability.isUnavailable else { return }

        switch route {
        case .panel, .displayServices:
            observePanel()
        case .ioDisplay:
            startPolling()
        case nil:
            break
        }
    }

    func invalidate() {
        stopPolling()
        stopObservingPanel()
    }

    /// The external route only. IOKit publishes no change notification for a
    /// DDC/CI display, so this is the one place Aperture still polls — slowly,
    /// and only while such a display is attached.
    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollForExternalChange() }
        }
        timer.tolerance = 0.75
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Panel notifications

    /// Registers for the backlight's change messages, so the slider follows the
    /// brightness keys as immediately as the volume slider follows the volume
    /// keys.
    private func observePanel() {
        guard notificationPort == nil, let service = Self.panelService() else { return }

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            IOObjectRelease(service)
            // Without a port there is nothing to listen on, so fall back to the
            // timer rather than silently stopping at whatever level was read.
            startPolling()
            return
        }
        // Delivering on the main queue is what makes `assumeIsolated` in the
        // callback sound.
        IONotificationPortSetDispatchQueue(port, .main)

        let context = Unmanaged.passUnretained(self).toOpaque()
        var notification: io_object_t = 0
        let status = IOServiceAddInterestNotification(
            port,
            service,
            kIOGeneralInterest,
            { context, _, _, _ in
                guard let context else { return }
                MainActor.assumeIsolated {
                    Unmanaged<BrightnessController>.fromOpaque(context)
                        .takeUnretainedValue()
                        .handlePanelChange()
                }
            },
            context,
            &notification
        )

        guard status == kIOReturnSuccess else {
            log.debug("Panel interest registration failed: \(status)")
            IONotificationPortDestroy(port)
            IOObjectRelease(service)
            startPolling()
            return
        }

        notificationPort = port
        observedService = service
        interestNotification = notification
    }

    private func stopObservingPanel() {
        if interestNotification != 0 {
            IOObjectRelease(interestNotification)
            interestNotification = 0
        }
        if observedService != 0 {
            IOObjectRelease(observedService)
            observedService = 0
        }
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }
    }

    /// The backlight raises two messages per change, so this reports only when
    /// the level has actually moved — and never for Aperture's own writes.
    private func handlePanelChange() {
        // The panel's notification arrives a beat *after* the write that caused
        // it, by which time a synchronous flag has already been cleared — so our
        // own change came back as an external one and raised a second readout.
        guard Date().timeIntervalSince(lastLocalWrite) > 0.4 else { return }
        guard !isSettingLocally else { return }
        let previous = level
        refresh()
        guard abs(previous - level) > 0.005 else { return }
        log.debug("external brightness change: \(previous, privacy: .public) -> \(self.level, privacy: .public)")
        onExternalChange?(level, displayName.isEmpty ? "Display" : displayName)
    }

    /// Moves brightness by `delta` of the full scale, from where the panel is
    /// *now*.
    ///
    /// Read fresh rather than taken from `level`: HDR content drives the
    /// backlight above its SDR maximum, where `level` is pinned at 1.0, and
    /// stepping from that would write the maximum — a brightness-*up* press
    /// that dims the screen.
    func step(by delta: Double) {
        guard capability.canWrite else { return }

        switch route {
        case .ioDisplay:
            guard let service = Self.ioDisplayService() else { return }
            defer { IOObjectRelease(service) }
            var current: Float = 0
            guard IODisplayGetFloatParameter(
                service, 0, kIODisplayBrightnessKey as CFString, &current
            ) == kIOReturnSuccess else { return }
            setLevel(Double(current) + delta)

        case .displayServices(let display):
            guard let current = DisplayServices.shared?.brightness(of: display) else { return }
            setLevel(current + delta)

        case .panel:
            guard let service = Self.panelService() else { return }
            defer { IOObjectRelease(service) }
            guard let (raw, cap) = Self.panelBrightness(service) else { return }
            let target = Self.stepped(raw: raw, cap: cap, by: delta)
            log.debug("step \(delta, privacy: .public): \(raw, privacy: .public) -> \(target, privacy: .public)")
            writePanel(target, service: service, cap: cap)

        case nil:
            return
        }
    }

    private func writePanel(_ raw: Int, service: io_service_t, cap: Int) {
        isSettingLocally = true
        lastLocalWrite = Date()
        defer { isSettingLocally = false }
        let status = IORegistryEntrySetCFProperty(service, PanelKey.brightness as CFString, raw as CFNumber)
        if status == KERN_SUCCESS {
            level = Self.fraction(level: raw, cap: cap)
            log.debug("Brightness set to \(raw, privacy: .public) of \(cap, privacy: .public)")
        } else {
            log.notice("panel write REFUSED: status=\(status, privacy: .public) value=\(raw, privacy: .public)")
        }
    }

    func setLevel(_ newValue: Double) {
        guard capability.canWrite else { return }
        let clamped = min(max(newValue, Self.minimumFraction), 1)

        isSettingLocally = true
        defer { isSettingLocally = false }

        switch route {
        case .ioDisplay:
            guard let service = Self.ioDisplayService() else { return }
            defer { IOObjectRelease(service) }
            let status = IODisplaySetFloatParameter(
                service, 0, kIODisplayBrightnessKey as CFString, Float(clamped)
            )
            if status == kIOReturnSuccess {
                level = clamped
            } else {
                log.debug("Brightness write refused: \(status)")
            }

        case .displayServices(let display):
            guard let services = DisplayServices.shared else { return }
            lastLocalWrite = Date()
            if services.set(display, Float(clamped)) == 0 {
                level = clamped
                log.debug("Brightness set to \(clamped, privacy: .public) via DisplayServices")
            } else {
                log.notice("DisplayServices refused brightness \(clamped, privacy: .public)")
            }

        case .panel:
            guard let service = Self.panelService() else { return }
            defer { IOObjectRelease(service) }
            guard let (_, cap) = Self.panelBrightness(service) else { return }
            writePanel(Self.rawLevel(fraction: clamped, cap: cap), service: service, cap: cap)

        case nil:
            return
        }
    }

    func refresh() {
        let previousRoute = route
        resolveRoute()
        // Attaching a monitor moves brightness from the built-in panel to the
        // external display, which listens a different way. Re-arming here means
        // any refresh repairs the wiring, so no separate display-change
        // observer is needed.
        if route != previousRoute, isObserving {
            stopPolling()
            stopObservingPanel()
            panelAcceptsWrites = nil
            start()
        }
    }

    private func resolveRoute() {
        if refreshFromIODisplay() { return }
        if refreshFromDisplayServices() { return }
        if refreshFromPanel() { return }
        route = nil
        capability = .unavailable(reason: Self.unsupportedExplanation)
        displayName = ""
    }

    /// Whether ``start`` has run and teardown has not — so a route change knows
    /// whether there is anything to re-arm.
    private var isObserving: Bool { pollTimer != nil || notificationPort != nil }

    /// External displays first: a documented parameter beats a probed one, and
    /// an attached monitor is the display the user means.
    private func refreshFromIODisplay() -> Bool {
        guard let service = Self.ioDisplayService() else { return false }
        defer { IOObjectRelease(service) }

        var value: Float = 0
        guard IODisplayGetFloatParameter(
            service, 0, kIODisplayBrightnessKey as CFString, &value
        ) == kIOReturnSuccess else { return false }

        route = .ioDisplay
        level = Double(value)
        displayName = Self.ioDisplayName(for: service) ?? "Display"
        // Writing the value it already has: proves the write path without
        // changing anything the user can see.
        let writeStatus = IODisplaySetFloatParameter(
            service, 0, kIODisplayBrightnessKey as CFString, value
        )
        capability = writeStatus == kIOReturnSuccess ? .readWrite : .readOnly
        return true
    }

    private func refreshFromDisplayServices() -> Bool {
        guard let services = DisplayServices.shared,
              let display = Self.builtInDisplayID(),
              let value = services.brightness(of: display) else { return false }

        route = .displayServices(display)
        level = min(max(value, 0), 1)
        displayName = Self.builtInDisplayName()
        capability = services.canChange(display) ? .readWrite : .readOnly
        return true
    }

    private func refreshFromPanel() -> Bool {
        guard let service = Self.panelService() else { return false }
        defer { IOObjectRelease(service) }

        guard let (raw, cap) = Self.panelBrightness(service) else { return false }

        route = .panel
        level = Self.fraction(level: raw, cap: cap)
        displayName = Self.builtInDisplayName()

        // Probed once and remembered. Writing the current value back is
        // harmless in itself, but doing it on every refresh would write to the
        // display on every notification, and every write raises another
        // notification.
        if panelAcceptsWrites == nil {
            let writeStatus = IORegistryEntrySetCFProperty(service, PanelKey.brightness as CFString, raw as CFNumber)
            panelAcceptsWrites = writeStatus == KERN_SUCCESS
        }
        capability = panelAcceptsWrites == true ? .readWrite : .readOnly
        return true
    }

    private func pollForExternalChange() {
        guard !isSettingLocally else { return }
        let previous = level
        refresh()
        if abs(previous - level) > 0.01 {
            onExternalChange?(level, displayName.isEmpty ? "Display" : displayName)
        }
    }

    // MARK: - Scale

    /// Backlight level as a fraction of the panel's SDR maximum.
    ///
    /// Clamped because the two are not strictly ordered: HDR content pushes the
    /// level above the SDR cap, which would otherwise send the slider past its
    /// own track.
    nonisolated static func fraction(level: Int, cap: Int) -> Double {
        guard cap > 0 else { return 0 }
        return min(max(Double(level) / Double(cap), 0), 1)
    }

    /// One step of brightness, in the panel's own units.
    ///
    /// The ceiling is `max(cap, raw)`, not `cap`: clamping an HDR-boosted panel
    /// to the SDR maximum would pull it *down* on a brightness-up press. The
    /// floor keeps the screen visible.
    nonisolated static func stepped(raw: Int, cap: Int, by delta: Double) -> Int {
        guard cap > 0 else { return raw }
        let ceiling = Double(max(cap, raw))
        let floor = Double(cap) * minimumFraction
        let target = Double(raw) + delta * Double(cap)
        return Int(min(max(target, floor), ceiling).rounded())
    }

    nonisolated static func rawLevel(fraction: Double, cap: Int) -> Int {
        Int((min(max(fraction, 0), 1) * Double(cap)).rounded())
    }

    // MARK: - IOKit

    /// Caller owns the returned service and must `IOObjectRelease` it.
    private static func ioDisplayService() -> io_service_t? {
        matching("IODisplayConnect") { service in
            var probe: Float = 0
            return IODisplayGetFloatParameter(
                service, 0, kIODisplayBrightnessKey as CFString, &probe
            ) == kIOReturnSuccess
        }
    }

    /// The backlight entry, told apart from the other `AppleCLCD2` services by
    /// being the only one that publishes a nits cap.
    ///
    /// Caller owns the returned service and must `IOObjectRelease` it.
    private static func panelService() -> io_service_t? {
        matching(PanelKey.service) { service in
            panelBrightness(service) != nil
        }
    }

    /// First service of `className` satisfying `isWanted`, ownership transferred
    /// to the caller. Every other service in the iteration is released here.
    private static func matching(
        _ className: String,
        where isWanted: (io_service_t) -> Bool
    ) -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching(className),
            &iterator
        ) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            if isWanted(service) { return service }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return nil
    }

    /// The backlight's current setting and its scale.
    private static func panelBrightness(_ service: io_service_t) -> (value: Int, maximum: Int)? {
        guard let parameters = IORegistryEntryCreateCFProperty(
            service, PanelKey.parameters as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? [String: Any],
            let brightness = parameters[PanelKey.brightness] as? [String: Any],
            let value = brightness[PanelKey.value] as? Int,
            let maximum = brightness[PanelKey.maximum] as? Int,
            maximum > 0 else { return nil }
        return (value, maximum)
    }

    private static func registryInt(_ service: io_service_t, _ key: String) -> Int? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Int
    }

    /// The built-in panel, if it is online — it is not with the lid closed.
    private static func builtInDisplayID() -> CGDirectDisplayID? {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count) == .success else { return nil }
        return displays.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    private static func builtInDisplayName() -> String {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }?.localizedName
            ?? NSScreen.main?.localizedName
            ?? "Built-in Display"
    }

    private static func ioDisplayName(for service: io_service_t) -> String? {
        guard let info = IODisplayCreateInfoDictionary(
            service, IOOptionBits(kIODisplayOnlyPreferredName)
        )?.takeRetainedValue() as? [String: Any] else { return nil }

        guard let names = info[kDisplayProductName] as? [String: String] else { return nil }
        if let preferred = names[Locale.current.identifier] { return preferred }
        return names.values.first
    }

    // MARK: - DisplayServices

    /// Apple's private DisplayServices framework, loaded at runtime and never
    /// linked — the one private framework Aperture calls, and only because the
    /// user chose it over the alternative.
    ///
    /// Measured on a MacBook Pro with auto-brightness on: `corebrightnessd` owns
    /// the built-in panel and re-commits its own level on every ambient-light
    /// update, about once a second. A write to the backlight's registry entry
    /// changes the value read back, but not the light the screen gives off —
    /// `corebrightnessd`'s logged level never moved. The only public route is to
    /// let macOS handle the brightness keys, and macOS then always draws its own
    /// panel. A DisplayServices write is adopted by `corebrightnessd` itself: its
    /// logged level followed at once and held through its sensor updates.
    ///
    /// Resolved with `dlopen`, so a macOS that drops these symbols falls through
    /// to the registry route rather than failing to launch.
    private struct DisplayServices: @unchecked Sendable {
        // `@unchecked` because C function pointers carry no state: once
        // resolved they are immutable and safe to call from anywhere.
        typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
        typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32
        typealias CanChange = @convention(c) (CGDirectDisplayID) -> Bool

        let get: Get
        let set: Set
        let canChange: CanChange

        static let shared: DisplayServices? = {
            let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
            guard let handle = dlopen(path, RTLD_LAZY),
                  let get = dlsym(handle, "DisplayServicesGetBrightness"),
                  let set = dlsym(handle, "DisplayServicesSetBrightness"),
                  let canChange = dlsym(handle, "DisplayServicesCanChangeBrightness") else { return nil }
            return DisplayServices(
                get: unsafeBitCast(get, to: Get.self),
                set: unsafeBitCast(set, to: Set.self),
                canChange: unsafeBitCast(canChange, to: CanChange.self)
            )
        }()

        /// 0…1, or nil if the display does not answer.
        func brightness(of display: CGDirectDisplayID) -> Double? {
            var value: Float = 0
            guard get(display, &value) == 0 else { return nil }
            return Double(value)
        }
    }
}
