//
//  CalendarService.swift
//  Aperture
//
//  EventKit integration. Nothing here runs until the user turns Calendar on in
//  Settings — constructing the service does not touch EventKit, and the access
//  prompt is only raised from an explicit user action.
//

import AppKit
import EventKit
import Observation
import OSLog
import SwiftUI

@MainActor
@Observable
final class CalendarService {

    enum Access: Equatable, Sendable {
        case notRequested
        case authorized
        case denied
        case restricted
        /// macOS 14+ can grant write-only access, which cannot read events.
        case writeOnly

        var isReadable: Bool { self == .authorized }

        var statusText: String {
            switch self {
            case .notRequested: "Not requested"
            case .authorized: "Full access granted"
            case .denied: "Denied — enable in System Settings ▸ Privacy & Security ▸ Calendars"
            case .restricted: "Restricted by system policy"
            case .writeOnly: "Write-only — Aperture needs full access to show events"
            }
        }
    }

    struct CalendarInfo: Identifiable, Equatable, Sendable {
        var id: String
        var title: String
        var color: RGBColor
        var sourceName: String
    }

    private(set) var access: Access = .notRequested
    private(set) var availableCalendars: [CalendarInfo] = []
    private(set) var upcomingEvents: [CalendarActivity] = []
    private(set) var lastRefresh: Date?

    private let store = EKEventStore()
    private let log = Logger(subsystem: ApertureInfo.bundleIdentifier, category: "Calendar")
    private var changeObserver: NSObjectProtocol?
    private var refreshTimer: Timer?
    private var isEnabled = false

    /// The one in-flight authorisation request, if any.
    ///
    /// EventKit reports `.notDetermined` until the user actually answers, so
    /// without single-flighting this, every caller that arrives while the panel
    /// is on screen sees "not asked yet" and raises another one.
    private var accessRequest: Task<Bool, Never>?
    /// Whether this launch has already put the prompt on screen. Dismissing the
    /// panel without choosing leaves the status `.notDetermined` forever, and
    /// re-asking on every settings change is worse than waiting for the user to
    /// come back through Settings deliberately.
    private var hasRequestedThisLaunch = false

    private var selectedIdentifiers: Set<String> = []
    private var lookAhead: TimeInterval = 12 * 60 * 60

    init() {
        access = Self.currentAccess()
    }

    /// Explicit teardown, called from app termination. A `deinit` cannot do
    /// this: it is `nonisolated` on a `@MainActor` type and cannot reach the
    /// isolated timer/observer state.
    func invalidate() { disable() }

    // MARK: - Enablement

    /// Turns integration on. Requests access only if it has never been asked
    /// for, so a denied user is not re-prompted on every launch.
    /// Turns integration on, or applies a changed configuration.
    ///
    /// Idempotent: calling it repeatedly with the same inputs does nothing.
    /// Preference observation is broad — changing the accent colour reaches
    /// here too — so this has to be cheap and, above all, must not re-prompt.
    ///
    /// - Parameter promptIfNeeded: whether a missing authorisation may raise the
    ///   system panel. Only ever true when the user just asked for calendar
    ///   events; launching with the setting already on must never put a dialog
    ///   on screen unbidden.
    func enable(
        selectedIdentifiers: Set<String>,
        lookAhead: TimeInterval,
        promptIfNeeded: Bool
    ) async {
        let selectionChanged = self.selectedIdentifiers != selectedIdentifiers
        let windowChanged = self.lookAhead != lookAhead
        let wasEnabled = isEnabled

        self.selectedIdentifiers = selectedIdentifiers
        self.lookAhead = lookAhead
        isEnabled = true

        access = Self.currentAccess()
        let willAsk = Self.shouldRequestAccess(
            current: access,
            hasAskedThisLaunch: hasRequestedThisLaunch,
            promptAllowed: promptIfNeeded
        )
        // Recorded at notice level so the prompt path stays auditable from the
        // system log: this is the one place a user-visible panel can appear, and
        // "it asked me twice" is otherwise very hard to diagnose after the fact.
        log.notice("""
            Calendar enable — access=\(String(describing: self.access), privacy: .public), \
            askedThisLaunch=\(self.hasRequestedThisLaunch, privacy: .public), \
            promptAllowed=\(promptIfNeeded, privacy: .public), \
            willPrompt=\(willAsk, privacy: .public)
            """)
        if willAsk {
            await requestAccess()
        }
        guard access.isReadable else { return }

        installChangeObserver()

        if !wasEnabled {
            scheduleRefreshTimer()
            reloadCalendars()
        }
        if !wasEnabled || selectionChanged || windowChanged {
            refreshEvents()
        }
    }

