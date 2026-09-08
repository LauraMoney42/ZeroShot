//
//  CaptureService.swift
//  ZeroShot
//
//  Wraps /usr/sbin/screencapture. Shelling out buys us Apple's own crosshair
//  picker for free: Space toggles window mode, Esc cancels, multiple displays
//  and Retina scaling all just work.
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
import UniformTypeIdentifiers

enum CaptureMode {
    /// Interactive crosshair. Space switches to window mode inside the picker.
    case region
    /// Interactive, starting in window mode.
    case window
    /// Non-interactive grab of the screen. Needs Screen Recording permission.
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
    /// - Parameter delay: seconds to wait before grabbing, passed as `-T`.
    static func capture(mode: CaptureMode, delay: Int = 0) async -> CaptureResult? {
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
