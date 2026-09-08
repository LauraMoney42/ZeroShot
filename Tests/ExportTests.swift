//
//  ExportTests.swift
//  ZeroShotTests
//
//  Covers FilenamePattern expansion, the non-overwrite suffixing in
//  Exporter, pngData's output size (native and cropped), and that
//  copyToClipboard leaves a PNG type behind without touching the user's
//  real pasteboard.
//

import AppKit
import CoreGraphics
import ImageIO
import XCTest
@testable import ZeroShot

final class ExportTests: XCTestCase {

    private var suiteDefaults: UserDefaults!
    private let suiteName = "us.kindcode.zeroshot.ExportTests"

    override func setUp() {
        super.setUp()
        suiteDefaults = UserDefaults(suiteName: suiteName)
        suiteDefaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        suiteDefaults.removePersistentDomain(forName: suiteName)
        suiteDefaults = nil
        super.tearDown()
    }

    /// A fixed instant, injected instead of `Date()`, so {date}/{time}/
    /// {datetime} expand to a known string regardless of when the test runs.
    private func fixedDate(day: Int = 7) -> Date {
        var components = DateComponents()
        components.year = 2024
        components.month = 3
        components.day = day
        components.hour = 9
        components.minute = 5
        components.second = 3
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    // MARK: FilenamePattern

    func testExpandsDateTimeAndDatetimeTokens() {
        let date = fixedDate()

        let name = FilenamePattern.expand("ZeroShot_{date}_{time}",
                                          date: date,
                                          pixelSize: CGSize(width: 100, height: 50),
                                          defaults: suiteDefaults)
        XCTAssertEqual(name, "ZeroShot_2024-03-07_09-05-03.png")

        let datetimeName = FilenamePattern.expand("Shot-{datetime}",
                                                   date: date,
                                                   pixelSize: CGSize(width: 100, height: 50),
                                                   defaults: suiteDefaults)
        XCTAssertEqual(datetimeName, "Shot-2024-03-07_09-05-03.png")
    }

    func testExpandsWidthAndHeightTokens() {
        let name = FilenamePattern.expand("Shot_{width}x{height}",
                                          date: fixedDate(),
                                          pixelSize: CGSize(width: 1920, height: 1080),
                                          defaults: suiteDefaults)
        XCTAssertEqual(name, "Shot_1920x1080.png")
    }

    func testAlwaysEndsInPNGEvenWithoutExtensionInThePattern() {
        let name = FilenamePattern.expand("NoExtensionHere",
                                          date: fixedDate(),
                                          pixelSize: CGSize(width: 10, height: 10),
                                          defaults: suiteDefaults)
        XCTAssertEqual(name, "NoExtensionHere.png")
    }

    func testCounterKeepsGrowingAcrossDaysAndSkipsExistingFiles() throws {
        let suiteDefaults = try XCTUnwrap(UserDefaults(suiteName: "ZeroShotTests.counter.\(UUID().uuidString)"))
        let day1 = Date(timeIntervalSince1970: 1_700_000_000)
        let day2 = day1.addingTimeInterval(86_400 * 3)

        XCTAssertEqual(FilenamePattern.expand("Shot{n}", date: day1, pixelSize: .zero, defaults: suiteDefaults), "Shot1.png")
        XCTAssertEqual(FilenamePattern.expand("Shot{counter}", date: day1, pixelSize: .zero, defaults: suiteDefaults), "Shot2.png")
        XCTAssertEqual(FilenamePattern.expand("Shot{n}", date: day2, pixelSize: .zero, defaults: suiteDefaults), "Shot3.png",
                       "the counter must not reset on a new day")

        // A preview must not consume a number.
        XCTAssertEqual(FilenamePattern.expand("Shot{n}", pixelSize: .zero, defaults: suiteDefaults, consumeCounter: false), "Shot4.png")
        XCTAssertEqual(FilenamePattern.peekCounter(defaults: suiteDefaults), 4)

        // Existing files in the folder are skipped.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zs-counter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appendingPathComponent("Shot4.png"))
        try Data().write(to: folder.appendingPathComponent("Shot5.png"))
        XCTAssertEqual(FilenamePattern.expand("Shot{n}", pixelSize: .zero, defaults: suiteDefaults, folder: folder), "Shot6.png")

        FilenamePattern.resetCounter(defaults: suiteDefaults)
        XCTAssertEqual(FilenamePattern.expand("Shot{n}", pixelSize: .zero, defaults: suiteDefaults), "Shot1.png")
    }

    func testDatePartTokensAllowSeparatorFreeNames() {
        let date = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13:20 UTC
        let name = FilenamePattern.expand("Screenshot {year}{month}{day} {hour}{minute}{second}", date: date, pixelSize: .zero)
        XCTAssertFalse(name.contains("_"))
        XCTAssertFalse(name.contains("{"))
        XCTAssertTrue(name.hasPrefix("Screenshot 2023"))
        XCTAssertEqual(name.count, "Screenshot 20231114 221320.png".count)
    }

    func testSanitizesIllegalFilenameCharacters() {
        let name = FilenamePattern.expand("Bad:Name/With*Chars?\"<>|",
                                          date: fixedDate(),
                                          pixelSize: .zero,
                                          defaults: suiteDefaults)
        for illegal in ["/", ":", "*", "?", "\"", "<", ">", "|"] {
            XCTAssertFalse(name.contains(illegal), "expected \(illegal) to be sanitized out of \(name)")
        }
        XCTAssertTrue(name.hasSuffix(".png"))
    }

    // MARK: Non-overwrite suffixing

    func testUniqueURLAppendsIncrementingSuffixWhenTheFileAlreadyExists() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let first = Exporter.uniqueURL(for: "Shot.png", in: folder)
        XCTAssertEqual(first.lastPathComponent, "Shot.png")
        try Data().write(to: first)

        let second = Exporter.uniqueURL(for: "Shot.png", in: folder)
        XCTAssertEqual(second.lastPathComponent, "Shot-2.png")
        try Data().write(to: second)

        let third = Exporter.uniqueURL(for: "Shot.png", in: folder)
        XCTAssertEqual(third.lastPathComponent, "Shot-3.png")
    }