    /// Whether a prompt is warranted. Pure and `nonisolated`, so the whole rule
    /// can be tested without EventKit, a real authorisation state, or the main
    /// actor. All three conditions have to hold:
    ///
    /// * the user asked for this (`promptAllowed`) — launch never does;
    /// * macOS has no answer on file yet;
    /// * this launch has not already put the panel up.
    nonisolated static func shouldRequestAccess(
        current: Access,
        hasAskedThisLaunch: Bool,
        promptAllowed: Bool
    ) -> Bool {
        promptAllowed && current == .notRequested && !hasAskedThisLaunch
    }

    func disable() {
        guard isEnabled else { return }
        isEnabled = false
        refreshTimer?.invalidate()
        refreshTimer = nil
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
            self.changeObserver = nil
        }
        upcomingEvents = []
    }

    /// Raises the system prompt at most once at a time, and at most once per
    /// launch. Concurrent callers all await the same request rather than each
    /// putting up their own panel.
    @discardableResult
    func requestAccess() async -> Bool {
        if let accessRequest {
            log.notice("Calendar prompt already in flight — joining it rather than raising another")
            return await accessRequest.value
        }

        log.notice("Calendar prompt: raising the system panel")
        hasRequestedThisLaunch = true
        let store = self.store
        let log = self.log
        let request = Task { () -> Bool in
            do {
                return try await store.requestFullAccessToEvents()
            } catch {
                // Never swallowed with `try?`. EventKit reports *why* it refused
                // — a missing usage string, a restricted profile, a TCC fault —
                // and discarding that turns every cause into the same silent
                // "nothing happened", which is exactly what it did.
                let nsError = error as NSError
                log.error("Calendar request failed — domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) reason=\(nsError.localizedDescription, privacy: .public)")
                return false
            }
        }
        accessRequest = request

        let granted = await request.value
        accessRequest = nil

        access = Self.currentAccess()
        let raw = EKEventStore.authorizationStatus(for: .event).rawValue
        log.notice("Calendar prompt answered — granted=\(granted, privacy: .public), access=\(String(describing: self.access), privacy: .public), rawStatus=\(raw, privacy: .public)")
        if granted {
            reloadCalendars()
            refreshEvents()
        }
        return granted
    }

    /// Lets the user retry from Settings after dismissing the prompt.
    func allowRetryingAccess() { hasRequestedThisLaunch = false }

    func updateSelection(_ identifiers: Set<String>) {
        selectedIdentifiers = identifiers
        refreshEvents()
    }

    func updateLookAhead(_ interval: TimeInterval) {
        lookAhead = interval
        refreshEvents()
    }

    // MARK: - Loading

    func reloadCalendars() {
        guard access.isReadable else {
            availableCalendars = []
            return
        }
        availableCalendars = store.calendars(for: .event)
            .map {
                CalendarInfo(
                    id: $0.calendarIdentifier,
                    title: $0.title,
                    color: RGBColor(cgColor: $0.cgColor) ?? .neutral,
                    sourceName: $0.source?.title ?? ""
                )
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func refreshEvents() {
        guard isEnabled, access.isReadable else {
            upcomingEvents = []
            return
        }

        let now = Date()
        let calendars = resolvedCalendars()
        // An empty selection means "every calendar" rather than "none", which is
        // what a first-run user expects right after granting access.
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-60 * 30),
            end: now.addingTimeInterval(lookAhead),
            calendars: calendars
        )

        let events = store.events(matching: predicate)
        upcomingEvents = CalendarEventFilter.filter(
            events.map(CalendarActivity.init(event:)),
            at: now,
            limit: 12
        )
        lastRefresh = now
    }

    private func resolvedCalendars() -> [EKCalendar]? {
        guard !selectedIdentifiers.isEmpty else { return nil }
        let matches = store.calendars(for: .event).filter { selectedIdentifiers.contains($0.calendarIdentifier) }
        return matches.isEmpty ? nil : matches
    }

    /// Events change rarely, so refresh on EventKit's own change notification
    /// and keep only a slow safety-net timer for time-based transitions
    /// (an event ending, or entering the imminent window).
    private func installChangeObserver() {
        guard changeObserver == nil else { return }
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reloadCalendars()
                self?.refreshEvents()
            }
        }
    }

    private func scheduleRefreshTimer() {
        guard refreshTimer == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshEvents() }
        }
        timer.tolerance = 15
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    // MARK: - Actions

    /// Opens the event in Calendar.app via its `ical://` URL, falling back to
    /// simply launching Calendar when the identifier cannot be resolved.
    func openInCalendar(_ activity: CalendarActivity?) {
        if let activity, let url = URL(string: "ical://ekevent/\(activity.id)") {
            if NSWorkspace.shared.open(url) { return }
        }
        if let url = URL(string: "ical://") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Preview/test seam: installs events without touching EventKit.
    func previewSeed(access: Access, calendars: [CalendarInfo] = [], events: [CalendarActivity] = []) {
        self.access = access
        availableCalendars = calendars
        upcomingEvents = events
        lastRefresh = Date()
    }

    static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: .notRequested
        case .restricted: .restricted
        case .denied: .denied
        case .fullAccess: .authorized
        case .writeOnly: .writeOnly
        @unknown default: .notRequested
        }
    }

    /// Opens the exact Privacy pane the user needs after a denial.
    static func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Filtering

