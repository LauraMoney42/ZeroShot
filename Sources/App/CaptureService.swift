//
//  CaptureService.swift
//  ZeroShot
//
//  Region and Window capture shell out to /usr/sbin/screencapture: Apple's
//  own crosshair picker for free, with Space toggling window mode, Esc
//  cancelling, and Retina scaling handled automatically. Full Screen capture
//  is Core Graphics + ScreenCaptureKit instead (see captureFullScreen), since
//  it needs to target one specific display rather than whatever the picker
//  is pointed at.
//
//  RETINA / COORDINATE NOTE
//  ------------------------
//  screencapture writes the native pixel image: a 2x display produces a PNG
//  whose pixel dimensions are twice the point dimensions. There is no reliable
//  way to recover "points" from the file alone, and we do not try. Instead the
//  whole editor works in PIXEL space with a TOP-LEFT origin (document space),
//  and the canvas view divides by its own display scale when it draws. So a
//  capture is handed on as a CGImage plus its exact pixel size, nothing else.
//

import Foundation
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

enum CaptureMode: Equatable {
    /// Interactive crosshair. Space switches to window mode inside the picker.
    case region
    /// Interactive, starting in window mode.
    case window
    /// Non-interactive grab of a single display: whichever one currently has
    /// the mouse pointer. Needs Screen Recording permission. Captured via
    /// ScreenCaptureKit rather than `screencapture` (see
    /// `CaptureService.captureFullScreen`), so `arguments` is unused for this
    /// case.
    case fullScreen

    var arguments: [String] {
        switch self {
        case .region:     return ["-i"]
        case .window:     return ["-i", "-W"]
        case .fullScreen: return []
        }
    }
}

/// What a successful capture produces. The CGImage and its pixel size are the
/// only things the editor needs; the URL is kept so the temp file can be
/// revealed, re-read or cleaned up.
struct CaptureResult {
    let image: CGImage
    let pixelSize: CGSize
    let fileURL: URL
}

enum CaptureService {

    static let executablePath = "/usr/sbin/screencapture"

    /// Runs screencapture and loads the result.
    ///
    /// Returns `nil` when the user cancelled (Esc leaves no file behind), when
    /// screencapture is missing, or when the PNG cannot be decoded. Cancellation
    /// and permission denial look the same from here; the caller should simply
    /// do nothing.
    ///
    /// - Parameter delay: seconds to wait before grabbing, passed as `-T`
    ///   for `.region`/`.window`, or slept through directly for `.fullScreen`.
    static func capture(mode: CaptureMode, delay: Int = 0) async -> CaptureResult? {
        if mode == .fullScreen {
            return await captureFullScreen(delay: delay)
        }

        let url = makeTemporaryURL()

        var arguments = ["-x", "-t", "png"]          // -x: no camera shutter sound
        arguments += mode.arguments
        if delay > 0 { arguments += ["-T", String(delay)] }
        arguments.append(url.path)

        let status = await run(arguments: arguments)

        // A non-zero exit, or no file at all, means "nothing to edit".
        guard status == 0 else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        guard fileHasContent(at: url) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        guard let image = loadCGImage(at: url) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }

        return CaptureResult(image: image,
                             pixelSize: CGSize(width: image.width, height: image.height),
                             fileURL: url)
    }

    /// Grabs just the display holding the mouse pointer, rather than
    /// shelling out to `screencapture` with no `-D`: that flag's numbering is
    /// not reliably documented across macOS versions, while resolving "the
    /// screen the user is on" ourselves from the live mouse position is
    /// unambiguous. Uses ScreenCaptureKit (`CGDisplayCreateImage`, the older
    /// one-line way to do this, is unavailable as of the macOS 26 SDK: Apple
    /// requires ScreenCaptureKit now). Still needs Screen Recording
    /// permission, exactly like the `screencapture` path does.
    private static func captureFullScreen(delay: Int) async -> CaptureResult? {
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
        }

        guard let image = await captureImage(ofDisplay: currentDisplayID()) else { return nil }

        let url = makeTemporaryURL()
        guard writePNG(image, to: url) else { return nil }

        return CaptureResult(image: image,
                             pixelSize: CGSize(width: image.width, height: image.height),
                             fileURL: url)
    }

    /// One-shot screenshot of a single display via `SCScreenshotManager`,
    /// ScreenCaptureKit's non-streaming capture API (macOS 14+). `nil` on any
    /// failure: permission denial, a display that has gone away between
    /// `currentDisplayID()` and here, or content enumeration failing.
    private static func captureImage(ofDisplay displayID: CGDirectDisplayID) async -> CGImage? {
        guard let content = try? await SCShareableContent.current,
              let display = content.displays.first(where: { $0.displayID == displayID })
                ?? content.displays.first
        else { return nil }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        // Native pixel dimensions, not points, so a Retina capture comes out
        // full resolution -- consistent with the RETINA / COORDINATE NOTE
        // above and with what `screencapture` itself produces.
        configuration.width = CGDisplayPixelsWide(display.displayID)
        configuration.height = CGDisplayPixelsHigh(display.displayID)
        // Matches the plain `screencapture` path, which also omits the
        // cursor unless `-C` is passed (it never is here).
        configuration.showsCursor = false

        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// The display whose bounds contain the current mouse pointer, falling
    /// back to the main display if the pointer is (improbably) outside every
    /// screen.
    static func currentDisplayID() -> CGDirectDisplayID {
        let point = CGEvent(source: nil)?.location ?? .zero
        return displayID(containing: point, in: activeDisplayBounds()) ?? CGMainDisplayID()
    }

    /// Every active display's id and bounds, in Quartz global display space
    /// (same space `CGEvent.location` reports in).
    private static func activeDisplayBounds() -> [CGDirectDisplayID: CGRect] {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(displayIDs.count), &displayIDs, &displayCount) == .success else {
            return [:]
        }
        var bounds: [CGDirectDisplayID: CGRect] = [:]
        for id in displayIDs.prefix(Int(displayCount)) {
            bounds[id] = CGDisplayBounds(id)
        }
        return bounds
    }

    /// Pure geometry, kept separate from the live Core Graphics calls above so
    /// it is unit-testable without a real display list: which display (if
    /// any) contains `point`.
    static func displayID(containing point: CGPoint, in bounds: [CGDirectDisplayID: CGRect]) -> CGDirectDisplayID? {
        for (id, rect) in bounds where rect.contains(point) {
            return id
        }
        return nil
    }

    /// Encodes `image` as PNG straight to `url`. Mirrors `Exporter`'s PNG
    /// encoding but writes directly to a file instead of building `Data`,
    /// since a full-screen capture has nowhere else to go through first.
    private static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { return false }

        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    // MARK: - Pieces (kept internal so tests can exercise them)

    static func makeTemporaryURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZeroShot", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("capture-\(UUID().uuidString).png")
    }

    static func fileHasContent(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return false }
        return size > 0
    }

    /// Decodes the PNG at its native pixel size. No scaling, no color
    /// conversion, so what we edit is what Apple captured.
    static func loadCGImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceShouldCache: true]
        return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
    }

    /// Runs the tool off the main thread and resumes when it exits.
    private static func run(arguments: [String]) async -> Int32 {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: -1)
            }
        }
    }
}
