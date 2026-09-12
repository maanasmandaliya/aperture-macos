//
//  main.swift
//  Aperture
//
//  Aperture is an agent app: no Dock tile, no windows at launch, and every
//  surface it does own (the overlay panels, the status item, the settings
//  window) is positioned and levelled in ways only AppKit can express.
//
//  It therefore starts from an explicit AppKit entry point rather than a SwiftUI
//  `App`. The `App` protocol requires a `Scene`, and an agent app has none to
//  give — a placeholder scene is not free: an unused `MenuBarExtra` still
//  registers a status item and writes its visibility into user defaults, which
//  is confusing to anyone reading the app's defaults domain later.
//
//  SwiftUI still draws everything: the overlay, the hub and all of Settings are
//  SwiftUI views hosted inside AppKit windows.
//

import AppKit

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