    func testSaveWritesThePNGAndAvoidsOverwritingOnRepeatedSaves() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let preferences = Preferences(defaults: suiteDefaults)
        preferences.filenamePattern = "FixedName"

        let document1 = EditorDocument(image: TestSupport.makeImage(width: 40, height: 40))
        let url1 = try Exporter.save(document: document1, to: folder, preferences: preferences)
        XCTAssertEqual(url1.lastPathComponent, "FixedName.png")
        XCTAssertFalse(document1.hasUnsavedChanges, "save() must call markSaved()")

        let document2 = EditorDocument(image: TestSupport.makeImage(width: 40, height: 40))
        let url2 = try Exporter.save(document: document2, to: folder, preferences: preferences)
        XCTAssertEqual(url2.lastPathComponent, "FixedName-2.png")
    }

    // MARK: pngData size

    func testPNGDataDecodesToNativePixelSizeWithoutCrop() throws {
        let document = EditorDocument(image: TestSupport.makeImage(width: 220, height: 130))
        let data = try XCTUnwrap(Exporter.pngData(for: document))
        XCTAssertEqual(try decodedPixelSize(from: data), CGSize(width: 220, height: 130))
    }

    func testPNGDataDecodesToCropSizeWhenCropped() throws {
        let document = EditorDocument(image: TestSupport.makeImage(width: 220, height: 130))
        document.setCrop(CGRect(x: 10, y: 10, width: 90, height: 60))
        let data = try XCTUnwrap(Exporter.pngData(for: document))
        XCTAssertEqual(try decodedPixelSize(from: data), CGSize(width: 90, height: 60))
    }

    private func decodedPixelSize(from data: Data) throws -> CGSize {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil),
                                   "pngData did not produce decodable PNG bytes")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return CGSize(width: image.width, height: image.height)
    }

    // MARK: Clipboard

    func testCopyToClipboardLeavesPNGTypeOnAPrivatePasteboard() throws {
        // A private, named pasteboard so the test never touches the user's
        // real clipboard.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("us.kindcode.zeroshot.ExportTestsPasteboard"))
        pasteboard.clearContents()

        let document = EditorDocument(image: TestSupport.makeImage(width: 30, height: 30))
        let wrote = Exporter.copyToClipboard(document: document, pasteboard: pasteboard)

        XCTAssertTrue(wrote)
        XCTAssertTrue(pasteboard.types?.contains(.png) ?? false, "expected a public.png entry on the pasteboard")
        XCTAssertNotNil(pasteboard.data(forType: .png))
    }

    // MARK: Helpers

    private func makeTempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZeroShotExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
