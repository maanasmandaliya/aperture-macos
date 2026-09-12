//
//  AppEnvironment.swift
//  Aperture
//
//  The composition root. Everything the UI needs hangs off one observable
//  object so views never reach for singletons.
//

import AppKit
import Observation
import OSLog
import SwiftUI

@MainActor
@Observable
final class AppEnvironment {

    // MARK: Services

    let preferences: Preferences
    let media: MediaHub
    let calendar: CalendarService
    let timers: TimerService
    let notifications: NotificationFeed
    let audio: AudioOutputController
    let brightness: BrightnessController
    let focus: FocusStatusService
    let hud: HUDCenter
    let overlay: OverlayManager
    let mediaKeys = MediaKeyTap()

    // MARK: Derived state

    /// The single activity the overlay is presenting, recomputed whenever an
    /// input changes or the clock advances far enough to matter.
    private(set) var currentActivity: Activity?
    /// Advanced by the coordinator's tick so countdown labels re-render.
    private(set) var now: Date = .now

    private let log = Logger(subsystem: ApertureInfo.bundleIdentifier, category: "Environment")
    private var coordinatorTimer: Timer?
    private var observationTask: Task<Void, Never>?
    private var lastAppliedMediaSource: MediaSourceChoice
    /// Change-gate for the media-key tap. Without it every observed
    /// preference change re-applied the setting, and each re-apply asked
    /// macOS for Accessibility — so toggling *anything* raised the panel.
    @ObservationIgnored private var lastMediaKeyPress: (key: MediaKey, time: TimeInterval)?
    private var lastAppliedInterceptMediaKeys: Bool
    private var lastAppliedCalendarEnabled = false
    /// Calendar inputs as last applied. Preference observation is broad — an
    /// accent change wakes it too — so the calendar is only touched when one of
    /// *its* settings actually moved.
    private var lastAppliedCalendarSelection: Set<String> = []
    private var lastAppliedLookAhead: TimeInterval = -1
    private var isRunning = false
    /// Identity of the activity last announced, so a peek fires when the thing
    /// itself changes rather than on every recomputation.
    private var lastAnnouncedActivityKey: String?

    init(preferences: Preferences = Preferences()) {
        self.preferences = preferences
        media = MediaHub(source: preferences.mediaSource)
        calendar = CalendarService()
        timers = TimerService()
        notifications = NotificationFeed()
        audio = AudioOutputController()
        brightness = BrightnessController()
        focus = FocusStatusService()
        hud = HUDCenter()
        overlay = OverlayManager()
        lastAppliedMediaSource = preferences.mediaSource
        lastAppliedInterceptMediaKeys = preferences.interceptMediaKeys
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true

        overlay.contentProvider = { [weak self] geometry in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(
                OverlayRootView(geometry: geometry)
                    .environment(self)
            )
        }

        wireHUDSources()

        // A sideways swipe across the open hub changes track, but only when the
        // current source can actually skip and something is loaded — otherwise
        // the gesture silently does nothing, which is better than pretending.
        overlay.onSkipTrack = { [weak self] direction in
            guard let self,
                  self.media.capabilities.contains(.skip),
                  self.media.snapshot.hasTrack else { return }
            switch direction {
            case .next: self.media.next()
            case .previous: self.media.previous()
            }
        }

        // Refresh the system readings the hub displays the moment it opens, no
        // matter how it was opened (shortcut, menu, or a click on the pill).
        overlay.onPresentationChange = { [weak self] presentation in
            guard presentation.isExpanded else { return }
            self?.audio.refresh()
            self?.brightness.refresh()
            self?.focus.refresh()
        }

        overlay.start(
            scale: preferences.resolvedScale,
            showInFullscreen: preferences.showInFullscreen,
            hoverExpansion: preferences.hoverExpansion,
            haptics: preferences.hapticFeedback,
            hideInFullscreen: preferences.hideInFullscreen
        )
        overlay.updateAppearance(
            scale: preferences.resolvedScale,
            showInFullscreen: preferences.showInFullscreen,
            hoverExpansion: preferences.hoverExpansion,
            haptics: preferences.hapticFeedback,
            hideInFullscreen: preferences.hideInFullscreen,
            autoCollapse: preferences.autoCollapseHub
        )
        overlay.setPaused(preferences.isPaused)

        // Polling a media source while nothing is on screen produces a readout
        // nobody can see; the hub refreshes on open, so nothing is lost.
        media.overlayIsVisible = { [weak self] in self?.overlay.isShowingAnything ?? true }
        media.start()
        brightness.start()
        applyMediaKeyPreference()
        refreshSystemAccessibilityFlags()
        installWorkspaceObservers()

        // Launch never prompts. If a previous grant is gone — which happens on
        // every rebuild of an ad-hoc-signed app, since macOS keys permissions to
        // the binary's hash — the Schedule pane explains it and offers a button,
        // rather than a dialog appearing before the user has asked for anything.
        Task { await applyCalendarPreferences(allowPrompt: false) }
        startCoordinatorTick()
        observePreferences()
    }

