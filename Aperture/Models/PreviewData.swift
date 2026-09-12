//
//  PreviewData.swift
//  Aperture
//
//  Realistic fixtures for SwiftUI previews and unit tests. Kept in the app
//  target so previews can reach it without a separate module.
//

import Foundation

enum PreviewData {

    /// A fixed instant, so previews and snapshot expectations are stable.
    static let referenceDate = Date(timeIntervalSinceReferenceDate: 780_000_000)

    static let notchedScreen = ScreenGeometry(
        id: 1,
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        notch: NotchMetrics(width: 204, height: 37),
        menuBarHeight: 37,
        localizedName: "Built-in Display"
    )

    static let plainScreen = ScreenGeometry(
        id: 2,
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        notch: .none,
        menuBarHeight: 24,
        localizedName: "Studio Display"
    )

    static let playingMedia = MediaSnapshot(
        title: "Slow Meridian",
        artist: "Halden Cross",
        album: "Northlight",
        isPlaying: true,
        duration: 214,
        elapsed: 83,
        sampledAt: referenceDate,
        lastTransportChange: referenceDate.addingTimeInterval(-83),
        artworkData: nil,
        sourceName: "Demo player"
    )

    static let explicitMedia: MediaSnapshot = {
        var snapshot = playingMedia
        snapshot.title = "Ferrous"
        snapshot.artist = "Modal Atlas"
        snapshot.album = "Field Notes"
        snapshot.duration = 251
        snapshot.elapsed = 160
        snapshot.isExplicit = true
        snapshot.isShuffled = true
        return snapshot
    }()

    static let pausedMedia: MediaSnapshot = {
        var snapshot = playingMedia
        snapshot.isPlaying = false
        snapshot.lastTransportChange = referenceDate.addingTimeInterval(-4)
        return snapshot
    }()

    static let runningTimer = TimerActivity(
        id: UUID(uuidString: "0DE4B5A2-1C4E-4E7C-9F1F-2A2E5B7C9D01") ?? UUID(),
        title: "Steep tea",
        total: 300,
        fireDate: referenceDate.addingTimeInterval(126),
        pausedRemaining: nil
    )

    static let pausedTimer: TimerActivity = {
        var timer = runningTimer
        timer.fireDate = nil
        timer.pausedRemaining = 126
        return timer
    }()

    static let imminentEvent = CalendarActivity(
        id: "event.standup",
        title: "Design review",
        start: referenceDate.addingTimeInterval(7 * 60),
        end: referenceDate.addingTimeInterval(37 * 60),
        isAllDay: false,
        location: "Studio 2",
        calendarTitle: "Work",
        calendarColor: RGBColor(red: 0.44, green: 0.51, blue: 0.98)
    )

    static let upcomingEvents: [CalendarActivity] = [
        imminentEvent,
        CalendarActivity(
            id: "event.1on1",
            title: "1:1 with Priya",
            start: referenceDate.addingTimeInterval(95 * 60),
            end: referenceDate.addingTimeInterval(125 * 60),
            isAllDay: false,
            location: nil,
            calendarTitle: "Work",
            calendarColor: RGBColor(red: 0.44, green: 0.51, blue: 0.98)
        ),
        CalendarActivity(
            id: "event.dentist",
            title: "Dentist",
            start: referenceDate.addingTimeInterval(4 * 3600),
            end: referenceDate.addingTimeInterval(5 * 3600),
            isAllDay: false,
            location: "Marlow Street",
            calendarTitle: "Personal",
            calendarColor: RGBColor(red: 0.36, green: 0.78, blue: 0.62)
        ),
        CalendarActivity(
            id: "event.allday",
            title: "Quarter close",
            start: Calendar.current.startOfDay(for: referenceDate),
            end: Calendar.current.startOfDay(for: referenceDate).addingTimeInterval(86_400),
            isAllDay: true,
            location: nil,
            calendarTitle: "Work",
            calendarColor: RGBColor(red: 0.44, green: 0.51, blue: 0.98)
        ),
    ]

    static let previewCalendars: [CalendarService.CalendarInfo] = [
        CalendarService.CalendarInfo(
            id: "cal.work", title: "Work",
            color: RGBColor(red: 0.44, green: 0.51, blue: 0.98), sourceName: "iCloud"
        ),
        CalendarService.CalendarInfo(
            id: "cal.personal", title: "Personal",
            color: RGBColor(red: 0.36, green: 0.78, blue: 0.62), sourceName: "iCloud"
        ),
    ]

    static let call = CallActivity(
        id: UUID(uuidString: "9A1D3F60-77B2-4E31-8F0A-5C6D7E8F9A0B") ?? UUID(),
        title: "Standup",
        startedAt: referenceDate.addingTimeInterval(-372),
        isMuted: false
    )

    static let notification = NotificationActivity(
        id: UUID(uuidString: "3B2C1D40-55E6-4712-9A8B-0C1D2E3F4A5B") ?? UUID(),
        sourceName: "Aperture",
        title: "Build finished",
        body: "Release configuration succeeded in 42s.",
        symbolName: "hammer.fill",
        date: referenceDate,
        tint: RGBColor(red: 0.353, green: 0.812, blue: 0.596)
    )
}
