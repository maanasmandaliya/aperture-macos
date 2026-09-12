//
//  OverlayPanel.swift
//  Aperture
//
//  The borderless, non-activating panel that hosts the overlay on one screen.
//

import AppKit
import SwiftUI

/// A floating panel pinned to the top centre of a single display.
///
/// Windowing decisions worth knowing:
/// * `.nonactivatingPanel` — clicking the hub must never pull focus away from
///   the app the user is working in, so the panel can become *key* (sliders and
///   arrow keys work) without the app becoming *active*.
/// * `.statusBar` level — the camera housing sits above the menu bar's own
///   level; anything lower would be clipped by it on notched Macs.
/// * `.canJoinAllSpaces` + `.stationary` — the overlay belongs to the display,
///   not to a Space, and must not slide during Space transitions.
/// * `.canJoinAllSpaces` / `.fullScreenAuxiliary` follow the user's preference;
///   see `setSpaceBehavior(showInFullscreen:)` for what they can and cannot do.
final class OverlayPanel: NSPanel {

    /// Set by ``OverlayManager``; gates key-window eligibility so the collapsed
    /// pill never takes keyboard focus.
    var allowsKeyStatus = false {
        didSet {
            guard oldValue != allowsKeyStatus else { return }
            if !allowsKeyStatus, isKeyWindow { resignKey() }
        }
    }

    override var canBecomeKey: Bool { allowsKeyStatus }
    override var canBecomeMain: Bool { false }

    /// Escape must dismiss the hub even though there is no responder chain
    /// leading anywhere useful from a borderless panel.
    var onCancel: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // The SwiftUI surface draws its own, shaped shadow.
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        // `sharingType` is left at its default (`.readOnly`) on purpose. Setting
        // it to `.none` would hide the overlay from screenshots and screen
        // sharing, which is surprising: the overlay is part of what the user
        // sees, so it should be part of what they capture. Change this one line
        // if you want the opposite.
        setAccessibilityLabel("Aperture overlay")
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// Collection behaviour is the only supported lever over Space membership.
    ///
    /// `.canJoinAllSpaces` puts the panel on every Space; with it off the panel
    /// is confined to the Space it is on and follows app activation instead.
    ///
    /// Note what this does *not* do: it cannot keep the overlay out of a
    /// full-screen app. A window at `.statusBar` level is drawn above
    /// full-screen windows whatever its collection behaviour, and macOS exposes
    /// no public way to detect that a full-screen Space is active — measured on
    /// macOS 26, a full-screen window is byte-for-byte indistinguishable from a
    /// zoomed one in `CGWindowList` (same bounds, layer and alpha; the menu-bar
    /// window stays present in both). Suppressing the overlay there would need a
    /// private API, so Aperture does not claim to do it.
    func setSpaceBehavior(showInFullscreen: Bool) {
        var behavior: NSWindow.CollectionBehavior = [.stationary, .ignoresCycle]
        if showInFullscreen {
            behavior.insert(.canJoinAllSpaces)
            behavior.insert(.fullScreenAuxiliary)
        } else {
            behavior.insert(.moveToActiveSpace)
        }
        collectionBehavior = behavior
    }
}

/// Hosting view for the overlay's SwiftUI tree.
///
/// `acceptsFirstMouse` is the important part. Aperture's panel is deliberately
/// not key while collapsed, and AppKit's default is to swallow the first click
/// into an inactive window purely to focus it. Without this override, opening
/// the hub from the pill would take two clicks.
final class OverlayHostingView: NSHostingView<AnyView> {

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The panel is transparent apart from what SwiftUI draws, so the view must
    /// never paint a background of its own.
    override var isOpaque: Bool { false }

    @available(*, unavailable)
    required init(rootView: AnyView) { fatalError("Use init(overlayContent:)") }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    init(overlayContent: AnyView) {
        super.init(rootView: overlayContent)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = [.width, .height]
    }
}
