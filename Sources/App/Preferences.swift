//
//  Preferences.swift
//  ZeroShot
//
//  UserDefaults-backed settings. No UI yet: milestone 5 adds the window and
//  binds it straight to these properties.
//
//  Colors are stored as JSON blobs of `CodableColor` so they survive round
//  trips without depending on NSColor archiving. Folder URLs are stored as
//  plain paths; when the app is later sandboxed these become security-scoped
//  bookmarks, which is why access goes through accessors rather than
//  @AppStorage.
//

import Foundation
import CoreGraphics

final class Preferences {

    static let shared = Preferences()

    enum Key {
        static let defaultSaveFolder = "defaultSaveFolder"
        static let favoriteFolders = "favoriteFolders"
        static let filenamePattern = "filenamePattern"
        static let copyToClipboard = "copyToClipboard"
        static let copyOnCapture = "copyOnCapture"
        static let saveToFolder = "saveToFolder"
        static let defaultStrokeColor = "defaultStrokeColor"
        static let defaultBadgeColor = "defaultBadgeColor"
        static let defaultStrokeWidth = "defaultStrokeWidth"
        static let defaultFontSize = "defaultFontSize"
        static let defaultBadgeRadius = "defaultBadgeRadius"
        static let playSound = "playSound"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        registerDefaults()
    }

    /// Seeds the values that must be true/non-zero when nothing is stored yet.
    func registerDefaults() {
        defaults.register(defaults: [
            Key.filenamePattern: Preferences.defaultFilenamePattern,
            Key.copyToClipboard: true,
            Key.copyOnCapture: true,
            Key.saveToFolder: true,
            Key.defaultStrokeWidth: 3.0,
            Key.defaultFontSize: 28.0,
            Key.defaultBadgeRadius: 26.0,
            Key.playSound: false
        ])
    }

    static let defaultFilenamePattern = "ZeroShot_{date}_{time}"

    /// ~/Desktop, or the home directory if Desktop somehow does not exist.
    static var desktopURL: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    // MARK: Folders

    var defaultSaveFolder: URL {
        get {
            guard let path = defaults.string(forKey: Key.defaultSaveFolder), !path.isEmpty else {
                return Preferences.desktopURL
            }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        set { defaults.set(newValue.path, forKey: Key.defaultSaveFolder) }
    }

    var favoriteFolders: [URL] {
        get {
            let paths = defaults.stringArray(forKey: Key.favoriteFolders) ?? []
            return paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
        set { defaults.set(newValue.map(\.path), forKey: Key.favoriteFolders) }
    }

    // MARK: Naming and destinations

    var filenamePattern: String {
        get { defaults.string(forKey: Key.filenamePattern) ?? Preferences.defaultFilenamePattern }
        set { defaults.set(newValue, forKey: Key.filenamePattern) }
    }

    var copyToClipboard: Bool {
        get { defaults.bool(forKey: Key.copyToClipboard) }
        set { defaults.set(newValue, forKey: Key.copyToClipboard) }
    }

    /// Copies the raw capture to the clipboard the instant it is taken, before
    /// any editing. Independent of `copyToClipboard`, which governs what Done
    /// copies (the annotated result) when the user finishes editing.
    var copyOnCapture: Bool {
        get { defaults.bool(forKey: Key.copyOnCapture) }
        set { defaults.set(newValue, forKey: Key.copyOnCapture) }
    }

    var saveToFolder: Bool {
        get { defaults.bool(forKey: Key.saveToFolder) }
        set { defaults.set(newValue, forKey: Key.saveToFolder) }
    }

    var playSound: Bool {
        get { defaults.bool(forKey: Key.playSound) }
        set { defaults.set(newValue, forKey: Key.playSound) }
    }

    // MARK: Drawing defaults

    var defaultStrokeColor: CodableColor {
        get { color(forKey: Key.defaultStrokeColor) ?? .red }
        set { setColor(newValue, forKey: Key.defaultStrokeColor) }
    }

    var defaultBadgeColor: CodableColor {
        get { color(forKey: Key.defaultBadgeColor) ?? .red }
        set { setColor(newValue, forKey: Key.defaultBadgeColor) }
    }

    var defaultStrokeWidth: CGFloat {
        get { CGFloat(defaults.double(forKey: Key.defaultStrokeWidth)) }
        set { defaults.set(Double(newValue), forKey: Key.defaultStrokeWidth) }
    }

    var defaultFontSize: CGFloat {
        get { CGFloat(defaults.double(forKey: Key.defaultFontSize)) }
        set { defaults.set(Double(newValue), forKey: Key.defaultFontSize) }
    }

    var defaultBadgeRadius: CGFloat {
        get { CGFloat(defaults.double(forKey: Key.defaultBadgeRadius)) }
        set { defaults.set(Double(newValue), forKey: Key.defaultBadgeRadius) }
    }

    /// Style for a newly drawn shape, text run or freehand stroke.
    func defaultAnnotationStyle() -> AnnotationStyle {
        AnnotationStyle(strokeColor: defaultStrokeColor,
                        fillColor: nil,
                        strokeWidth: defaultStrokeWidth,
                        fontSize: defaultFontSize,
                        badgeRadius: defaultBadgeRadius)
    }

    /// Style for a newly dropped number badge, which has its own color setting.
    func defaultBadgeStyle() -> AnnotationStyle {
        AnnotationStyle(strokeColor: defaultBadgeColor,
                        fillColor: nil,
                        strokeWidth: defaultStrokeWidth,
                        fontSize: defaultFontSize,
                        badgeRadius: defaultBadgeRadius)
    }

    // MARK: Color storage

    private func color(forKey key: String) -> CodableColor? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(CodableColor.self, from: data)
    }

    private func setColor(_ color: CodableColor, forKey key: String) {
        guard let data = try? JSONEncoder().encode(color) else { return }
        defaults.set(data, forKey: key)
    }
}
