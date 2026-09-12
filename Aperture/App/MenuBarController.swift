//
//  MenuBarController.swift
//  Aperture
//

import AppKit
import Carbon.HIToolbox
import Observation

/// Owns the status item and its menu.
///
/// Built with AppKit rather than SwiftUI's `MenuBarExtra` because the menu's
/// contents (shortcut glyph, pause state, activity summary) change with app
/// state, and an `NSMenu` rebuilt on `menuNeedsUpdate` is the direct way to keep
/// that honest without re-creating a scene.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {

    private let environment: AppEnvironment
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    init(environment: AppEnvironment) {
        self.environment = environment
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        // A stable autosave name keeps the item's position across launches
        // instead of letting macOS invent a new key each time.
        statusItem.autosaveName = "ApertureStatusItem"
        // Forced visible on purpose. macOS persists status-item visibility and
        // will hide overflow items on a crowded menu bar — which on a notched
        // MacBook happens easily. Aperture has no Dock icon and no window, so a
        // hidden item would leave the app with no way to reach Settings or Quit.
        statusItem.isVisible = true

        configureButton()
        menu.delegate = self
        statusItem.menu = menu
    }

    func invalidate() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    // MARK: - Button

    private func configureButton() {
        guard let button = statusItem.button else { return }
        let symbol = NSImage(
            systemSymbolName: "circle.dotted.circle",
            accessibilityDescription: "Aperture"
        )
        symbol?.isTemplate = true
        button.image = symbol
        button.imagePosition = .imageOnly
        button.toolTip = "\(ApertureInfo.name) — \(ApertureInfo.tagline)"
        button.setAccessibilityLabel("Aperture menu")
    }

    /// Reflects the paused state in the status glyph so the app's state is
    /// legible without opening the menu.
    private func refreshButton() {
        guard let button = statusItem.button else { return }
        let name = environment.preferences.isPaused ? "circle.dotted" : "circle.dotted.circle"
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: "Aperture")
        symbol?.isTemplate = true
        button.image = symbol
        button.appearsDisabled = environment.preferences.isPaused
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshButton()
        menu.removeAllItems()

        let header = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: "Toggle Hub",
            action: #selector(toggleHub),
            keyEquivalent: ""
        )
        toggle.target = self
        applyShortcutGlyph(to: toggle)
        toggle.isEnabled = !environment.preferences.isPaused
        menu.addItem(toggle)

        let pause = NSMenuItem(
            title: environment.preferences.isPaused ? "Resume Aperture" : "Pause Aperture",
            action: #selector(togglePause),
            keyEquivalent: ""
        )
        pause.target = self
        menu.addItem(pause)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit Aperture", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func statusLine() -> String {
        if environment.preferences.isPaused { return "Aperture is paused" }
        guard let activity = environment.currentActivity else { return "Idle" }
        switch activity {
        case .media(let media):
            return media.isPlaying ? "Playing — \(media.title)" : "Paused — \(media.title)"
        case .timer(let timer):
            return "Timer — \(DurationFormatter.clock(timer.remaining(at: environment.now)))"
        case .calendar(let event):
            return "Next — \(event.title)"
        case .call(let call):
            return "Call — \(call.title)"
        }
    }

    /// Shows the user's configured shortcut next to Toggle Hub. The item does
    /// not *use* the key equivalent (the global Carbon hot key does that), it
    /// only advertises it.
    private func applyShortcutGlyph(to item: NSMenuItem) {
        let binding = environment.preferences.hotKey
        guard binding.isValid else { return }
        var flags: NSEvent.ModifierFlags = []
        if binding.modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if binding.modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if binding.modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if binding.modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        item.keyEquivalentModifierMask = flags
        item.keyEquivalent = HotKeyBinding.keyName(for: binding.keyCode).lowercased() == "space"
            ? " "
            : HotKeyBinding.keyName(for: binding.keyCode).lowercased()
    }

    // MARK: - Actions

    @objc private func toggleHub() { environment.toggleHub() }

    @objc private func togglePause() {
        environment.setPaused(!environment.preferences.isPaused)
        refreshButton()
    }

    @objc private func openSettings() { onOpenSettings?() }

    @objc private func quit() { onQuit?() }
}
