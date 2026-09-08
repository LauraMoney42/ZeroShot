//
//  FilenamePattern.swift
//  ZeroShot
//
//  Expands a user-editable pattern such as "Screenshot{n}" or
//  "Screenshot {date} {time}" into a concrete filename, always ending in
//  ".png". Tokens are replaced only when present, so a pattern without a
//  counter never touches the counter store.
//
//  COUNTER SEMANTICS: {counter} (alias {n}) is a single number that keeps
//  growing across days and launches, like Greenshot's ${NUM}. When the target
//  folder is known it also skips over numbers whose file already exists, so
//  "Screenshot1, 2, 3" stays gap-free even if the user resets the counter or
//  moves files in by hand.
//

import Foundation
import CoreGraphics

enum FilenamePattern {

    /// Ready-made patterns offered in Preferences. The first is the default.
    static let presets: [(label: String, pattern: String)] = [
        ("ZeroShot_2026-09-04_14-05-33", "ZeroShot_{date}_{time}"),
        ("Screenshot1, Screenshot2, ...", "Screenshot{n}"),
        ("Screenshot 2026-09-04 14-05-33", "Screenshot {date} {time}"),
        ("Screenshot 20260904 140533", "Screenshot {year}{month}{day} {hour}{minute}{second}"),
        ("Screenshot 2026-09-04 at 14.05.33", "Screenshot {date} at {hour}.{minute}.{second}")
    ]

    /// Every token, for the legend in Preferences.
    static let tokenLegend = "{n} counter, {date} 2026-09-04, {time} 14-05-33, {datetime}, {year} {month} {day} {hour} {minute} {second}, {width} {height}"

    /// Expands `pattern` into a sanitized filename ending in ".png".
    ///
    /// - Parameters:
    ///   - date: injectable so tests get deterministic date tokens.
    ///   - pixelSize: backs {width} and {height}.
    ///   - defaults: backs the counter. Tests pass an isolated suite so they do
    ///     not perturb (or race with) the user's real counter.
    ///   - folder: when given, the counter skips numbers already used by a
    ///     file in that folder.
    ///   - consumeCounter: false for previews, which must not burn a number.
    static func expand(_ pattern: String,
                        date: Date = Date(),
                        pixelSize: CGSize,
                        defaults: UserDefaults = .standard,
                        folder: URL? = nil,
                        consumeCounter: Bool = true) -> String {
        var result = pattern.isEmpty ? Preferences.defaultFilenamePattern : pattern

        let dateTokens: [(String, String)] = [
            ("{datetime}", "yyyy-MM-dd_HH-mm-ss"),
            ("{date}", "yyyy-MM-dd"),
            ("{time}", "HH-mm-ss"),
            ("{year}", "yyyy"),
            ("{month}", "MM"),
            ("{day}", "dd"),
            ("{hour}", "HH"),
            ("{minute}", "mm"),
            ("{second}", "ss")
        ]
        for (token, format) in dateTokens where result.contains(token) {
            result = result.replacingOccurrences(of: token, with: formatter(format).string(from: date))
        }
        if result.contains("{width}") {
            result = result.replacingOccurrences(of: "{width}",
                                                  with: String(Int(pixelSize.width.rounded())))
        }
        if result.contains("{height}") {
            result = result.replacingOccurrences(of: "{height}",
                                                  with: String(Int(pixelSize.height.rounded())))
        }

        // {n} is the short spelling of {counter}; normalize before expanding.
        result = result.replacingOccurrences(of: "{n}", with: "{counter}")
        guard result.contains("{counter}") else {
            return finish(result)
        }

        var number = defaults.integer(forKey: counterValueKey) + 1
        var name = finish(result.replacingOccurrences(of: "{counter}", with: String(number)))
        if let folder {
            // Walk past files that already exist so the sequence stays gap-free
            // and never relies on the "-2" suffix the exporter adds as a last
            // resort. Bounded so a pathological folder cannot spin forever.
            var attempts = 0
            while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path),
                  attempts < 100_000 {
                number += 1
                attempts += 1
                name = finish(result.replacingOccurrences(of: "{counter}", with: String(number)))
            }
        }
        if consumeCounter {
            defaults.set(number, forKey: counterValueKey)
        }
        return name
    }

    /// Puts the counter back so the next expansion yields 1 (or the first
    /// free number in the folder).
    static func resetCounter(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: counterValueKey)
    }

    /// The number the next expansion would produce, for the Preferences UI.
    static func peekCounter(defaults: UserDefaults = .standard) -> Int {
        defaults.integer(forKey: counterValueKey) + 1
    }

    private static func finish(_ name: String) -> String {
        let sanitized = sanitize(name)
        return sanitized.hasSuffix(".png") ? sanitized : sanitized + ".png"
    }

    private static func formatter(_ format: String) -> DateFormatter {
        // en_US_POSIX plus a fixed format string keeps this locale independent;
        // the machine's own time zone is used deliberately so the stamp is the
        // time the user sees on the clock.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    // MARK: Counter store

    private static let counterValueKey = "filenamePatternCounterValue"

    // MARK: Sanitizing

    /// Characters illegal, or merely awkward, in a filename: the path
    /// separators (current and legacy Mac Classic), shell/URL metacharacters,
    /// and control characters.
    private static let illegalCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        .union(.controlCharacters)

    static func sanitize(_ name: String) -> String {
        let cleaned = name.unicodeScalars
            .map { illegalCharacters.contains($0) ? "-" : String($0) }
            .joined()
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "ZeroShot" : trimmed
    }
}
