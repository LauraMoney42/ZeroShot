//
//  Renderer.swift
//  ZeroShot
//
//  One drawing routine shared by the on-screen canvas and by export, so what
//  you see is exactly what gets saved.
//
//  COORDINATE CONVENTION
//  ---------------------
//  Document space == image PIXEL space with a TOP-LEFT origin (+y down), the
//  same convention the canvas and the annotation model use.
//
//  A CGContext is natively bottom-left. `draw(document:in:)` therefore flips
//  the context exactly ONCE at the top and then works entirely in top-left
//  document coordinates. Images (the base capture, pixellated blur patches)
//  need a local counter-flip, which `drawImage(_:in:context:)` does.
//
//  If a crop is set, the context is additionally translated so that the crop
//  origin lands on the output origin, and clipped to the crop rect. Annotation
//  coordinates never change when you crop.
//

import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

enum Renderer {

    /// Shared CIContext for the blur/pixellate tool. Creating one per draw is
    /// expensive enough to be visible while dragging.
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Pixel size of what `renderImage` will produce for this document.
    static func outputPixelSize(for document: EditorDocument) -> CGSize {
        document.outputRect.size
    }

    // MARK: - Main entry point

    /// Draws the base image and every annotation into `ctx`.
    ///
    /// `ctx` is expected to be an un-transformed context whose bounds are
    /// `outputPixelSize(for:)` in the natural bottom-left CG orientation. This
    /// method flips it and leaves the graphics state as it found it.
    static func draw(document: EditorDocument, in ctx: CGContext, includeSelection: Bool = false) {
        // `displayRect` is `outputRect` for everything except a canvas whose
        // crop tool is currently showing the whole image again (see
        // EditorDocument.isSuspendingCropForEditing). `renderImage` clears that
        // flag first, so export always uses the applied crop.
        let output = document.displayRect

        ctx.saveGState()
        defer { ctx.restoreGState() }

        // 1. Flip to a top-left origin whose height is the OUTPUT height.
        ctx.translateBy(x: 0, y: output.height)
        ctx.scaleBy(x: 1, y: -1)
        // 2. Shift so that document coordinates line up with the output.
        ctx.translateBy(x: -output.origin.x, y: -output.origin.y)
        // 3. Nothing outside the crop may paint.
        ctx.clip(to: output)

        ctx.interpolationQuality = .high

        drawImage(document.baseImage, in: document.imageRect, context: ctx)

        for annotation in document.annotations {
            draw(annotation, document: document, in: ctx)
        }

        if includeSelection {
            for annotation in document.selectedAnnotations {
                drawSelection(for: annotation, in: ctx)
            }
        }
    }

