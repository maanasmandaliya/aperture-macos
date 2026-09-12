//
//  SettingsWindowController.swift
//  Aperture
//

import AppKit
import SwiftUI

/// Hosts the settings UI in a real, resizable window.
///
/// Built directly on `NSWindowController` rather than SwiftUI's `Settings`
/// scene: an `.accessory` activation-policy app has no reliable way to open
/// that scene, and Aperture needs to raise the window from a status-item menu
/// while briefly promoting itself to a regular app so the window can take focus.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment

        let hosting = NSHostingController(
            rootView: SettingsRootView().environment(environment)
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "\(ApertureInfo.name) Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 620, height: 470))
        window.isReleasedWhenClosed = false
        window.center()
        window.titlebarAppearsTransparent = false

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present() {
        // Temporarily become a regular app so the settings window can be
        // focused and reachable via ⌘-Tab; policy is restored on close.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
