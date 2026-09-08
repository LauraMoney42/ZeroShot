#!/usr/bin/env swift
//
//  make-icon.swift
//  ZeroShot
//
//  Draws the app icon with Core Graphics (no image assets, no Xcode asset
//  catalog needed) and builds Resources/AppIcon.icns from it.
//
//  Design: rounded-square background, dark blue to teal gradient (same as
//  before, for continuity), with a yellow highlighter pen drawn diagonally
//  over a translucent highlight stroke -- the app's own highlighter tool,
//  since that is the shape most people reach for first.
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

    // MARK: Highlighter pen, drawn diagonally (tip lower-left, cap
    // upper-right), the same way the SF Symbol and the in-app tool read.
    let center = CGPoint(x: size / 2, y: size / 2)
    let angle = -45 * CGFloat.pi / 180

    // The translucent mark the highlighter leaves behind, drawn first so the
    // pen sits on top of it. Offset below the pen's own axis, the way an
    // underline sits below a word.
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: angle)
    let markWidth = size * 0.46
    let markHeight = size * 0.105
    let markRect = CGRect(x: -markWidth * 0.42, y: size * 0.10, width: markWidth, height: markHeight)
    ctx.addPath(CGPath(roundedRect: markRect, cornerWidth: markHeight / 2, cornerHeight: markHeight / 2, transform: nil))
    ctx.setFillColor(CGColor(red: 1.0, green: 0.85, blue: 0.15, alpha: 0.55))
    ctx.fillPath()
    ctx.restoreGState()

    // The barrel: a yellow capsule, most of the pen's length.
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: angle)
    let barrelLength = size * 0.62
    let barrelWidth = size * 0.165
    let barrelRect = CGRect(x: -barrelLength / 2, y: -barrelWidth / 2, width: barrelLength, height: barrelWidth)
    let barrelPath = CGPath(roundedRect: barrelRect, cornerWidth: barrelWidth * 0.4, cornerHeight: barrelWidth * 0.4, transform: nil)
    ctx.addPath(barrelPath)
    ctx.setFillColor(CGColor(red: 1.0, green: 0.82, blue: 0.0, alpha: 1.0))
    ctx.fillPath()

    // A thin highlight along the top edge of the barrel, for a rounded,
    // dimensional look rather than a flat bar.
    ctx.addPath(barrelPath)
    ctx.clip()
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.22))
    ctx.fill(CGRect(x: -barrelLength / 2, y: barrelWidth * 0.08, width: barrelLength, height: barrelWidth * 0.22))
    ctx.restoreGState()

    // The cap: a dark charcoal band at the upper-right end of the barrel.
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: angle)
    let capLength = barrelLength * 0.30
    let capRect = CGRect(x: barrelLength / 2 - capLength, y: -barrelWidth / 2, width: capLength, height: barrelWidth)
    ctx.addPath(barrelPath)
    ctx.clip()
    ctx.setFillColor(CGColor(red: 0.16, green: 0.18, blue: 0.22, alpha: 1.0))
    ctx.fill(capRect)
    ctx.restoreGState()

    // The nib: a pale chisel tip at the lower-left end, angled to a point so
    // it reads as the business end of a highlighter, not just a rod.
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: angle)
    let nibLength = size * 0.11
    let nibBaseX = -barrelLength / 2
    let nib = CGMutablePath()
    nib.move(to: CGPoint(x: nibBaseX, y: -barrelWidth / 2))
    nib.addLine(to: CGPoint(x: nibBaseX, y: barrelWidth / 2))
    nib.addLine(to: CGPoint(x: nibBaseX - nibLength, y: barrelWidth * 0.12))
    nib.addLine(to: CGPoint(x: nibBaseX - nibLength * 1.15, y: -barrelWidth * 0.12))
    nib.closeSubpath()
    ctx.addPath(nib)
    ctx.setFillColor(CGColor(red: 0.90, green: 0.90, blue: 0.90, alpha: 1.0))
    ctx.fillPath()
    ctx.restoreGState()

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