    /// Flattens the document to a new CGImage at native pixel size (crop size
    /// when cropped). Returns nil only if a bitmap context cannot be made.
    static func renderImage(document: EditorDocument) -> CGImage? {
        // A flattened image always uses the APPLIED crop, even if the crop tool
        // happens to be showing the whole capture on screen right now.
        let wasSuspendingCrop = document.isSuspendingCropForEditing
        document.isSuspendingCropForEditing = false
        defer { document.isSuspendingCropForEditing = wasSuspendingCrop }

        let size = outputPixelSize(for: document)
        let width = max(Int(size.width.rounded()), 1)
        let height = max(Int(size.height.rounded()), 1)

        guard let ctx = CGContext(data: nil,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CodableColor.colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        draw(document: document, in: ctx, includeSelection: false)
        return ctx.makeImage()
    }

    /// Convenience for SwiftUI/AppKit previews. The NSImage is given the
    /// document's pixel size in points, i.e. it is treated as 1x, which is what
    /// a scroll view wants for a "100%" view of the pixels.
    static func renderNSImage(document: EditorDocument) -> NSImage? {
        guard let cgImage = renderImage(document: document) else { return nil }
        return NSImage(cgImage: cgImage,
                       size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    // MARK: - Per-annotation drawing

    /// Draws ONE annotation into a context whose CTM is already document space
    /// (top-left origin, +y down). Added for the canvas's live drag preview so
    /// the shape you drag out is drawn by exactly the same code that will draw
    /// it once committed. `draw(document:in:)` is still the entry point for
    /// everything else.
    static func drawPreview(_ annotation: Annotation, document: EditorDocument, in ctx: CGContext) {
        draw(annotation, document: document, in: ctx)
    }

    private static func draw(_ annotation: Annotation, document: EditorDocument, in ctx: CGContext) {
        let style = annotation.style
        let stroke = style.strokeColor.cgColor
        let width = max(style.strokeWidth, 0.5)

        ctx.saveGState()
        defer { ctx.restoreGState() }

        ctx.setLineWidth(width)
        ctx.setStrokeColor(stroke)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)

        switch annotation.kind {

        case .rectangle(let rect):
            let r = rect.standardized
            if let fill = style.fillColor {
                ctx.setFillColor(fill.cgColor)
                ctx.fill(r)
            }
            ctx.stroke(r, width: width)

        case .ellipse(let rect):
            let r = rect.standardized
            if let fill = style.fillColor {
                ctx.setFillColor(fill.cgColor)
                ctx.fillEllipse(in: r)
            }
            ctx.strokeEllipse(in: r)

        case .line(let a, let b):
            ctx.move(to: a)
            ctx.addLine(to: b)
            ctx.strokePath()

        case .arrow(let a, let b):
            drawArrow(from: a, to: b, width: width, color: stroke, in: ctx)

        case .path(let points):
            guard points.count > 1 else {
                if let only = points.first {
                    ctx.setFillColor(stroke)
                    ctx.fillEllipse(in: CGRect(x: only.x - width / 2, y: only.y - width / 2,
                                               width: width, height: width))
                }
                return
            }
            ctx.move(to: points[0])
            for point in points.dropFirst() { ctx.addLine(to: point) }
            ctx.strokePath()

        case .highlight(let rect):
            // Multiply keeps the underlying text readable through the wash.
            ctx.setBlendMode(.multiply)
            ctx.setFillColor(style.strokeColor.withAlpha(0.4).cgColor)
            ctx.fill(rect.standardized)

        case .blur(let rect):
            drawPixellated(rect: rect, document: document, style: style, in: ctx)

        case .text(let rect, let string):
            drawText(string, in: rect.standardized, style: style, ctx: ctx)

        case .badge(let center, let number):
            drawBadge(number: number, center: center, style: style, ctx: ctx)
        }
    }

    // MARK: Arrow

    private static func drawArrow(from a: CGPoint, to b: CGPoint,
                                  width: CGFloat, color: CGColor, in ctx: CGContext) {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 0.001 else { return }

        let ux = dx / length
        let uy = dy / length

        // Head size scales with stroke width, with a floor so thin arrows still
        // read as arrows.
        let headLength = min(max(width * 4.5, 10), length)
        let headHalfWidth = max(width * 2.2, 5)

        // Stop the shaft just inside the head so the join is not visible.
        let shaftEnd = CGPoint(x: b.x - ux * headLength * 0.85,
                               y: b.y - uy * headLength * 0.85)

        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.move(to: a)
        ctx.addLine(to: shaftEnd)
        ctx.strokePath()

        let baseCenter = CGPoint(x: b.x - ux * headLength, y: b.y - uy * headLength)
        // Perpendicular unit vector.
        let px = -uy
        let py = ux

        ctx.setFillColor(color)
        ctx.beginPath()
        ctx.move(to: b)
        ctx.addLine(to: CGPoint(x: baseCenter.x + px * headHalfWidth,
                                y: baseCenter.y + py * headHalfWidth))
        ctx.addLine(to: CGPoint(x: baseCenter.x - px * headHalfWidth,
                                y: baseCenter.y - py * headHalfWidth))
        ctx.closePath()
        ctx.fillPath()
    }

    // MARK: Blur

    private static func drawPixellated(rect: CGRect, document: EditorDocument,
                                       style: AnnotationStyle, in ctx: CGContext) {
        let target = rect.standardized.integral.intersection(document.imageRect)
        guard !target.isNull, target.width >= 1, target.height >= 1 else { return }

        // The inspector's stroke width doubles as the blur strength: block size
        // is strokeWidth * 3, so the 1...12 slider gives 3...36 pixel blocks.
        let blockSize = max(3, style.strokeWidth * 3)

        guard let pixellated = pixellatedPatch(of: document.baseImage,
                                               region: target,
                                               blockSize: blockSize) else { return }
        drawImage(pixellated, in: target, context: ctx)
    }

    /// Pixellates ONE region of the base image, never the whole image, and
    /// remembers the last few results.
    ///
    /// Without the cache every canvas redraw (each mouse-moved event of a drag,
    /// every selection change, every scroll) would re-run `CIPixellate`. The key
    /// covers everything that changes the output, so a hit is always safe.
    private static func pixellatedPatch(of image: CGImage,
                                        region: CGRect,
                                        blockSize: CGFloat) -> CGImage? {
        let key = PixellateKey(image: ObjectIdentifier(image),
                               x: Int(region.minX), y: Int(region.minY),
                               width: Int(region.width), height: Int(region.height),
                               blockSize: Int((blockSize * 10).rounded()))

        pixellateCacheLock.lock()
        if let hit = pixellateCache[key] {
            pixellateCacheLock.unlock()
            return hit
        }
        pixellateCacheLock.unlock()

        // CGImage.cropping uses top-left pixel coordinates, the same space the
        // annotation rect is already in, so no conversion is needed.
        guard let cropped = image.cropping(to: region) else { return nil }

        let input = CIImage(cgImage: cropped)
        let filter = CIFilter.pixellate()
        // Clamping stops the filter sampling transparent black outside the
        // patch, which would fade the edges of the blurred rect.
        filter.inputImage = input.clampedToExtent()
        filter.scale = Float(blockSize)
        // Anchor the block grid on the patch, not on the image origin, so the
        // blocks line up with the rect the user dragged.
        filter.center = CGPoint(x: input.extent.midX, y: input.extent.midY)

        guard let output = filter.outputImage?.cropped(to: input.extent),
              let pixellated = ciContext.createCGImage(output, from: input.extent) else { return nil }

        pixellateCacheLock.lock()
        // A plain cap rather than a real LRU: a document has a handful of blur
        // rects at most, and dropping everything costs one filter pass.
        if pixellateCache.count >= 24 { pixellateCache.removeAll(keepingCapacity: true) }
        pixellateCache[key] = pixellated
        pixellateCacheLock.unlock()

        return pixellated
    }

    private struct PixellateKey: Hashable {
        let image: ObjectIdentifier
        let x: Int, y: Int, width: Int, height: Int
        /// Tenths of a pixel, so the key stays Hashable without CGFloat.
        let blockSize: Int
    }

    private static var pixellateCache: [PixellateKey: CGImage] = [:]
    private static let pixellateCacheLock = NSLock()

    // MARK: Text

    private static func drawText(_ string: String, in rect: CGRect,
                                 style: AnnotationStyle, ctx: CGContext) {
        guard !string.isEmpty, rect.width > 0, rect.height > 0 else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(style.fontSize, 1)),
            .foregroundColor: NSColor(cgColor: style.strokeColor.cgColor) ?? .red
        ]
        let attributed = NSAttributedString(string: string, attributes: attributes)
        // Never let a stale box clip or wrap the text: a font-size change
        // after the box was laid out must still show every glyph.
        let needed = measureText(string, style: style)
        let drawRect = CGRect(x: rect.minX, y: rect.minY,
                              width: max(rect.width, needed.width),
                              height: max(rect.height, needed.height))
        drawAttributed(attributed, in: drawRect, ctx: ctx)
    }