/// Pure event-shaping rules, split out so they can be unit-tested without an
/// `EKEventStore` or calendar permission.
enum CalendarEventFilter {

    /// Drops finished events, de-duplicates recurring instances that share a
    /// start, sorts by start time, and caps the result.
    static func filter(_ events: [CalendarActivity], at now: Date, limit: Int) -> [CalendarActivity] {
        var seen = Set<String>()
        return events
            .filter { !$0.hasEnded(at: now) }
            .filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { lhs, rhs in
                // All-day events sort after timed events starting the same day,
                // so the pill's countdown candidate is always on top.
                if lhs.start == rhs.start { return !lhs.isAllDay && rhs.isAllDay }
                return lhs.start < rhs.start
            }
            .filter { event in
                let key = "\(event.title)|\(event.start.timeIntervalSinceReferenceDate)"
                return seen.insert(key).inserted
            }
            .prefix(limit)
            .map { $0 }
    }
}

// MARK: - Bridging

extension CalendarActivity {
    init(event: EKEvent) {
        self.init(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: event.title ?? "Untitled event",
            start: event.startDate ?? Date(),
            end: event.endDate ?? (event.startDate ?? Date()).addingTimeInterval(3600),
            isAllDay: event.isAllDay,
            location: event.location?.isEmpty == false ? event.location : nil,
            calendarTitle: event.calendar?.title ?? "",
            calendarColor: RGBColor(cgColor: event.calendar?.cgColor) ?? .neutral
        )
    }
}

extension RGBColor {
    init?(cgColor: CGColor?) {
        guard let cgColor,
              let converted = NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB) else { return nil }
        self.init(
            red: Double(converted.redComponent),
            green: Double(converted.greenComponent),
            blue: Double(converted.blueComponent)
        )
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }
}
