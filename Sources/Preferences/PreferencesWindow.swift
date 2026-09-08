//
//  PreferencesWindow.swift
//  ZeroShot
//
//  The real Settings window, replacing ZeroShotApp's placeholder. Three tabs:
//  General (hotkey, export toggles, launch at login), Folders (default and
//  favorite folders, filename pattern with a live preview), and Defaults
//  (stroke/badge color, stroke width, font size, badge radius).
//

import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

// MARK: - Root

struct PreferencesWindow: View {

    /// Ephemeral UserDefaults suite used only to compute the filename preview
    /// text, so typing in the pattern field never advances the real per-day
    /// {counter} the exporter uses when actually saving.
    fileprivate static let previewDefaults = UserDefaults(suiteName: "us.kindcode.zeroshot.filenamePreview") ?? .standard

    var body: some View {
        TabView {
            GeneralPreferencesView()
                .tabItem { Label("General", systemImage: "gearshape") }
            FoldersPreferencesView()
                .tabItem { Label("Files", systemImage: "folder") }
            DefaultsPreferencesView()
                .tabItem { Label("Defaults", systemImage: "paintpalette") }
        }
        .frame(width: 460, height: 420)
    }
}

// MARK: - General

struct GeneralPreferencesView: View {

    @State private var copyOnCapture = Preferences.shared.copyOnCapture
    @State private var copyToClipboard = Preferences.shared.copyToClipboard
    @State private var saveToFolder = Preferences.shared.saveToFolder
    @State private var playSound = Preferences.shared.playSound
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                HotkeyRecorderView(slot: .fullScreen)
                HotkeyRecorderView(slot: .region)
            } header: {
                Text("Capture Hotkeys")
            }

            Section {
                Toggle("Copy screenshot to clipboard immediately", isOn: $copyOnCapture)
                    .onChange(of: copyOnCapture) { _, newValue in
                        Preferences.shared.copyOnCapture = newValue
                    }
                Toggle("Copy annotated image to clipboard when done", isOn: $copyToClipboard)
                    .onChange(of: copyToClipboard) { _, newValue in
                        Preferences.shared.copyToClipboard = newValue
                    }
                Toggle("Save to folder", isOn: $saveToFolder)
                    .onChange(of: saveToFolder) { _, newValue in
                        Preferences.shared.saveToFolder = newValue
                    }
                Toggle("Play a sound on capture", isOn: $playSound)
                    .onChange(of: playSound) { _, newValue in
                        Preferences.shared.playSound = newValue
                    }
            } header: {
                Text("On Capture")
            }

            Section {
                Toggle("Launch ZeroShot at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }
            } header: {
                Text("Startup")
            }
        }
        .padding(20)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("ZeroShot: could not change launch-at-login: \(error.localizedDescription)")
            // Reflect whatever actually happened rather than the failed intent.
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Hotkey recorder

/// Click to record: the next key combo with at least one modifier becomes the
/// new hotkey for `slot`, stored via HotkeyManager's existing UserDefaults
/// keys and re-registered immediately so it takes effect without a relaunch.
/// One instance per slot; each keeps its own recording state so recording one
/// hotkey does not disturb the other.
struct HotkeyRecorderView: View {

    let slot: HotkeyManager.Slot

    @State private var keyCode: UInt32
    @State private var modifiers: UInt32
    @State private var isRecording = false
    @State private var eventMonitor: Any?

    init(slot: HotkeyManager.Slot) {
        self.slot = slot
        let stored = HotkeyManager.shared.storedBinding(for: slot)
        _keyCode = State(initialValue: stored.keyCode)
        _modifiers = State(initialValue: stored.modifiers)
    }

    var body: some View {
        HStack {
            Text("\(slot.label):")
            Button(isRecording ? "Press a key combo..." : HotkeyRecorderView.symbols(modifiers: modifiers, keyCode: keyCode)) {
                startRecording()
            }
            .frame(minWidth: 130)
            .disabled(isRecording)

            Button("Reset to \(HotkeyRecorderView.symbols(modifiers: slot.defaultModifiers, keyCode: slot.defaultKeyCode))") {
                reset()
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil // swallow the key while recording
        }
    }

    private func stopRecording() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
        isRecording = false
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            stopRecording()
            return
        }

        let carbonModifiers = HotkeyRecorderView.carbonModifiers(from: event.modifierFlags)
        // At least one modifier is required; otherwise keep listening so a
        // stray letter key does not become the whole hotkey.
        guard carbonModifiers != 0 else { return }