    func shutDown() {
        isRunning = false
        coordinatorTimer?.invalidate()
        coordinatorTimer = nil
        observationTask?.cancel()
        observationTask = nil
        media.stop()
        notifications.stopDemoGenerator()
        notifications.detachAll()
        timers.invalidate()
        hud.invalidate()
        brightness.invalidate()
        mediaKeys.stop()
        audio.invalidate()
        focus.invalidate()
        calendar.invalidate()
        overlay.invalidate()
    }

    // MARK: - HUD wiring

    private func wireHUDSources() {
        hud.onPresentationChange = { [weak self] style in
            self?.overlay.setHUD(style)
        }

        audio.onExternalChange = { [weak self] level, muted in
            self?.hud.present(.volume(level: level, isMuted: muted))
        }

        brightness.onExternalChange = { [weak self] level, displayName in
            self?.hud.present(.brightness(level: level, displayName: displayName))
        }

        timers.onCompletion = { [weak self] timer in
            self?.hud.present(.timerCompleted(title: timer.title))
            self?.recomputeActivity()
        }

        notifications.onPublish = { [weak self] activity in
            self?.hud.present(.notification(activity))
        }

        mediaKeys.onPress = { [weak self] press in
            self?.handleMediaKey(press)
        }
    }

    // MARK: - Media keys

    /// macOS's own step is a sixteenth; Shift+Option quarters it. Matching both
    /// matters because Aperture is now the only thing moving the level — the
    /// system never sees the key.
    nonisolated static func step(fine: Bool) -> Double { fine ? 1.0 / 64 : 1.0 / 16 }

    /// A press this soon after the last press of the same key is the key being
    /// held: auto-repeat arrives about every 85 ms, while even quick deliberate
    /// taps land further apart than this.
    nonisolated static let autoRepeatWindow: TimeInterval = 0.15

    /// Held keys are told apart by pace, not by the event's repeat bit. This
    /// keyboard sets that bit on fresh presses too — a single tap of
    /// brightness-down arrives as `0x30a01` — so trusting it gave every press
    /// the fine step, about 1.5%, which on screen looks like nothing at all.
    nonisolated static func isAutoRepeat(
        _ key: MediaKey,
        at time: TimeInterval,
        after previous: (key: MediaKey, time: TimeInterval)?
    ) -> Bool {
        guard let previous, previous.key == key else { return false }
        return time - previous.time < autoRepeatWindow
    }

    /// Whether applying the media-key preference may raise the Accessibility
    /// panel.
    ///
    /// Only on the transition that turns interception *on*. This used to be an
    /// unconditional `true`, evaluated on every observed preference change,
    /// which meant flipping any unrelated switch asked macOS for Accessibility
    /// all over again.
    nonisolated static func shouldRequestMediaKeyAccess(current: Bool, lastApplied: Bool) -> Bool {
        current && current != lastApplied
    }

    private func handleMediaKey(_ press: MediaKeyPress) {
        // Auto-repeat takes the fine step, not the full one. A held key delivers
        // an event roughly every 85 ms, so a full sixteenth per repeat crosses
        // the whole range in about a second — which reads as a control that
        // cannot be aimed rather than one that is fast. A quarter step per
        // repeat glides across in a few seconds instead, and a single press
        // still moves exactly one notch.
        let now = ProcessInfo.processInfo.systemUptime
        let isHeld = Self.isAutoRepeat(press.key, at: now, after: lastMediaKeyPress)
        lastMediaKeyPress = (press.key, now)
        let step = Self.step(fine: press.isFineAdjustment || isHeld)

        switch press.key {
        case .volumeUp, .volumeDown:
            guard audio.capability.canWrite else { return }
            // Nudging the volume unmutes, the way the system's own keys do.
            if audio.isMuted { audio.setMuted(false) }
            let target = audio.level + (press.key == .volumeUp ? step : -step)
            audio.setLevel(min(max(target, 0), 1))
            hud.present(.volume(level: audio.level, isMuted: audio.isMuted))

        case .mute:
            // Auto-repeat would flap a toggle on and off while held.
            guard !isHeld, audio.capability.canWrite else { return }
            audio.setMuted(!audio.isMuted)
            hud.present(.volume(level: audio.level, isMuted: audio.isMuted))

        case .brightnessUp, .brightnessDown:
            guard brightness.capability.canWrite else { return }
            // Delegated rather than computed here: the arithmetic has to happen
            // in the panel's own units, against a freshly read level.
            brightness.step(by: press.key == .brightnessUp ? step : -step)
            let name = brightness.displayName.isEmpty ? "Display" : brightness.displayName
            hud.present(.brightness(level: brightness.level, displayName: name))
        }
    }

