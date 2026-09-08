//
//  WindowActivation.swift
//  ZeroShot
//
//  Brings one of our windows in front of every other app. A menu bar agent
//  is never the "user's current app", so on macOS 14+ a plain activate() is
//  refused when it follows a hotkey or a menu click in another app. The
//  combination below is what actually works:
//
//  1. Float the window until it gets focus, so it is at least visible on top.
//  2. Ask Launch Services to open our own bundle with activates=true. Launch
//     Services is allowed to activate anything, and for an already-running
//     app that just brings it forward.
//

import AppKit

@MainActor
enum WindowActivation {

    static func bringToFront(_ window: NSWindow?) {
        window?.level = .floating
        DispatchQueue.main.async {
            NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
            NSApp.activate(ignoringOtherApps: true)
            window?.orderFrontRegardless()
            window?.makeKeyAndOrderFront(nil)

            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config)
        }
    }

    /// Call from `windowDidBecomeKey` so the window behaves normally once it
    /// has focus.
    static func settle(_ window: NSWindow?) {
        window?.level = .normal
    }
}
