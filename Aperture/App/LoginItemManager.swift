//
//  LoginItemManager.swift
//  Aperture
//

import Foundation
import OSLog
import ServiceManagement

/// Wraps `SMAppService.mainApp`. Registration only sticks for a signed app in
/// its final location; unsigned debug builds surface `.notRegistered` back to
/// Settings instead of silently pretending it worked.
@MainActor
enum LoginItemManager {

    private static let log = Logger(subsystem: ApertureInfo.bundleIdentifier, category: "LoginItem")

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static var requiresApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// Returns the status actually achieved, which may differ from `enabled`.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> SMAppService.Status {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.error("Login item update failed: \(error.localizedDescription, privacy: .public)")
        }
        return SMAppService.mainApp.status
    }

    /// Opens System Settings ▸ General ▸ Login Items so the user can approve.
    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: "Enabled"
        case .requiresApproval: "Awaiting approval in System Settings"
        case .notFound: "Unavailable for this build"
        case .notRegistered: "Not enabled"
        @unknown default: "Unknown"
        }
    }
}