    /// Asks macOS for both permissions the key tap needs, then re-applies.
    ///
    /// Driven by an explicit button, because launch must never prompt: this is
    /// the moment the user has actually asked.
    func requestMediaKeyPermissions() {
        applyMediaKeyPreference(prompting: true)
    }

    /// Starts or stops the key tap to match the preference.
    ///
    /// - Parameter prompting: whether a missing permission may raise the system
    ///   dialog. Only true when the user has just asked for this, never at
    ///   launch — the same rule the calendar follows.
    func applyMediaKeyPreference(prompting: Bool = false) {
        guard preferences.interceptMediaKeys else {
            mediaKeys.stop()
            return
        }
        // Attempt the tap rather than gating on `AXIsProcessTrusted`. That check
        // is a proxy for what we actually need, and a proxy can disagree with
        // reality — it did here, reporting "not permitted" for an app the user
        // had granted. `CGEvent.tapCreate` never prompts; it simply returns nil
        // when it is refused, so trying costs nothing and its answer is the
        // ground truth.
        let started = mediaKeys.start()
        if started {
            log.notice("media keys: tap installed")
            return
        }

        // Refused. Two permissions gate this and macOS says which is missing
        // only by refusing, so both are asked for — and asking for Input
        // Monitoring is also what puts Aperture in that list in the first place.
        if prompting {
            MediaKeyTap.requestInputMonitoring()
            _ = MediaKeyTap.isPermitted(prompting: true)
        }
        let ax = MediaKeyTap.isPermitted() ? "granted" : "missing"
        let hid = MediaKeyTap.canListenToInput() ? "granted" : "missing"
        log.notice("media keys: tap refused (accessibility=\(ax, privacy: .public), inputMonitoring=\(hid, privacy: .public))")
        mediaKeys.stop()
    }

    // MARK: - Coordination

    /// One adaptive timer replaces per-view clocks. It runs at 1 Hz only while
    /// something is actually counting; otherwise it idles at 5 s, which is
    /// enough to notice an event entering the imminent window.
    private func startCoordinatorTick() {
        scheduleTick(interval: 1)
    }

    private func scheduleTick(interval: TimeInterval) {
        coordinatorTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        coordinatorTimer = timer
    }

    private func tick() {
        now = .now
        recomputeActivity()

        let wantsFastTick = timers.active != nil
            || media.snapshot.isPlaying
            || currentActivity?.kind == .calendar
            || currentActivity?.kind == .call

        let desired: TimeInterval = wantsFastTick ? 1 : 5
        if let current = coordinatorTimer?.timeInterval, abs(current - desired) > 0.01 {
            scheduleTick(interval: desired)
        }
    }

    func recomputeActivity() {
        let inputs = ActivityInputs(
            call: nil, // No public macOS API reports call state; see README.
            timer: timers.active,
            media: media.snapshot,
            calendarEvents: calendar.upcomingEvents,
            now: now
        )
        let resolved = ActivitySelector.select(inputs, policy: preferences.activityPolicy)
        if resolved != currentActivity {
            currentActivity = resolved
        }
        overlay.setHasActivity(resolved != nil)
        announceIfChanged(resolved)
    }

    /// Fires a peek when the *thing being shown* changes — a new track, a timer
    /// starting, an event coming into range. Comparing identity rather than the
    /// whole value keeps a ticking playhead or countdown from re-announcing
    /// itself every second.
    private func announceIfChanged(_ activity: Activity?) {
        let key = Self.identityKey(for: activity)
        guard key != lastAnnouncedActivityKey else { return }
        lastAnnouncedActivityKey = key
        guard key != nil else { return }
        overlay.peek()
    }

    private static func identityKey(for activity: Activity?) -> String? {
        switch activity {
        case .media(let media): "media:\(media.title)|\(media.artist)"
        case .timer(let timer): "timer:\(timer.id.uuidString)"
        case .calendar(let event): "calendar:\(event.id)"
        case .call(let call): "call:\(call.id.uuidString)"
        case nil: nil
        }
    }

    // MARK: - Preference propagation

