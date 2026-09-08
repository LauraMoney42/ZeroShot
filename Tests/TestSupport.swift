//
//  TestSupport.swift
//  ZeroShotTests
//
//  Small helpers for building and inspecting CGImages in tests.
//  All pixel access uses the app's convention: TOP-LEFT origin, +y down.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ZeroShot

enum TestSupport {

    struct RGBA: Equatable, CustomStringConvertible {
        var r: UInt8, g: UInt8, b: UInt8, a: UInt8

        var isWhite: Bool { r > 245 && g > 245 && b > 245 }
        var isRedish: Bool { r > 180 && g < 100 && b < 100 }

        var description: String { "rgba(\(r), \(g), \(b), \(a))" }
    }

    static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: CodableColor.colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// A solid image, white by default.
    static func makeImage(width: Int, height: Int, color: CodableColor = .white) -> CGImage {
        guard let ctx = makeContext(width: width, height: height) else {
            fatalError("could not create a test bitmap context")
        }
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage() else {
            fatalError("could not create a test image")
        }
        return image
    }

    /// An image whose TOP half is `top` and bottom half is `bottom`, used to pin
    /// down vertical orientation. The context is bottom-left origin, so the top
    /// half is the high-y band.
    static func makeVerticallySplitImage(width: Int, height: Int,
                                         top: CodableColor, bottom: CodableColor) -> CGImage {
        guard let ctx = makeContext(width: width, height: height) else {
            fatalError("could not create a test bitmap context")
        }
        ctx.setFillColor(bottom.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        ctx.setFillColor(top.cgColor)
        ctx.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))
        guard let image = ctx.makeImage() else {
            fatalError("could not create a test image")
        }
        return image
    }

    /// Writes a CGImage out as a PNG, the same format screencapture produces.
    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                                UTType.png.identifier as CFString,
                                                                1, nil) else {
            throw NSError(domain: "TestSupport", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "could not create a PNG destination"])
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "TestSupport", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "could not write the PNG"])
        }
    }

    /// Reads every pixel of `image` into an RGBA8 buffer indexed from the
    /// TOP-LEFT, matching document space.
    static func pixels(of image: CGImage) -> (width: Int, height: Int, data: [UInt8]) {
        let width = image.width
        let height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)

        data.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width * 4,
                                      space: CodableColor.colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                fatalError("could not create a readback context")
            }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (width, height, data)
    }

    /// Colour at document point (x, y), origin top-left.
    static func color(of image: CGImage, x: Int, y: Int) -> RGBA {
        let buffer = pixels(of: image)
        precondition(x >= 0 && x < buffer.width && y >= 0 && y < buffer.height,
                     "sample point is outside the image")
        let offset = (y * buffer.width + x) * 4
        return RGBA(r: buffer.data[offset],
                    g: buffer.data[offset + 1],
                    b: buffer.data[offset + 2],
                    a: buffer.data[offset + 3])
    }

    /// True when any pixel inside `rect` is not white.
    static func containsNonWhitePixel(_ image: CGImage, in rect: CGRect) -> Bool {
        let buffer = pixels(of: image)
        let clamped = rect.integral.intersection(CGRect(x: 0, y: 0,
                                                        width: buffer.width,
                                                        height: buffer.height))
        guard !clamped.isNull else { return false }
        for y in Int(clamped.minY)..<Int(clamped.maxY) {
            for x in Int(clamped.minX)..<Int(clamped.maxX) {
                let offset = (y * buffer.width + x) * 4
                let pixel = RGBA(r: buffer.data[offset],
                                 g: buffer.data[offset + 1],
                                 b: buffer.data[offset + 2],
                                 a: buffer.data[offset + 3])
                if !pixel.isWhite { return true }
            }
        }
        return false
    }
}
