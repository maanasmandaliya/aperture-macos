//
//  OverlayManager.swift
//  Aperture
//
//  Owns one panel per eligible display, keeps them positioned across display
//  changes, and is the single place the overlay's state machine is driven from.
//

import AppKit
import Observation
import OSLog
import SwiftUI

@MainActor
@Observable
final class OverlayManager {

    // MARK: Observable state

    private(set) var machine = OverlayStateMachine()
    private(set) var geometries: [ScreenGeometry] = []
    /// Display currently under the cursor, or the primary display. Only this
    /// one renders anything beyond the idle pill.
    private(set) var focusedDisplayID: CGDirectDisplayID?
    private(set) var isHoveringPill = false
    /// Displays whose active space belongs to a full-screen app. Only consulted
    /// when the user has asked Aperture to stay out of the way there.
    private(set) var fullScreenDisplays: Set<CGDirectDisplayID> = []

    var presentation: OverlayPresentation { machine.presentation }

    /// What a given display should show.
    ///
    /// The hub and HUDs belong to one display at a time — duplicating them on
    /// every monitor would be noise — so unfocused displays fall back to their
    /// resting state while the focused one gets the full presentation.
    func presentation(for displayID: CGDirectDisplayID) -> OverlayPresentation {
        Self.suppressing(unsuppressedPresentation(for: displayID), isSuppressed: isSuppressed(displayID))
    }

    /// Applies the full-screen rule to a presentation.
    ///
    /// The line is *who asked*, not what the surface is. Anything Aperture puts
    /// on screen of its own accord — the resting pill, a track announcement, a
    /// finished timer, a notification — is withheld. Anything that exists
    /// because the user just did something survives: the hub they swiped open,
    /// and the volume or brightness readout they summoned by pressing a key.
    ///
    /// Suppressing that readout was the wrong call: pressing a volume key in a
    /// full-screen film is a direct request for feedback, and hiding Aperture's
    /// answer leaves nothing at all when the system panel is being suppressed
    /// too.
    nonisolated static func suppressing(
        _ base: OverlayPresentation,
        isSuppressed: Bool
    ) -> OverlayPresentation {
        guard isSuppressed else { return base }
        switch base {
        case .expanded, .hud(.meter): return base
        case .hidden, .minimal, .compact, .hud(.message): return .hidden
        }
    }

    /// True when the pill should stay out of a full-screen app on this display.
    func isSuppressed(_ displayID: CGDirectDisplayID) -> Bool {
        hideInFullscreenEnabled && fullScreenDisplays.contains(displayID)
    }

    private func unsuppressedPresentation(for displayID: CGDirectDisplayID) -> OverlayPresentation {
        guard displayID != focusedDisplayID else { return machine.presentation }
        switch machine.presentation {
        case .hidden: return .hidden
        case .minimal: return .minimal
        // Peeks, HUDs and the hub belong to the display the user is looking at.
        case .compact, .hud, .expanded: return .minimal
        }
    }

    // MARK: Collaborators

    /// Supplies the SwiftUI content for a screen. Set once by ``AppEnvironment``.
    var contentProvider: ((ScreenGeometry) -> AnyView)?
    /// Raised when the presentation changes, so the app can react (e.g. refresh
    /// system readings before the hub appears).
    var onPresentationChange: ((OverlayPresentation) -> Void)?

    enum SkipDirection: Equatable, Sendable {
        case next
        case previous
    }

    /// Raised by a horizontal swipe across the open hub. The manager knows
    /// nothing about playback, so whether a skip is even possible is decided by
    /// whoever wires this up.
    var onSkipTrack: ((SkipDirection) -> Void)?

    private let log = Logger(subsystem: ApertureInfo.bundleIdentifier, category: "Overlay")
    private let tracker = OverlayMouseTracker()
    @ObservationIgnored private let haptics: HapticPerforming

    init(haptics: HapticPerforming = HapticFeedback()) {
        self.haptics = haptics
    }

    private var panels: [CGDirectDisplayID: OverlayPanel] = [:]
    private var hosts: [CGDirectDisplayID: OverlayHostingView] = [:]
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var fullScreenTask: Task<Void, Never>?

    private var overlayScale: CGFloat = 1
    private var showInFullscreen = false
    private var hoverExpansionEnabled = true
    private var hapticsEnabled = true
    private var hideInFullscreenEnabled = false
    private var autoCollapseEnabled = true
    private var isStarted = false