    /// Observation-based change tracking: `withObservationTracking` fires once
    /// per change, so this re-arms itself instead of polling preferences.
    private func observePreferences() {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = self.preferences.isPaused
                        _ = self.preferences.overlayScale
                        _ = self.preferences.showInFullscreen
                        _ = self.preferences.hoverExpansion
                        _ = self.preferences.hapticFeedback
                        _ = self.preferences.hideInFullscreen
                        _ = self.preferences.interceptMediaKeys
                        _ = self.preferences.autoCollapseHub
                        _ = self.preferences.accent
                        _ = self.preferences.appearanceMode
                        _ = self.preferences.mediaSource
                        _ = self.preferences.calendarEnabled
                        _ = self.preferences.selectedCalendarIDs
                        _ = self.preferences.lookAheadMinutes
                        _ = self.preferences.showMedia
                        _ = self.preferences.showCalendar
                        _ = self.preferences.showTimers
                    } onChange: {
                        continuation.resume()
                    }
                }
                // `onChange` fires from inside the setter, so yield once to let
                // the new value land before reading it back.
                await Task.yield()
                guard !Task.isCancelled else { return }
                self.applyPreferences()
            }
        }
    }

    private func applyPreferences() {
        overlay.setPaused(preferences.isPaused)
        overlay.updateAppearance(
            scale: preferences.resolvedScale,
            showInFullscreen: preferences.showInFullscreen,
            hoverExpansion: preferences.hoverExpansion,
            haptics: preferences.hapticFeedback,
            hideInFullscreen: preferences.hideInFullscreen,
            autoCollapse: preferences.autoCollapseHub
        )

        // Only when this particular setting moved, and only prompting on the
        // way *on*: that is the one moment the user has actually asked for the
        // permission. Turning it off, or changing any other preference, must
        // never raise the panel.
        if preferences.interceptMediaKeys != lastAppliedInterceptMediaKeys {
            let prompting = Self.shouldRequestMediaKeyAccess(
                current: preferences.interceptMediaKeys,
                lastApplied: lastAppliedInterceptMediaKeys
            )
            lastAppliedInterceptMediaKeys = preferences.interceptMediaKeys
            applyMediaKeyPreference(prompting: prompting)
        }

        if preferences.mediaSource != lastAppliedMediaSource {
            lastAppliedMediaSource = preferences.mediaSource
            media.setSource(preferences.mediaSource)
        }

        // Reached from an observed preference change, so turning the setting on
        // here *is* a deliberate user action and may prompt.
        Task { await applyCalendarPreferences(allowPrompt: true) }
        recomputeActivity()
        overlay.refreshContent()
    }

    private func applyCalendarPreferences(allowPrompt: Bool) async {
        let enabled = preferences.calendarEnabled
        let selection = preferences.selectedCalendarIDs
        let lookAhead = preferences.lookAheadInterval

        let unchanged = enabled == lastAppliedCalendarEnabled
            && selection == lastAppliedCalendarSelection
            && lookAhead == lastAppliedLookAhead
        guard !unchanged else { return }

        lastAppliedCalendarEnabled = enabled
        lastAppliedCalendarSelection = selection
        lastAppliedLookAhead = lookAhead

        if enabled {
            await calendar.enable(
                selectedIdentifiers: selection,
                lookAhead: lookAhead,
                promptIfNeeded: allowPrompt
            )
        } else {
            calendar.disable()
        }
        recomputeActivity()
    }

    // MARK: - Workspace

    private func installWorkspaceObservers() {
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSystemAccessibilityFlags() }
        }
    }

    private func refreshSystemAccessibilityFlags() {
        let workspace = NSWorkspace.shared
        preferences.updateSystemAccessibilityFlags(
            reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast
        )
    }

    // MARK: - Actions surfaced by menus and shortcuts

    func toggleHub() {
        guard !preferences.isPaused else { return }
        audio.refresh()
        brightness.refresh()
        focus.refresh()
        overlay.toggleExpanded()
    }

    func setPaused(_ paused: Bool) {
        preferences.isPaused = paused
        if paused { hud.dismiss() }
    }

    var accent: AccentChoice { preferences.accent }
}

// MARK: - Preview support

extension AppEnvironment {
    /// Detached instance with in-memory preferences and seeded services, for
    /// SwiftUI previews. Seeding the services (not just `currentActivity`) is
    /// what lets the hub panes render real content in the canvas.
    static func preview(
        activity: Activity? = nil,
        seedSchedule: Bool = true,
        configure: (Preferences) -> Void = { _ in }
    ) -> AppEnvironment {
        let environment = AppEnvironment(preferences: .preview(configure: configure))
        environment.now = PreviewData.referenceDate

        if seedSchedule {
            environment.calendar.previewSeed(
                access: .authorized,
                calendars: PreviewData.previewCalendars,
                events: PreviewData.upcomingEvents
            )
        }

        switch activity {
        case .media(let snapshot):
            environment.media.previewSeed(snapshot)
        case .timer(let timer):
            environment.timers.previewSeed(timer)
        case .calendar, .call, nil:
            break
        }

        environment.currentActivity = activity
        environment.overlay.setHasActivity(activity != nil)
        return environment
    }

    /// Preview-only seam for driving the overlay into a specific activity.
    /// The setter itself stays private so production code can only get here
    /// through ``recomputeActivity()``.
    func previewOverride(activity: Activity?) {
        currentActivity = activity
        overlay.setHasActivity(activity != nil)
    }
}
