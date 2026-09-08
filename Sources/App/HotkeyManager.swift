//
//  HotkeyManager.swift
//  ZeroShot
//
//  Global hotkeys via Carbon's RegisterEventHotKey.
//
//  Why Carbon and not CGEventTap or NSEvent.addGlobalMonitor: Carbon hotkeys
//  work from a plain LSUIElement app with NO Accessibility and NO Input
//  Monitoring permission. The API is old but it is not deprecated and it is
//  what every menu bar utility on the Mac uses.
//
//  TWO HOTKEYS
//  -----------
//  ZeroShot has two independent global hotkeys, one per capture mode
//  (`Slot`). Carbon identifies each registered hotkey by a numeric id carried
//  in its `EventHotKeyID`, so every slot gets its own id, its own pair of
//  UserDefaults keys and its own default binding; only the event handler
//  itself is shared.
//

import Foundation
import Carbon.HIToolbox

final class HotkeyManager {

    static let shared = HotkeyManager()

    /// Which capture action a registered hotkey triggers.
    enum Slot: CaseIterable {
        case fullScreen
        case region

        /// Numeric id Carbon uses to tell registered hotkeys apart. Arbitrary
        /// and stable as long as it does not change between launches.
        var carbonID: UInt32 {
            switch self {
            case .fullScreen: return 1
            case .region: return 2
            }
        }

        var keyCodeDefaultsKey: String {
            switch self {
            case .fullScreen: return "hotkeyFullScreenKeyCode"
            case .region: return "hotkeyRegionKeyCode"
            }
        }

        var modifiersDefaultsKey: String {
            switch self {
            case .fullScreen: return "hotkeyFullScreenModifiers"
            case .region: return "hotkeyRegionModifiers"
            }
        }

        /// Full Screen defaults to Cmd+0, Region to Cmd+1.
        var defaultKeyCode: UInt32 {
            switch self {
            case .fullScreen: return UInt32(kVK_ANSI_0)
            case .region: return UInt32(kVK_ANSI_1)
            }
        }

        var defaultModifiers: UInt32 { UInt32(cmdKey) }

        /// Shown in Preferences next to each recorder.
        var label: String {
            switch self {
            case .fullScreen: return "Full Screen"
            case .region: return "Region"
            }
        }
    }

    /// Four-char code 'ZERO' identifying our hotkeys to Carbon.
    private static let signature: OSType = 0x5A45524F

    private struct Registration {
        var hotKeyRef: EventHotKeyRef?
        var handler: (() -> Void)?
    }

    private var eventHandlerRef: EventHandlerRef?
    private var registrations: [Slot: Registration] = [:]

    private init() {}

    deinit {
        unregisterAll()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    // MARK: - Public API

    /// Registers a global hotkey for `slot`, replacing any previous binding
    /// for that slot, and remembers the binding in UserDefaults. The other
    /// slot's hotkey, if any, is left untouched.
    ///
    /// - Parameters:
    ///   - keyCode: a virtual key code, e.g. `UInt32(kVK_ANSI_0)`.
    ///   - modifiers: Carbon modifier mask, e.g. `UInt32(cmdKey | shiftKey)`.
    /// - Returns: true if Carbon accepted the registration. It refuses when the
    ///   combination is already claimed by another process (or by ZeroShot's
    ///   own other slot).
    @discardableResult
    func register(_ slot: Slot, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> Bool {
        unregister(slot)
        installEventHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: HotkeyManager.signature, id: slot.carbonID)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode,
                                         modifiers,
                                         hotKeyID,
                                         GetApplicationEventTarget(),
                                         0,
                                         &reference)
        guard status == noErr, let reference else {
            return false
        }

        registrations[slot] = Registration(hotKeyRef: reference, handler: handler)
        store(slot, keyCode: keyCode, modifiers: modifiers)
        return true
    }

    /// Registers whatever binding is stored in UserDefaults for `slot`,
    /// falling back to that slot's default on first launch.
    @discardableResult
    func registerStoredHotkey(_ slot: Slot, handler: @escaping () -> Void) -> Bool {
        let stored = storedBinding(for: slot)
        return register(slot, keyCode: stored.keyCode, modifiers: stored.modifiers, handler: handler)
    }

    /// Tears down `slot`'s hotkey. Safe to call when nothing is registered.
    func unregister(_ slot: Slot) {
        if let ref = registrations[slot]?.hotKeyRef {
            UnregisterEventHotKey(ref)
        }
        registrations[slot] = nil
    }

    /// Tears down every registered hotkey.
    func unregisterAll() {
        for slot in Slot.allCases {
            unregister(slot)
        }
    }

    /// The binding a Preferences recorder for `slot` should show.
    func storedBinding(for slot: Slot) -> (keyCode: UInt32, modifiers: UInt32) {
        let defaults = UserDefaults.standard
        let keyCode = defaults.object(forKey: slot.keyCodeDefaultsKey) as? Int
        let modifiers = defaults.object(forKey: slot.modifiersDefaultsKey) as? Int
        return (UInt32(keyCode ?? Int(slot.defaultKeyCode)),
                UInt32(modifiers ?? Int(slot.defaultModifiers)))
    }

    // MARK: - Internals

    private func store(_ slot: Slot, keyCode: UInt32, modifiers: UInt32) {
        let defaults = UserDefaults.standard
        defaults.set(Int(keyCode), forKey: slot.keyCodeDefaultsKey)
        defaults.set(Int(modifiers), forKey: slot.modifiersDefaultsKey)
    }

    fileprivate func fire(carbonID: UInt32) {
        guard let slot = Slot.allCases.first(where: { $0.carbonID == carbonID }) else { return }
        registrations[slot]?.handler?()
    }

    /// Installs the single Carbon event handler for the process, shared by
    /// every slot. Done lazily so nothing Carbon-related happens until a
    /// hotkey is actually wanted.
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
            guard status == noErr, receivedID.signature == HotkeyManager.signature else { return noErr }

            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            let carbonID = receivedID.id
            DispatchQueue.main.async {
                manager.fire(carbonID: carbonID)
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