        apply(keyCode: UInt32(event.keyCode), modifiers: carbonModifiers)
        stopRecording()
    }

    private func reset() {
        apply(keyCode: slot.defaultKeyCode, modifiers: slot.defaultModifiers)
    }

    private func apply(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        if !AppState.shared.reregisterHotkey(slot, keyCode: keyCode, modifiers: modifiers) {
            NSLog("ZeroShot: could not register that hotkey, it may already be claimed by another app.")
        }
    }

    // MARK: Formatting

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        return result
    }

    private static func symbols(modifiers: UInt32, keyCode: UInt32) -> String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "\u{2303}" }
        if modifiers & UInt32(optionKey) != 0 { text += "\u{2325}" }
        if modifiers & UInt32(shiftKey) != 0 { text += "\u{21E7}" }
        if modifiers & UInt32(cmdKey) != 0 { text += "\u{2318}" }
        text += keyLabels[keyCode] ?? "Key \(keyCode)"
        return text
    }

    private static let keyLabels: [UInt32: String] = [
        UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
        UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
        UInt32(kVK_ANSI_9): "9",
        UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
        UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
        UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_Space): "Space", UInt32(kVK_Return): "Return", UInt32(kVK_Tab): "Tab",
        UInt32(kVK_Delete): "Delete", UInt32(kVK_Escape): "Escape",
        UInt32(kVK_LeftArrow): "\u{2190}", UInt32(kVK_RightArrow): "\u{2192}",
        UInt32(kVK_UpArrow): "\u{2191}", UInt32(kVK_DownArrow): "\u{2193}",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        // The numeric keypad sends its own key codes, distinct from the
        // number row (kVK_ANSI_0 vs kVK_ANSI_Keypad0), so a hotkey can be
        // bound to either without colliding with the other. Labeled
        // separately here so the two don't look identical in the recorder.
        UInt32(kVK_ANSI_Keypad0): "Keypad 0", UInt32(kVK_ANSI_Keypad1): "Keypad 1",
        UInt32(kVK_ANSI_Keypad2): "Keypad 2", UInt32(kVK_ANSI_Keypad3): "Keypad 3",
        UInt32(kVK_ANSI_Keypad4): "Keypad 4", UInt32(kVK_ANSI_Keypad5): "Keypad 5",
        UInt32(kVK_ANSI_Keypad6): "Keypad 6", UInt32(kVK_ANSI_Keypad7): "Keypad 7",
        UInt32(kVK_ANSI_Keypad8): "Keypad 8", UInt32(kVK_ANSI_Keypad9): "Keypad 9",
        UInt32(kVK_ANSI_KeypadEnter): "Keypad Enter", UInt32(kVK_ANSI_KeypadClear): "Keypad Clear"
    ]
}

// MARK: - Folders

struct FoldersPreferencesView: View {

