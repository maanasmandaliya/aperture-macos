//
//  SettingsRootView.swift
//  Aperture
//

import SwiftUI

struct SettingsRootView: View {

    @Environment(AppEnvironment.self) private var environment
    @State private var selection: SettingsTab = .general

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general, appearance, calendar, accessibility, about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "General"
            case .appearance: "Appearance"
            case .calendar: "Calendar"
            case .accessibility: "Accessibility"
            case .about: "About"
            }
        }

        var symbolName: String {
            switch self {
            case .general: "gearshape"
            case .appearance: "paintbrush"
            case .calendar: "calendar"
            case .accessibility: "figure.wave"
            case .about: "info.circle"
            }
        }
    }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(SettingsTab.allCases) { tab in
                pane(for: tab)
                    .tabItem { Label(tab.title, systemImage: tab.symbolName) }
                    .tag(tab)
            }
        }
        .frame(minWidth: 580, minHeight: 430)
        .scenePadding()
    }

    @ViewBuilder
    private func pane(for tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettingsView()
        case .appearance: AppearanceSettingsView()
        case .calendar: CalendarSettingsView()
        case .accessibility: AccessibilitySettingsView()
        case .about: AboutSettingsView()
        }
    }
}

#Preview("Settings") {
    SettingsRootView()
        .environment(AppEnvironment.preview())
        .frame(width: 620, height: 470)
}
