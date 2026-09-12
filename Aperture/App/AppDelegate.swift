//
//  AppDelegate.swift
//  Aperture
//

import AppKit
import Observation
import OSLog
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private(set) var environment = AppEnvironment()

    private var menuBar: MenuBarController?
    private var settingsWindow: SettingsWindowController?
    private let hotKeys = HotKeyCenter()
    private var hotKeyObservation: Task<Void, Never>?
    private let log = Logger(subsystem: ApertureInfo.bundleIdentifier, category: "AppDelegate")

    /// Unit tests load the app bundle as their host; without this guard the
    /// overlay panels, status item and global hot key would all be installed
    /// into the test process.
    private var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isRunningTests else { return }

        // Menu-bar utility: no Dock tile, no app menu, never steals activation.
        NSApp.setActivationPolicy(.accessory)

        environment.start()

        let menuBar = MenuBarController(environment: environment)
        menuBar.onOpenSettings = { [weak self] in self?.showSettings() }
        menuBar.onQuit = { NSApp.terminate(nil) }
        self.menuBar = menuBar

        registerHotKey()
        observeHotKeyChanges()

        // Sync the login item to whatever the user last chose, in case the
        // registration was revoked (moved app bundle, macOS reset, etc.).
        if environment.preferences.launchAtLogin, !LoginItemManager.isEnabled {
            LoginItemManager.setEnabled(true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyObservation?.cancel()
        hotKeys.invalidate()
        menuBar?.invalidate()
        environment.shutDown()
    }

    /// A menu-bar utility has no windows to restore; clicking the Dock icon (if
    /// the user ever forces one) should reveal Settings instead of doing nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings()
        return true
    }

    // MARK: - Settings

    @objc func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(environment: environment)
        }
        settingsWindow?.present()
    }

    // MARK: - Hot key

    private func registerHotKey() {
        hotKeys.register(environment.preferences.hotKey) { [weak self] in
            self?.environment.toggleHub()
        }
        if hotKeys.lastRegistrationFailed {
            log.notice("Toggle shortcut is unavailable — another app may already own it.")
        }
    }

    /// Re-registers when the user edits the shortcut in Settings.
    private func observeHotKeyChanges() {
        hotKeyObservation = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = self.environment.preferences.hotKey
                    } onChange: {
                        continuation.resume()
                    }
                }
                await Task.yield()
                guard !Task.isCancelled else { return }
                self.registerHotKey()
            }
        }
    }

    var hotKeyRegistrationFailed: Bool { hotKeys.lastRegistrationFailed }
}
