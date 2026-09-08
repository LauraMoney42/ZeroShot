//
//  HotkeyManager.swift
//  ZeroShot
//
//  Global hotkey via Carbon's RegisterEventHotKey.
//
//  Why Carbon and not CGEventTap or NSEvent.addGlobalMonitor: Carbon hotkeys
//  work from a plain LSUIElement app with NO Accessibility and NO Input
//  Monitoring permission. The API is old but it is not deprecated and it is
//  what every menu bar utility on the Mac uses.
//

import Foundation
import Carbon.HIToolbox

final class HotkeyManager {

    static let shared = HotkeyManager()

    // UserDefaults keys, deliberately public so the future Preferences pane can
    // write them and call `applyStoredBinding()`.
    static let keyCodeDefaultsKey = "hotkeyKeyCode"
    static let modifiersDefaultsKey = "hotkeyModifiers"

    /// Cmd+0. Note this shadows "Actual Size" in browsers while ZeroShot runs;
    /// Preferences will let the user change it.
    static let defaultKeyCode = UInt32(kVK_ANSI_0)
    static let defaultModifiers = UInt32(cmdKey)

    /// Four-char code 'ZERO' identifying our hotkeys to Carbon.
    private static let signature: OSType = 0x5A45524F
    private static let hotKeyIdentifier: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var handler: (() -> Void)?

    /// Currently registered binding, or nil when nothing is registered.
    private(set) var currentKeyCode: UInt32?
    private(set) var currentModifiers: UInt32?

    private init() {}

    deinit {
        unregister()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    // MARK: - Public API

    /// Registers a global hotkey, replacing any previous one, and remembers the
    /// binding in UserDefaults.
    ///
    /// - Parameters:
    ///   - keyCode: a virtual key code, e.g. `UInt32(kVK_ANSI_0)`.
    ///   - modifiers: Carbon modifier mask, e.g. `UInt32(cmdKey | shiftKey)`.
    /// - Returns: true if Carbon accepted the registration. It refuses when the
    ///   combination is already claimed by another process.
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> Bool {
        unregister()
        self.handler = handler
        installEventHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: HotkeyManager.signature,
                                     id: HotkeyManager.hotKeyIdentifier)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode,
                                         modifiers,
                                         hotKeyID,
                                         GetApplicationEventTarget(),
                                         0,
                                         &reference)
        guard status == noErr, let reference else {
            self.handler = nil
            return false
        }

        hotKeyRef = reference
        currentKeyCode = keyCode
        currentModifiers = modifiers
        store(keyCode: keyCode, modifiers: modifiers)
        return true
    }

    /// Registers whatever binding is stored in UserDefaults, falling back to
    /// Cmd+0 on first launch.
    @discardableResult
    func registerStoredHotkey(handler: @escaping () -> Void) -> Bool {
        let stored = storedBinding()
        return register(keyCode: stored.keyCode, modifiers: stored.modifiers, handler: handler)
    }

    /// Tears down the current hotkey. Safe to call when nothing is registered.
    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        currentKeyCode = nil
        currentModifiers = nil
        handler = nil
    }

    /// The binding a Preferences pane should show.
    func storedBinding() -> (keyCode: UInt32, modifiers: UInt32) {
        let defaults = UserDefaults.standard
        let keyCode = defaults.object(forKey: HotkeyManager.keyCodeDefaultsKey) as? Int
        let modifiers = defaults.object(forKey: HotkeyManager.modifiersDefaultsKey) as? Int
        return (UInt32(keyCode ?? Int(HotkeyManager.defaultKeyCode)),
                UInt32(modifiers ?? Int(HotkeyManager.defaultModifiers)))
    }

    // MARK: - Internals

    private func store(keyCode: UInt32, modifiers: UInt32) {
        let defaults = UserDefaults.standard
        defaults.set(Int(keyCode), forKey: HotkeyManager.keyCodeDefaultsKey)
        defaults.set(Int(modifiers), forKey: HotkeyManager.modifiersDefaultsKey)
    }

    fileprivate func fire() {
        handler?()
    }

    /// Installs the single Carbon event handler for the process. Done lazily so
    /// nothing Carbon-related happens until a hotkey is actually wanted.
    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))

        // The callback must be a plain C function pointer, so `self` travels
        // through userData rather than being captured.
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }

            var receivedID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &receivedID)
            guard status == noErr,
                  receivedID.signature == HotkeyManager.signature,
                  receivedID.id == HotkeyManager.hotKeyIdentifier else { return noErr }

            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                manager.fire()
            }
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(),
                            callback,
                            1,
                            &spec,
                            Unmanaged.passUnretained(self).toOpaque(),
                            &eventHandlerRef)
    }
}
