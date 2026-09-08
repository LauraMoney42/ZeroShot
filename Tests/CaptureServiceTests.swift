//
//  CaptureServiceTests.swift
//  ZeroShotTests
//
//  Everything here is non-interactive. The actual `capture(mode:)` call is NOT
//  exercised: region and window modes need a human at the crosshair, and full
//  screen mode would raise a Screen Recording permission dialog for the test
//  host. What is tested is the plumbing either side of the subprocess, plus
//  the full-screen display-selection geometry, which is pure and does not
//  touch Core Graphics' live display list.
//

import XCTest
import CoreGraphics
@testable import ZeroShot

final class CaptureServiceTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZeroShotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testScreencaptureExists() {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: CaptureService.executablePath),
                      "the app shells out to \(CaptureService.executablePath)")
    }

    func testModeArguments() {
        XCTAssertEqual(CaptureMode.region.arguments, ["-i"])
        XCTAssertEqual(CaptureMode.window.arguments, ["-i", "-W"])
        // Unused in practice (full screen bypasses the subprocess entirely,
        // see testDisplayIDContainingPoint* below) but still a harmless,
        // exhaustively-checked value.
        XCTAssertEqual(CaptureMode.fullScreen.arguments, [])
    }

    func testDisplayIDContainingPointPicksTheMatchingDisplay() {
        // Two side-by-side displays, as in a laptop-plus-external setup:
        // built-in at the origin, external starting where it ends.
        let bounds: [CGDirectDisplayID: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 1440, height: 900),
            2: CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        ]

        XCTAssertEqual(CaptureService.displayID(containing: CGPoint(x: 100, y: 100), in: bounds), 1)
        XCTAssertEqual(CaptureService.displayID(containing: CGPoint(x: 2000, y: 500), in: bounds), 2)
        // Right on the seam: CGRect.contains is min-inclusive, so this pixel
        // column belongs to the display starting there, not the one ending
        // there.
        XCTAssertEqual(CaptureService.displayID(containing: CGPoint(x: 1440, y: 0), in: bounds), 2)
    }

    func testDisplayIDContainingPointReturnsNilWhenPointerIsOffscreen() {
        let bounds: [CGDirectDisplayID: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 1440, height: 900)
        ]
        XCTAssertNil(CaptureService.displayID(containing: CGPoint(x: -50, y: -50), in: bounds))
        XCTAssertNil(CaptureService.displayID(containing: CGPoint(x: 5000, y: 5000), in: bounds))
    }

    func testDisplayIDContainingPointWithNoDisplaysReturnsNil() {
        XCTAssertNil(CaptureService.displayID(containing: .zero, in: [:]))
    }

    func testTemporaryURLIsUniqueAndInAWritableDirectory() throws {
        let first = CaptureService.makeTemporaryURL()
        let second = CaptureService.makeTemporaryURL()
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.pathExtension, "png")

        let directory = first.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertTrue(FileManager.default.isWritableFile(atPath: directory.path))
    }

    func testMissingOrEmptyFileIsTreatedAsCancelled() throws {
        // Esc in Apple's picker leaves no file at all.
        let missing = scratch.appendingPathComponent("nothing-here.png")
        XCTAssertFalse(CaptureService.fileHasContent(at: missing))
        XCTAssertNil(CaptureService.loadCGImage(at: missing))

        // A zero-byte file must not be mistaken for a capture either.
        let empty = scratch.appendingPathComponent("empty.png")
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        XCTAssertFalse(CaptureService.fileHasContent(at: empty))
    }

    func testLoadCGImageKeepsNativePixelDimensions() throws {
        // Stand-in for a 2x capture: the loader must not rescale anything.
        let source = TestSupport.makeImage(width: 640, height: 400)
        let url = scratch.appendingPathComponent("capture.png")
        try TestSupport.writePNG(source, to: url)

        XCTAssertTrue(CaptureService.fileHasContent(at: url))
        let loaded = try XCTUnwrap(CaptureService.loadCGImage(at: url))
        XCTAssertEqual(loaded.width, 640)
        XCTAssertEqual(loaded.height, 400)

        // And it drops straight into a document at that pixel size.
        let document = EditorDocument(image: loaded, sourceURL: url)
        XCTAssertEqual(document.pixelSize, CGSize(width: 640, height: 400))
        XCTAssertEqual(document.sourceURL, url)
    }
}