    /// Recognises one swipe per gesture. The threshold can sit this low only
    /// because the recogniser latches: without that, a flick would page through
    /// every pane at once.
    private var swipe = SwipeRecognizer(threshold: 18)
    private var hoverHaptic = HapticThrottle()
    private var peekTask: Task<Void, Never>?
    private var idleCollapseTask: Task<Void, Never>?

    // MARK: - Lifecycle

    func start(
        scale: CGFloat,
        showInFullscreen: Bool,
        hoverExpansion: Bool,
        haptics: Bool = true,
        hideInFullscreen: Bool = false
    ) {
        guard !isStarted else { return }
        isStarted = true
        overlayScale = scale
        self.showInFullscreen = showInFullscreen
        hoverExpansionEnabled = hoverExpansion
        hapticsEnabled = haptics
        hideInFullscreenEnabled = hideInFullscreen

        rebuildPanels()
        installObservers()
        refreshFullScreenState()

        tracker.onMove = { [weak self] location in
            self?.handleCursor(location)
        }
        tracker.onScroll = { [weak self] sample in
            self?.handleScroll(sample)
        }
        tracker.start()
    }

    func invalidate() {
        peekTask?.cancel(); peekTask = nil
        idleCollapseTask?.cancel(); idleCollapseTask = nil
        fullScreenTask?.cancel(); fullScreenTask = nil
        haptics.invalidate()
        tracker.stop()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        screenObserver = nil
        spaceObserver = nil
        activationObserver = nil
        for panel in panels.values { panel.orderOut(nil) }
        panels.removeAll()
        hosts.removeAll()
        isStarted = false
    }

    // MARK: - Configuration

    func updateAppearance(
        scale: CGFloat,
        showInFullscreen: Bool,
        hoverExpansion: Bool,
        haptics: Bool = true,
        hideInFullscreen: Bool = false,
        autoCollapse: Bool = true
    ) {
        let scaleChanged = abs(overlayScale - scale) > 0.001
        overlayScale = scale
        hoverExpansionEnabled = hoverExpansion
        hapticsEnabled = haptics
        autoCollapseEnabled = autoCollapse

        if hideInFullscreenEnabled != hideInFullscreen {
            hideInFullscreenEnabled = hideInFullscreen
            refreshFullScreenState()
        }

        if self.showInFullscreen != showInFullscreen {
            self.showInFullscreen = showInFullscreen
            for panel in panels.values { panel.setSpaceBehavior(showInFullscreen: showInFullscreen) }
        }
        if scaleChanged { repositionPanels() }
    }

    // MARK: - State transitions

    @discardableResult
    func send(_ event: OverlayEvent) -> Bool {
        let changed = machine.apply(event)
        if changed {
            applyPresentation()
            restartIdleCollapseTimer()
        }
        return changed
    }

    func toggleExpanded() { send(.toggleExpanded) }
    func expand(tab: HubTab) { send(.expand(tab)) }
    func collapse() { send(.collapse) }
    func selectTab(_ tab: HubTab) { send(.selectTab(tab)) }
    func setPaused(_ paused: Bool) { send(.pauseChanged(paused)) }
    func setHasActivity(_ hasActivity: Bool) { send(.activityChanged(hasActivity)) }
    func setHUD(_ style: HUDStyle?) { send(style.map(OverlayEvent.hudBegan) ?? .hudEnded) }

    // MARK: - Peeks

