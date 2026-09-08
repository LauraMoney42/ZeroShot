//
//  Exporter.swift
//  ZeroShot
//
//  Turns a flattened EditorDocument into PNG bytes and gets them onto the
//  clipboard or onto disk. `Renderer.renderImage` already does the flattening
//  (native pixel size, or the crop size when cropped); this file only owns
//  encoding and the filesystem/pasteboard side effects.
//

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ExportError: LocalizedError {
    case renderFailed
    case pngEncodingFailed
    case writeFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .renderFailed:
            return "Could not render the capture."
        case .pngEncodingFailed:
            return "Could not encode the image as PNG."
        case .writeFailed(let underlying):
            return "Could not write the file: \(underlying.localizedDescription)"
        }
    }
}

enum Exporter {

    // MARK: PNG data

    /// Flattened PNG bytes at the document's native pixel size, or the crop
    /// size when the document has a crop set. `nil` only if rendering or
    /// encoding fails.
    static func pngData(for document: EditorDocument) -> Data? {
        guard let image = Renderer.renderImage(document: document) else { return nil }
        return pngData(from: image)
    }

    private static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    // MARK: Clipboard

    /// Writes both PNG and TIFF representations so apps that prefer either
    /// format (browsers tend to want PNG, Pages/Preview-style apps TIFF)
    /// accept the paste. `pasteboard` defaults to the general pasteboard;
    /// tests pass a private one so they do not clobber the user's clipboard.
    @discardableResult
    static func copyToClipboard(document: EditorDocument, pasteboard: NSPasteboard = .general) -> Bool {
        guard let cgImage = Renderer.renderImage(document: document) else { return false }
        guard let png = pngData(from: cgImage) else { return false }

        pasteboard.clearContents()
        var wroteSomething = pasteboard.setData(png, forType: .png)

        if let tiff = NSBitmapImageRep(cgImage: cgImage).tiffRepresentation {
            wroteSomething = pasteboard.setData(tiff, forType: .tiff) || wroteSomething
        }
        return wroteSomething
    }

    // MARK: Save to folder

    /// Builds a filename from `preferences.filenamePattern`, avoids
    /// overwriting an existing file by appending "-2", "-3"... before the
    /// extension, writes the PNG, and marks the document saved.
    @discardableResult
    static func save(document: EditorDocument, to folder: URL, preferences: Preferences = .shared) throws -> URL {
        guard let png = pngData(for: document) else {
            throw ExportError.renderFailed
        }

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw ExportError.writeFailed(underlying: error)
        }

        let filename = FilenamePattern.expand(preferences.filenamePattern,
                                              pixelSize: Renderer.outputPixelSize(for: document),
                                              folder: folder)
        let url = uniqueURL(for: filename, in: folder)

        do {
            try png.write(to: url, options: .atomic)
        } catch {
            throw ExportError.writeFailed(underlying: error)
        }

        document.markSaved()
        return url
    }

    /// Finds a URL in `folder` that does not exist yet, appending "-2", "-3"...
    /// before the extension when `filename` is already taken.
    static func uniqueURL(for filename: String, in folder: URL) -> URL {
        let ext = (filename as NSString).pathExtension
        let stem = (filename as NSString).deletingPathExtension

        var candidate = folder.appendingPathComponent(filename)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)"
            candidate = folder.appendingPathComponent(name)
            suffix += 1
        }
        return candidate
    }
}
