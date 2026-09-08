#!/usr/bin/env swift
//
//  make-icon.swift
//  ZeroShot
//
//  Draws the app icon with Core Graphics (no image assets, no Xcode asset
//  catalog needed) and builds Resources/AppIcon.icns from it.
//
//  Design: rounded-square background, dark blue to teal gradient, a white
//  camera-shutter style ring, and a bold white "0" in the center, tying the
//  icon to the Cmd+0 capture hotkey.
//
//  Run with: swift Scripts/make-icon.swift
//  (from the project root; it writes into ./Resources)
//

import AppKit
import CoreGraphics
import Foundation

// MARK: - Paths

let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resourcesDir = projectRoot.appendingPathComponent("Resources", isDirectory: true)
// The intermediate .iconset lives under build/, not Resources/, so only the
// final .icns (what the app actually needs) gets picked up as a bundle
// resource by project.yml's `resources: - path: Resources`.
let iconsetDir = projectRoot.appendingPathComponent("build/AppIcon.iconset", isDirectory: true)
let icnsURL = resourcesDir.appendingPathComponent("AppIcon.icns")

try? FileManager.default.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
try? FileManager.default.removeItem(at: iconsetDir)
try? FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

// MARK: - Drawing

/// Draws the full icon design into a square context of `pixels` x `pixels`,
/// at whatever resolution is asked for. Every measurement below is expressed
/// as a fraction of `pixels` so the same routine works at 16pt and 1024pt.
func drawIcon(pixels: Int) -> CGImage? {
    let size = CGFloat(pixels)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil,
                              width: pixels,
                              height: pixels,
                              bitsPerComponent: 8,
                              bytesPerRow: 0,
                              space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

    // Top-left origin makes the math below read the same as the rest of the
    // app's document space, even though this script is otherwise standalone.
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: 1, y: -1)

    let fullRect = CGRect(x: 0, y: 0, width: size, height: size)

    // MARK: Rounded-square background, dark blue to teal.
    let cornerRadius = size * 0.225 // macOS "squircle-ish" continuous look, close enough via round rect.
    let backgroundPath = CGPath(roundedRect: fullRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.saveGState()
    ctx.addPath(backgroundPath)
    ctx.clip()

    let darkBlue = CGColor(red: 0.06, green: 0.10, blue: 0.30, alpha: 1.0)
    let teal = CGColor(red: 0.06, green: 0.62, blue: 0.62, alpha: 1.0)
    guard let gradient = CGGradient(colorsSpace: colorSpace,
                                    colors: [darkBlue, teal] as CFArray,
                                    locations: [0.0, 1.0]) else { return nil }
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: 0),
                           end: CGPoint(x: size, y: size),
                           options: [])
    ctx.restoreGState()

    // Subtle inner highlight near the top so the gradient does not look flat.
    ctx.saveGState()
    ctx.addPath(backgroundPath)
    ctx.clip()
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.06))
    ctx.fillEllipse(in: CGRect(x: size * 0.05, y: -size * 0.35, width: size * 0.9, height: size * 0.9))
    ctx.restoreGState()

    // MARK: Camera-shutter style ring.
    let center = CGPoint(x: size / 2, y: size / 2)
    let ringRadius = size * 0.335
    let ringWidth = size * 0.052
    ctx.saveGState()
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.92))
    ctx.setLineWidth(ringWidth)
    ctx.setLineCap(.round)
    ctx.addArc(center: center, radius: ringRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()

    // Shutter "blade" notches around the ring, evenly spaced, to read as a
    // camera shutter rather than a plain circle.
    let notchCount = 8
    let notchLength = size * 0.075
    let notchWidth = size * 0.02
    for index in 0..<notchCount {
        let angle = (CGFloat(index) / CGFloat(notchCount)) * .pi * 2
        let inner = CGPoint(x: center.x + cos(angle) * (ringRadius - ringWidth / 2 - notchLength / 2),
                            y: center.y + sin(angle) * (ringRadius - ringWidth / 2 - notchLength / 2))
        ctx.saveGState()
        ctx.translateBy(x: inner.x, y: inner.y)
        ctx.rotate(by: angle)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.55))
        let notchRect = CGRect(x: -notchLength / 2, y: -notchWidth / 2, width: notchLength, height: notchWidth)
        ctx.fill(notchRect)
        ctx.restoreGState()
    }
    ctx.restoreGState()

    // MARK: Bold white "0" in the center (ties to the Cmd+0 hotkey).
    let font = NSFont.systemFont(ofSize: size * 0.42, weight: .heavy)
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
        .paragraphStyle: paragraphStyle
    ]
    let text = NSAttributedString(string: "0", attributes: attributes)
    let line = CTLineCreateWithAttributedString(text)
    let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)

    NSGraphicsContext.saveGraphicsState()
    let nsContext = NSGraphicsContext(cgContext: ctx, flipped: true)
    NSGraphicsContext.current = nsContext
    ctx.saveGState()
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: 1, y: -1)
    let textOrigin = CGPoint(x: center.x - bounds.width / 2 - bounds.origin.x,
                             y: size - (center.y + bounds.height / 2 + bounds.origin.y))
    ctx.textPosition = textOrigin
    CTLineDraw(line, ctx)
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()

    return ctx.makeImage()
}

// MARK: - PNG writing

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        FileHandle.standardError.write("Failed to create PNG destination for \(url.path)\n".data(using: .utf8)!)
        exit(1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        FileHandle.standardError.write("Failed to write PNG at \(url.path)\n".data(using: .utf8)!)
        exit(1)
    }
}

// MARK: - Standard iconset sizes

// (filename, pixel size)
let iconsetEntries: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (filename, pixels) in iconsetEntries {
    guard let image = drawIcon(pixels: pixels) else {
        FileHandle.standardError.write("Failed to render icon at \(pixels)px\n".data(using: .utf8)!)
        exit(1)
    }
    writePNG(image, to: iconsetDir.appendingPathComponent(filename))
    print("Wrote \(filename) (\(pixels)x\(pixels))")
}

// MARK: - iconutil

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetDir.path, "-o", icnsURL.path]
try process.run()
process.waitUntilExit()

if process.terminationStatus == 0 {
    print("Wrote \(icnsURL.path)")
} else {
    FileHandle.standardError.write("iconutil failed with status \(process.terminationStatus)\n".data(using: .utf8)!)
    exit(1)
}