    /// Shows the wide strip briefly, then returns to the minimal slab.
    ///
    /// Called when an activity starts or changes — a new track, a timer
    /// starting, an event coming into range. The overlay announces the change
    /// and then gets out of the way on its own.
    func peek(for duration: Duration = .seconds(3.4)) {
        guard send(.peekBegan) else { return }
        peekTask?.cancel()
        peekTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.send(.peekEnded)
        }
    }

    func endPeek() {
        peekTask?.cancel()
        peekTask = nil
        send(.peekEnded)
    }

    // MARK: - Idle collapse

    /// Closes the hub once the user has stopped interacting with it.
    ///
    /// Restarted on every hover and gesture, so it only fires when the cursor
    /// has genuinely left the overlay alone.
    private func restartIdleCollapseTimer() {
        idleCollapseTask?.cancel()
        idleCollapseTask = nil
        guard autoCollapseEnabled, Self.autoCollapses(machine.presentation) else { return }

        idleCollapseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self else { return }
            guard self.autoCollapseEnabled, Self.autoCollapses(self.machine.presentation), !self.isHoveringPill else { return }
            self.collapse()
        }
    }

    /// Whether the idle timer may close this presentation.
    ///
    /// Never the mirror: someone looking into it is not moving the cursor, and
    /// closing it on them after ten seconds would make it unusable.
    nonisolated static func autoCollapses(_ presentation: OverlayPresentation) -> Bool {
        presentation.isExpanded && !MirrorGeometry.showsMirror(presentation)
    }

    // MARK: - Swipe

    /// Two-finger swipe over the overlay.
    ///
    /// The panes are a vertical stack: swiping down opens the hub and then goes
    /// deeper through it, swiping up comes back and finally closes. One gesture
    /// covers open, page and close, which is why there is no tab bar.
    ///
    /// The horizontal axis is free, so it drives the track: swiping left flicks
    /// the current one away for the next, swiping right goes back. That only
    /// applies while the hub is open — a stray sideways scroll near the top of
    /// the screen should never change what is playing.
    ///
    /// Travel is accumulated across the gesture rather than acted on per event,
    /// so a flick and a slow drag both need the same distance, and a stray
    /// scroll that happens to pass under the pill does nothing.
    private func handleScroll(_ sample: ScrollSample) {
        guard isStarted, !machine.isPaused else { return }
        // Only while the pointer is actually on the overlay.
        guard isHoveringPill else {
            swipe.reset()
            return
        }

        switch swipe.consume(sample) {
        case .none:
            return
        case .swipedDown:
            restartIdleCollapseTimer()
            if let tab = machine.presentation.tab {
                // Already open: go deeper, or stay put at the last pane.
                if let deeper = tab.deeper { selectTab(deeper) }
            } else {
                expand(tab: machine.lastTab)
            }
        case .swipedUp:
            guard let tab = machine.presentation.tab else { return }
            restartIdleCollapseTimer()
            // Back up a pane, and close once there is nowhere shallower to go.
            if let shallower = tab.shallower { selectTab(shallower) } else { collapse() }

        case .swipedLeft:
            guard machine.presentation.isExpanded else { return }
            restartIdleCollapseTimer()
            onSkipTrack?(.next)

        case .swipedRight:
            guard machine.presentation.isExpanded else { return }
            restartIdleCollapseTimer()
            onSkipTrack?(.previous)
        }
    }

    // MARK: - Panels

    /// Recreates panels to match the current display set. Called on launch and
    /// on every `didChangeScreenParameters`, which covers resolution changes,
    /// display connect/disconnect, and arrangement edits.
    private func rebuildPanels() {
        let screens = NSScreen.screens
        let newGeometries = screens.map(ScreenGeometry.init(screen:))
        geometries = newGeometries

        let liveIDs = Set(newGeometries.map(\.id))
        for (id, panel) in panels where !liveIDs.contains(id) {
            panel.orderOut(nil)
            panels.removeValue(forKey: id)
            hosts.removeValue(forKey: id)
        }

        for geometry in newGeometries {
            let panel = panels[geometry.id] ?? makePanel(for: geometry)
            panels[geometry.id] = panel
            install(content: geometry, into: panel)
            panel.setFrame(windowFrame(for: geometry), display: true)
            panel.setSpaceBehavior(showInFullscreen: showInFullscreen)
        }

        if focusedDisplayID == nil || !liveIDs.contains(focusedDisplayID!) {
            focusedDisplayID = newGeometries.first(where: { $0.frame.origin == .zero })?.id ?? newGeometries.first?.id
        }

        send(.screenAvailabilityChanged(!newGeometries.isEmpty))
        applyPresentation()
    }

    private func makePanel(for geometry: ScreenGeometry) -> OverlayPanel {
        let panel = OverlayPanel(contentRect: windowFrame(for: geometry))
        panel.onCancel = { [weak self] in self?.collapse() }
        return panel
    }

    private func install(content geometry: ScreenGeometry, into panel: OverlayPanel) {
        guard let contentProvider else { return }
        let view = contentProvider(geometry)
        if let existing = hosts[geometry.id] {
            existing.rootView = view
        } else {
            let host = OverlayHostingView(overlayContent: view)
            panel.contentView = host
            hosts[geometry.id] = host
        }
    }

    /// Panel size is fixed per display and generous enough for the widest state
    /// plus spring overshoot and shadow, so nothing is ever resized mid-animation
    /// (which would tear the SwiftUI transition).
    private func windowFrame(for geometry: ScreenGeometry) -> NSRect {
        let layout = geometry.layout(scale: overlayScale)
        let width = max(Tokens.Size.hub.width * overlayScale, layout.pillSize.width) + Tokens.Size.windowPadding.width
        let height = Tokens.Size.hub.height * overlayScale + Tokens.Size.windowPadding.height
        return NSRect(
            x: geometry.frame.midX - width / 2,
            y: geometry.frame.maxY - height,
            width: width,
            height: height
        )
    }

    private func repositionPanels() {
        geometries = NSScreen.screens.map(ScreenGeometry.init(screen:))
        for geometry in geometries {
            guard let panel = panels[geometry.id] else { continue }
            install(content: geometry, into: panel)
            panel.setFrame(windowFrame(for: geometry), display: true)
        }
        applyPresentation()
    }

    /// Rebuilds the SwiftUI content on every screen — used when the geometry is
    /// unchanged but the view tree needs re-seeding (e.g. accent change).
    func refreshContent() {
        for geometry in geometries {
            guard let panel = panels[geometry.id] else { continue }
            install(content: geometry, into: panel)
        }
    }

    private func installObservers() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildPanels() }
        }

        // Re-assert ordering after a Space switch; panels that join all Spaces
        // can otherwise end up behind a newly-fronted full-screen window. This
        // is also where entering or leaving a full-screen Space is noticed.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyPresentation()
                self?.refreshFullScreenState(settling: true)
            }
        }

        // An app taking over a display can reorder windows at our level, so
        // re-assert ordering on activation too.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPresentation() }
        }
    }

    // MARK: - Full-screen suppression

    /// Re-reads which displays are showing a full-screen app.
    ///
    /// Costs nothing at all while the setting is off — the window list is never
    /// consulted — and about a third of a millisecond when it is on, which is
    /// why this is driven by Space changes rather than a timer.
    ///
    /// `settling` re-checks after the Space transition finishes. Mid-animation
    /// the window list genuinely describes neither Space: windows appear at
    /// sliding offsets and the desktop flickers in and out, so a single reading
    /// taken the instant the notification arrives can be wrong either way.
    func refreshFullScreenState(settling: Bool = false) {
        fullScreenTask?.cancel()
        fullScreenTask = nil

        guard hideInFullscreenEnabled else {
            applyFullScreenDisplays([])
            return
        }

        applyFullScreenDisplays(currentFullScreenDisplays())
        guard settling else { return }

        fullScreenTask = Task { [weak self] in
            for delay in [Duration.milliseconds(450), .milliseconds(750)] {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self, self.hideInFullscreenEnabled else { return }
                self.applyFullScreenDisplays(self.currentFullScreenDisplays())
            }
        }
    }

    private func currentFullScreenDisplays() -> Set<CGDirectDisplayID> {
        let windows = FullScreenDetector.snapshot()
        return Set(
            geometries
                .filter {
                    FullScreenDetector.isFullScreen(
                        // Core Graphics reports window bounds in its own
                        // top-left-origin space, so the display is asked for in
                        // the same terms rather than converted from AppKit's.
                        display: CGDisplayBounds($0.id),
                        windows: windows,
                        menuBarHeight: $0.menuBarHeight
                    )
                }
                .map(\.id)
        )
    }

    private func applyFullScreenDisplays(_ displays: Set<CGDirectDisplayID>) {
        guard displays != fullScreenDisplays else { return }
        log.notice("full-screen displays: \(displays.map(String.init).sorted().joined(separator: ","), privacy: .public)")
        fullScreenDisplays = displays
        applyPresentation()
    }

    // MARK: - Presentation

    private func applyPresentation() {
        // Named to leave `presentation(for:)` callable: the shadowing local is
        // what hid the per-display lookup from this loop in the first place.
        let global = machine.presentation

        for (id, panel) in panels {
            let isFocused = (id == focusedDisplayID)

            // Per display, not the global state: an unfocused screen rests
            // while another shows the hub, and a screen running a full-screen
            // app can be withdrawn entirely. Ordering the panel from the global
            // presentation instead is what let the pill stay on screen after
            // the suppression rule had correctly decided to hide it.
            switch presentation(for: id) {
            case .hidden:
                panel.orderOut(nil)
                panel.allowsKeyStatus = false
                continue
            case .minimal, .compact, .hud:
                panel.allowsKeyStatus = false
                panel.ignoresMouseEvents = !(isFocused && isHoveringPill)
            case .expanded:
                // Only the focused display shows the hub; the others stay in
                // their resting state so a second monitor is not covered.
                panel.allowsKeyStatus = isFocused
                panel.ignoresMouseEvents = !isFocused
            }

            panel.orderFrontRegardless()
        }

        if global.isExpanded, let focusedDisplayID, let panel = panels[focusedDisplayID] {
            // Key without activating: sliders and arrow keys work while the
            // user's frontmost app keeps focus.
            panel.makeKeyAndOrderFront(nil)
        }

        onPresentationChange?(global)
    }

    // MARK: - Cursor

    private func handleCursor(_ location: CGPoint) {
        guard isStarted else { return }

        // Follow the cursor between displays so the hub always opens where the
        // user is looking.
        if let geometry = geometries.first(where: { $0.frame.contains(location) }), geometry.id != focusedDisplayID {
            focusedDisplayID = geometry.id
            if machine.presentation.isExpanded { applyPresentation() }
        }

        let inside = pillHitRect().map { $0.contains(location) } ?? false
        guard inside != isHoveringPill else { return }
        isHoveringPill = inside
        if inside {
            swipe.reset()
            tapForHover()
        }
        restartIdleCollapseTimer()

        // Dropping the click-through shield is the whole point of tracking the
        // cursor; the hub manages its own shield while expanded.
        if !machine.presentation.isExpanded {
            applyPresentation()
        }
    }

    /// Taps the trackpad as the cursor arrives on the overlay, so its edge can
    /// be felt as well as seen.
    ///
    /// Entry only: a tap on the way out too would mean two taps for a cursor
    /// merely crossing the top of the screen, which is the common case.
    private func tapForHover() {
        guard hapticsEnabled, !machine.isPaused else { return }
        // Deliberately *not* skipped while suppressed in a full-screen app. The
        // pill is invisible there, but the target is not gone: a swipe still
        // opens the hub. With nothing drawn, the tap is the only thing that says
        // the edge is there at all, which makes it matter more, not less.
        guard hoverHaptic.shouldFire(at: ProcessInfo.processInfo.systemUptime) else { return }
        haptics.tap()
    }

    /// Global-coordinate rect of the collapsed pill on the focused display,
    /// padded slightly so the hover target is forgiving.
    private func pillHitRect() -> CGRect? {
        guard let focusedDisplayID,
              let geometry = geometries.first(where: { $0.id == focusedDisplayID }) else { return nil }

        // Asks the same metrics the slab is drawn from. Computing the size
        // separately here is what let the expanded hit region fall out of step
        // with the panes once each got its own height.
        let metrics = OverlayMetrics(layout: geometry.layout(scale: overlayScale), scale: overlayScale)
        let size = metrics.slabSize(
            for: machine.presentation,
            isHovering: isHoveringPill && hoverExpansionEnabled,
            hasActivity: machine.hasActivity
        )

        // The flare widens the slab beyond `size` at the very top edge, so the
        // hover region has to account for it or the shoulders go dead.
        let padding: CGFloat = 6
        let horizontal = padding + metrics.flare(for: machine.presentation)
        return CGRect(
            x: geometry.frame.midX - size.width / 2 - horizontal,
            y: geometry.frame.maxY - size.height - padding,
            width: size.width + horizontal * 2,
            height: size.height + padding
        )
    }

    /// Whether the overlay is drawing anything at all right now.
    ///
    /// False while paused, with no eligible screen, or suppressed in a
    /// full-screen app — the states where polling a media source produces
    /// something nobody can see.
    var isShowingAnything: Bool {
        guard let focusedDisplayID else { return machine.presentation != .hidden }
        return presentation(for: focusedDisplayID) != .hidden
    }

    /// True when the pointer is over the focused display's overlay surface.
    func isCursorOverOverlay() -> Bool { isHoveringPill }
}