    @State private var defaultFolder = Preferences.shared.defaultSaveFolder
    @State private var favorites = Preferences.shared.favoriteFolders
    @State private var pattern = Preferences.shared.filenamePattern
    @State private var selectedFavorite: URL?

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(defaultFolder.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose...") { chooseDefaultFolder() }
                }
            } header: {
                Text("Default Folder")
            }

            Section {
                List(favorites, id: \.self, selection: $selectedFavorite) { folder in
                    Text(folder.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .tag(folder)
                }
                .frame(minHeight: 90)

                HStack {
                    Button("Add...") { addFavorite() }
                    Button("Remove") { removeSelectedFavorite() }
                        .disabled(selectedFavorite == nil)
                    Spacer()
                    Button("Move Up") { move(-1) }
                        .disabled(!canMoveSelected(-1))
                    Button("Move Down") { move(1) }
                        .disabled(!canMoveSelected(1))
                }
            } header: {
                Text("Favorite Folders")
            }

            Section {
                Picker("Style", selection: presetBinding) {
                    ForEach(FilenamePattern.presets, id: \.pattern) { preset in
                        Text(preset.label).tag(preset.pattern)
                    }
                    Divider()
                    Text("Custom").tag("")
                }
                TextField("Pattern", text: $pattern)
                    .onChange(of: pattern) { _, newValue in
                        Preferences.shared.filenamePattern = newValue
                    }
                Text("Next file: \(previewName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(FilenamePattern.tokenLegend)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if pattern.contains("{n}") || pattern.contains("{counter}") {
                    HStack {
                        Text("Counter is at \(FilenamePattern.peekCounter())")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset Counter to 1") {
                            FilenamePattern.resetCounter()
                            counterTick += 1
                        }
                    }
                }
            } header: {
                Text("Filename")
            }
        }
        .padding(20)
    }

    /// Bumped to re-render the counter line after a reset.
    @State private var counterTick = 0

    /// Empty tag means "Custom": the field keeps whatever the user typed.
    private var presetBinding: Binding<String> {
        Binding(
            get: {
                FilenamePattern.presets.contains { $0.pattern == pattern } ? pattern : ""
            },
            set: { newValue in
                if !newValue.isEmpty { pattern = newValue }
            })
    }

    private var previewName: String {
        _ = counterTick
        let effective = pattern.isEmpty ? Preferences.defaultFilenamePattern : pattern
        // Real counter and real folder, but nothing consumed: this is exactly
        // the name the next Done would produce.
        return FilenamePattern.expand(effective,
                                      date: Date(),
                                      pixelSize: CGSize(width: 1920, height: 1080),
                                      folder: defaultFolder,
                                      consumeCounter: false)
    }

    private func chooseDefaultFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = defaultFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        defaultFolder = url
        Preferences.shared.defaultSaveFolder = url
    }

    private func addFavorite() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !favorites.contains(url) else { return }
        favorites.append(url)
        Preferences.shared.favoriteFolders = favorites
    }

    private func removeSelectedFavorite() {
        guard let selected = selectedFavorite else { return }
        favorites.removeAll { $0 == selected }
        Preferences.shared.favoriteFolders = favorites
        selectedFavorite = nil
    }

    private func canMoveSelected(_ delta: Int) -> Bool {
        guard let selected = selectedFavorite, let index = favorites.firstIndex(of: selected) else { return false }
        let target = index + delta
        return target >= 0 && target < favorites.count
    }

    private func move(_ delta: Int) {
        guard let selected = selectedFavorite, let index = favorites.firstIndex(of: selected) else { return }
        let target = index + delta
        guard target >= 0 && target < favorites.count else { return }
        favorites.swapAt(index, target)
        Preferences.shared.favoriteFolders = favorites
    }
}

// MARK: - Defaults

struct DefaultsPreferencesView: View {

    @State private var strokeColor = Preferences.shared.defaultStrokeColor.swiftUIColor
    @State private var badgeColor = Preferences.shared.defaultBadgeColor.swiftUIColor
    @State private var strokeWidth = Double(Preferences.shared.defaultStrokeWidth)
    @State private var fontSize = Double(Preferences.shared.defaultFontSize)
    @State private var badgeRadius = Double(Preferences.shared.defaultBadgeRadius)

    var body: some View {
        Form {
            ColorPicker("Stroke color", selection: $strokeColor, supportsOpacity: false)
                .onChange(of: strokeColor) { _, newValue in
                    Preferences.shared.defaultStrokeColor = CodableColor(color: newValue)
                }
            ColorPicker("Badge color", selection: $badgeColor, supportsOpacity: false)
                .onChange(of: badgeColor) { _, newValue in
                    Preferences.shared.defaultBadgeColor = CodableColor(color: newValue)
                }

            LabeledContent("Stroke width: \(Int(strokeWidth))pt") {
                Slider(value: $strokeWidth, in: 1...20, step: 1)
                    .onChange(of: strokeWidth) { _, newValue in
                        Preferences.shared.defaultStrokeWidth = CGFloat(newValue)
                    }
            }
            LabeledContent("Font size: \(Int(fontSize))pt") {
                Slider(value: $fontSize, in: 8...48, step: 1)
                    .onChange(of: fontSize) { _, newValue in
                        Preferences.shared.defaultFontSize = CGFloat(newValue)
                    }
            }
            LabeledContent("Badge radius: \(Int(badgeRadius))pt") {
                Slider(value: $badgeRadius, in: 6...48, step: 1)
                    .onChange(of: badgeRadius) { _, newValue in
                        Preferences.shared.defaultBadgeRadius = CGFloat(newValue)
                    }
            }
        }
        .padding(20)
    }
}

// MARK: - CodableColor <-> SwiftUI Color

extension CodableColor {
    var swiftUIColor: Color {
        Color(red: Double(red), green: Double(green), blue: Double(blue), opacity: Double(alpha))
    }

    /// Round-trips through NSColor's sRGB representation so the stored
    /// components line up with what `cgColor` (also sRGB) expects.
    init(color: Color) {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        self.init(red: resolved.redComponent,
                 green: resolved.greenComponent,
                 blue: resolved.blueComponent,
                 alpha: resolved.alphaComponent)
    }
}
