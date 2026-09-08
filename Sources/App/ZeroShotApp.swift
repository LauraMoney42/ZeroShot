//
//  ZeroShotApp.swift
//  ZeroShot
//
//  Menu bar only entry point. The app has no Dock icon and no windows until a
//  capture succeeds (LSUIElement is set in Support/Info.plist).
//

import AppKit
import SwiftUI
import Observation

// MARK: - App

@main
struct ZeroShotApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("ZeroShot", systemImage: "camera") {
            MenuBarContent()
        }
        .menuBarExtraStyle(.menu)
    }
}

// MARK: - Menu

struct MenuBarContent: View {

    var body: some View {
        // Reading AppState.shared inside `body` is enough for @Observable to
        // track it; SwiftUI installs the observation scope around body.
        let state = AppState.shared

        Button("Capture Full Screen") { state.capture(.fullScreen) }
            .keyboardShortcut("0", modifiers: .command)

        Button("Capture Region") { state.capture(.region) }
            .keyboardShortcut("1", modifiers: .command)

        Button("Capture Window") { state.capture(.window) }

        Button("Capture in 5 Seconds") { state.capture(.region, delay: 5) }

        Divider()

        Button("Open Last Screenshot") { state.openLastScreenshot() }
            .disabled(state.lastSavedURL == nil)

        Button("Reveal Screenshots Folder") { state.revealScreenshotsFolder() }

        Divider()

        Button("Preferences...") { state.showPreferences() }
            .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Quit ZeroShot") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}

// MARK: - App state

/// Shared, main-actor app state. Holds the things the menu needs to observe and
/// owns the capture-to-editor flow.
@MainActor
@Observable
final class AppState {

    static let shared = AppState()

    /// Set once the exporter exists (milestone 5). Until then "Open Last
    /// Screenshot" stays disabled.
    var lastSavedURL: URL?

    /// Guards against a second capture starting while Apple's picker is up.
    private(set) var isCapturing = false

    @ObservationIgnored private var preferencesController: PreferencesWindowController?

    private init() {}

    func capture(_ mode: CaptureMode, delay: Int = 0) {
        guard !isCapturing else { return }
        isCapturing = true

        Task { @MainActor in
            defer { isCapturing = false }
            guard let result = await CaptureService.capture(mode: mode, delay: delay) else {
                // Esc, or screencapture refused (most often a missing Screen
                // Recording permission). Either way: do nothing, quietly.
                return
            }
            if Preferences.shared.copyOnCapture {
                AppState.copyRawCapture(result)
            }
            if Preferences.shared.playSound {
                AppState.playShutterSound()
            }
            openEditor(with: result)
        }
    }

    /// `screencapture` is run with `-x` (no camera sound) so ZeroShot can play
    /// its own, gated by the playSound preference. Prefers the system's real
    /// screenshot sound; falls back to a bundled system sound if that file
    /// ever moves or is missing on a future macOS.
    /// Puts the untouched capture on the clipboard right away, so a paste
    /// works even if the user never opens the editor. Done later overwrites
    /// this with the annotated version, if that preference is also on.
    private static func copyRawCapture(_ result: CaptureResult) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let image = NSImage(cgImage: result.image, size: NSSize(width: result.pixelSize.width,
                                                                 height: result.pixelSize.height))
        pasteboard.writeObjects([image])
    }

    private static func playShutterSound() {
        let systemGrabSound = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif"
        if FileManager.default.fileExists(atPath: systemGrabSound),
           let sound = NSSound(contentsOfFile: systemGrabSound, byReference: true) {
            sound.play()
        } else {
            NSSound(named: "Pop")?.play()
        }
    }

    func openEditor(with result: CaptureResult) {
        let document = EditorDocument(image: result.image, sourceURL: result.fileURL)
        let controller = EditorWindowController(document: document)
        controller.present()
    }

    /// `lastSavedURL` is set by `ExportController` whenever a save succeeds.
    /// Opens it in the user's default viewer for PNGs.
    func openLastScreenshot() {
        guard let url = lastSavedURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Opens (or reveals) the configured default save folder in Finder.
    func revealScreenshotsFolder() {
        let folder = Preferences.shared.defaultSaveFolder
        // Make sure there is something for Finder to show even before the
        // first save.
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    func showPreferences() {
        if preferencesController == nil {
            preferencesController = PreferencesWindowController()
        }
        preferencesController?.showWindow(nil)
        WindowActivation.bringToFront(preferencesController?.window)
    }

    /// Re-registers `slot`'s global hotkey with a new binding and persists it
    /// (`HotkeyManager.register` writes the UserDefaults keys itself). Used by
    /// the Preferences hotkey recorders so a change takes effect immediately.
    @discardableResult
    func reregisterHotkey(_ slot: HotkeyManager.Slot, keyCode: UInt32, modifiers: UInt32) -> Bool {
        HotkeyManager.shared.register(slot, keyCode: keyCode, modifiers: modifiers) {
            MainActor.assumeIsolated {
                switch slot {
                case .fullScreen: AppState.shared.capture(.fullScreen)
                case .region: AppState.shared.capture(.region)
                }
            }
        }
    }
}

// MARK: - App delegate

/// Owns the global hotkey. SwiftUI's App struct is a value type recreated at
/// will, so anything with a lifetime lives here instead.
final class AppDelegate: NSObject, NSApplicationDelegate {

    let hotkeys = HotkeyManager.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = Preferences.shared
        // DEBUG only: ZEROSHOT_OPEN_IMAGE=/path.png opens the editor without the
        // picker. The whole DebugLaunch type is compiled out of Release builds,
        // so the call site has to be guarded too, not just the type.
        #if DEBUG
        DebugLaunch.openIfRequested()
        #endif

        for slot in HotkeyManager.Slot.allCases {
            let stored = hotkeys.storedBinding(for: slot)
            let registered = AppState.shared.reregisterHotkey(slot, keyCode: stored.keyCode, modifiers: stored.modifiers)
            if !registered {
                NSLog("ZeroShot: could not register the \(slot.label) hotkey, another app may own it.")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys.unregisterAll()
    }

    /// LSUIElement app: closing the last editor should not quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

// MARK: - Preferences window

/// Hosts the real settings UI (`PreferencesWindow`, in Sources/Preferences/).
@MainActor
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "ZeroShot Preferences"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: PreferencesWindow())
        super.init(window: window)
        window.delegate = self
    }

    /// Drops the floating level `WindowActivation` used to get in front.
    func windowDidBecomeKey(_ notification: Notification) {
        WindowActivation.settle(window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PreferencesWindowController is created in code only")
    }
}