    /// Natural size of `string` at the style's font, in document pixels, with
    /// the same slack the text overlay adds so the two agree exactly.
    static func measureText(_ string: String, style: AnnotationStyle) -> CGSize {
        let font = NSFont.systemFont(ofSize: max(style.fontSize, 1))
        let attributed = NSAttributedString(string: string.isEmpty ? " " : string,
                                            attributes: [.font: font])
        let bounds = attributed.boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude,
                         height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin])
        let lineHeight = max(font.ascender - font.descender + font.leading, font.pointSize * 1.2)
        return CGSize(width: ceil(bounds.width + font.pointSize * 0.6),
                      height: ceil(max(bounds.height, lineHeight)))
    }

    // MARK: Badge

    private static func drawBadge(number: Int, center: CGPoint,
                                  style: AnnotationStyle, ctx: CGContext) {
        let radius = max(style.badgeRadius, 2)
        let circle = CGRect(x: center.x - radius, y: center.y - radius,
                            width: radius * 2, height: radius * 2)

        ctx.saveGState()
        ctx.setFillColor(style.strokeColor.cgColor)
        ctx.fillEllipse(in: circle)
        ctx.restoreGState()

        // White bold number, shrunk to fit as the digit count grows.
        let text = String(number)
        var fontSize = radius * 1.25
        if text.count > 2 { fontSize *= 2.0 / CGFloat(text.count) }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: max(fontSize, 1)),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributed.size()
        let textRect = CGRect(x: center.x - textSize.width / 2,
                              y: center.y - textSize.height / 2,
                              width: textSize.width,
                              height: textSize.height)
        drawAttributed(attributed, in: textRect, ctx: ctx)
    }

    // MARK: - Low level helpers

    /// Draws a CGImage into a top-left-origin document rect. The extra flip
    /// undoes the global flip for the duration of the image draw only.
    private static func drawImage(_ image: CGImage, in rect: CGRect, context ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY + rect.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    /// AppKit string drawing into an arbitrary CGContext. The context is
    /// already y-down, so NSGraphicsContext is told `flipped: true`.
    private static func drawAttributed(_ string: NSAttributedString, in rect: CGRect, ctx: CGContext) {
        let previous = NSGraphicsContext.current
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.current = graphics
        string.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        NSGraphicsContext.current = previous
    }

    /// Dashed marching-ants box around a selected annotation, plus corner
    /// handles. Only drawn on screen, never in export.
    private static func drawSelection(for annotation: Annotation, in ctx: CGContext) {
        let box = annotation.boundingRect.insetBy(dx: -3, dy: -3)

        ctx.saveGState()
        ctx.setStrokeColor(CodableColor.blue.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [5, 3])
        ctx.stroke(box)
        ctx.setLineDash(phase: 0, lengths: [])

        let handle: CGFloat = 7
        let corners = [
            CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY)
        ]
        ctx.setFillColor(CodableColor.white.cgColor)
        for corner in corners {
            let r = CGRect(x: corner.x - handle / 2, y: corner.y - handle / 2,
                           width: handle, height: handle)
            ctx.fill(r)
            ctx.stroke(r)
        }
        ctx.restoreGState()
    }
}
