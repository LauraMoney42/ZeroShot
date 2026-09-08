//
//  ToolTests-M4.swift
//  ZeroShotTests
//
//  Milestone 4: crop, highlighter, blur and freehand pen.
//
//  The tools are driven exactly the way `CanvasView` drives them, by calling
//  the `CanvasTool` methods with DOCUMENT-space points, so no window, no run
//  loop and no real mouse are involved. Rendering assertions go through
//  `Renderer` and read pixels back with a top-left origin.
//

import AppKit
import CoreGraphics
import XCTest
@testable import ZeroShot

@MainActor
final class ToolTestsM4: XCTestCase {

    // MARK: Fixtures

    private func makeCanvas(documentSize: CGSize = CGSize(width: 400, height: 300),
                            viewSize: CGSize = CGSize(width: 800, height: 600),
                            zoom: CGFloat = 1,
                            image: CGImage? = nil)
    -> (CanvasView, EditorDocument, CanvasSettings) {
        let base = image ?? TestSupport.makeImage(width: Int(documentSize.width),
                                                  height: Int(documentSize.height))
        let document = EditorDocument(image: base)
        let settings = CanvasSettings()
        let canvas = CanvasView(document: document, settings: settings)
        canvas.frame = NSRect(origin: .zero, size: viewSize)
        canvas.setZoom(zoom)
        return (canvas, document, settings)
    }

    private func drag(_ canvas: CanvasView,
                      from start: CGPoint,
                      to end: CGPoint,
                      steps: Int = 4,
                      modifiers: NSEvent.ModifierFlags = []) {
        let tool = canvas.activeTool
        tool.mouseDown(at: start, modifiers: modifiers, canvas: canvas)
        for step in 1...max(steps, 1) {
            let t = CGFloat(step) / CGFloat(max(steps, 1))
            let point = CGPoint(x: start.x + (end.x - start.x) * t,
                                y: start.y + (end.y - start.y) * t)
            tool.mouseDragged(at: point, modifiers: modifiers, canvas: canvas)
        }
        tool.mouseUp(at: end, modifiers: modifiers, canvas: canvas)
    }

    /// A Return key press, the crop tool's "apply".
    private func returnKeyEvent() -> NSEvent {
        NSEvent.keyEvent(with: .keyDown,
                         location: .zero,
                         modifierFlags: [],
                         timestamp: 0,
                         windowNumber: 0,
                         context: nil,
                         characters: "\r",
                         charactersIgnoringModifiers: "\r",
                         isARepeat: false,
                         keyCode: 36)!
    }

    /// White with 4px black vertical stripes, so pixellating any region is
    /// guaranteed to change the pixels inside it.
    private func makeStripedImage(width: Int, height: Int) -> CGImage {
        guard let ctx = TestSupport.makeContext(width: width, height: height) else {
            fatalError("could not create a test bitmap context")
        }
        ctx.setFillColor(CodableColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CodableColor.black.cgColor)
        for x in stride(from: 0, to: width, by: 8) {
            ctx.fill(CGRect(x: x, y: 0, width: 4, height: height))
        }
        guard let image = ctx.makeImage() else { fatalError("could not create a test image") }
        return image
    }

    // MARK: - Crop

    func testCropApplyChangesTheRenderedSizeAndUndoRestoresIt() {
        let (canvas, document, _) = makeCanvas(zoom: 1)
        XCTAssertEqual(Renderer.outputPixelSize(for: document), CGSize(width: 400, height: 300))

        canvas.setActiveTool(.crop)
        drag(canvas, from: CGPoint(x: 50, y: 40), to: CGPoint(x: 250, y: 190), steps: 8)

        // The drag only proposes a rectangle; nothing is committed until apply.
        XCTAssertNil(document.cropRect)
        XCTAssertEqual(Renderer.outputPixelSize(for: document), CGSize(width: 400, height: 300))

        XCTAssertTrue(canvas.activeTool.handleKeyDown(returnKeyEvent(), canvas: canvas))

        XCTAssertEqual(document.cropRect, CGRect(x: 50, y: 40, width: 200, height: 150))
        XCTAssertEqual(Renderer.outputPixelSize(for: document), CGSize(width: 200, height: 150))

        // And the flattened image really is that size.
        let cropped = Renderer.renderImage(document: document)
        XCTAssertEqual(cropped?.width, 200)
        XCTAssertEqual(cropped?.height, 150)

        // One undo step for the whole crop.
        document.undoManager.undo()
        XCTAssertNil(document.cropRect)
        XCTAssertEqual(Renderer.outputPixelSize(for: document), CGSize(width: 400, height: 300))
        XCTAssertFalse(document.undoManager.canUndo)
    }

    func testCropIsNonDestructiveSoAnnotationsKeepTheirPixelCoordinates() {
        let (canvas, document, _) = makeCanvas(zoom: 1)
        let annotation = document.add(Annotation(kind: .rectangle(CGRect(x: 100, y: 100,
                                                                         width: 50, height: 50))))
        canvas.setActiveTool(.crop)
        drag(canvas, from: CGPoint(x: 80, y: 80), to: CGPoint(x: 280, y: 230), steps: 6)
        _ = canvas.activeTool.handleKeyDown(returnKeyEvent(), canvas: canvas)

        XCTAssertEqual(document.cropRect, CGRect(x: 80, y: 80, width: 200, height: 150))
        // Untouched: the model still speaks in original image pixels.
        XCTAssertEqual(document.annotation(withID: annotation.id)?.kind.rectValue,
                       CGRect(x: 100, y: 100, width: 50, height: 50))
        XCTAssertEqual(document.baseImage.width, 400)
    }

    func testCanvasFitsTheCroppedAreaAfterApplying() {
        let (canvas, document, _) = makeCanvas(zoom: 1)
        canvas.setActiveTool(.crop)
        drag(canvas, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 160), steps: 4)
        _ = canvas.activeTool.handleKeyDown(returnKeyEvent(), canvas: canvas)

        // The canvas lays out and converts against the crop, not the capture.
        XCTAssertEqual(canvas.document.displayRect, CGRect(x: 100, y: 100, width: 100, height: 60))
        XCTAssertEqual(canvas.viewPoint(fromDocument: CGPoint(x: 100, y: 100)), canvas.imageOrigin)
        XCTAssertEqual(canvas.contentSize.width, 100 * canvas.zoom, accuracy: 0.001)
    }

    func testCropToolShowsTheWholeImageAgainWhileAdjustingAnAppliedCrop() {
        let (canvas, document, _) = makeCanvas(zoom: 1)
        document.setCrop(CGRect(x: 50, y: 50, width: 100, height: 100))
        canvas.setActiveTool(.select)
        XCTAssertEqual(canvas.document.displayRect, CGRect(x: 50, y: 50, width: 100, height: 100))

        canvas.setActiveTool(.crop)
        // Suspended for editing: the canvas shows the whole capture...
        XCTAssertTrue(document.isSuspendingCropForEditing)
        XCTAssertEqual(canvas.document.displayRect, document.imageRect)
        // ...but export still uses the applied crop.
        XCTAssertEqual(Renderer.outputPixelSize(for: document), CGSize(width: 100, height: 100))
        XCTAssertEqual(Renderer.renderImage(document: document)?.width, 100)

        // Leaving the tool puts the cropped view back.
        canvas.setActiveTool(.select)
        XCTAssertFalse(document.isSuspendingCropForEditing)
        XCTAssertEqual(canvas.document.displayRect, CGRect(x: 50, y: 50, width: 100, height: 100))
    }

    func testResetCropPillRemovesTheCropAndUndoBringsItBack() {
        let (canvas, document, _) = makeCanvas(zoom: 1)
        document.setCrop(CGRect(x: 50, y: 50, width: 100, height: 100))
        canvas.setActiveTool(.crop)

        // With a crop applied and nothing re-dragged yet the overlay shows one
        // pill, "Reset crop", centred at the top of the visible area.
        let pill = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.maxY - 16 - 12)
        let tool = canvas.activeTool
        tool.mouseDown(at: canvas.documentPoint(fromView: pill), modifiers: [], canvas: canvas)
        tool.mouseUp(at: canvas.documentPoint(fromView: pill), modifiers: [], canvas: canvas)

        XCTAssertNil(document.cropRect)
        XCTAssertEqual(Renderer.outputPixelSize(for: document), CGSize(width: 400, height: 300))

        document.undoManager.undo()
        XCTAssertEqual(document.cropRect, CGRect(x: 50, y: 50, width: 100, height: 100))
    }

    func testEscapeDuringACropDragCommitsNothing() {
        let (canvas, document, _) = makeCanvas(zoom: 1)
        canvas.setActiveTool(.crop)
        drag(canvas, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 200, y: 200), steps: 4)

        canvas.activeTool.cancel(canvas: canvas)

        XCTAssertNil(document.cropRect)
        XCTAssertFalse(document.undoManager.canUndo)
    }

    // MARK: - Highlighter

    func testHighlightDragCreatesOneYellowHighlight() {
        let (canvas, document, settings) = makeCanvas(zoom: 1)
        settings.style.strokeColor = .red

        canvas.setActiveTool(.highlight)
        // Picking the tool switches the shared colour to yellow.
        XCTAssertEqual(settings.style.strokeColor, .yellow)

        drag(canvas, from: CGPoint(x: 20, y: 30), to: CGPoint(x: 140, y: 70), steps: 6)

        XCTAssertEqual(document.annotations.count, 1)
        XCTAssertEqual(document.annotations[0].kind.rectValue,
                       CGRect(x: 20, y: 30, width: 120, height: 40))
        XCTAssertEqual(document.annotations[0].style.strokeColor, .yellow)
        XCTAssertNil(document.annotations[0].style.fillColor)

        // Leaving the highlighter restores the previous colour for shapes.
        canvas.setActiveTool(.rectangle)
        XCTAssertEqual(settings.style.strokeColor, .red)
    }

    func testHighlightRendersAYellowWashOverAWhiteBase() {
        let document = EditorDocument(image: TestSupport.makeImage(width: 100, height: 100))
        document.add(Annotation(kind: .highlight(CGRect(x: 20, y: 20, width: 40, height: 40)),
                                style: AnnotationStyle(strokeColor: .yellow)))

        guard let image = Renderer.renderImage(document: document) else {
            return XCTFail("expected a rendered image")
        }
        let inside = TestSupport.color(of: image, x: 40, y: 40)
        let outside = TestSupport.color(of: image, x: 5, y: 5)

        XCTAssertTrue(outside.isWhite, "outside the highlight should be untouched: \(outside)")
        // 40% yellow multiplied over white: red stays high, blue drops most.
        XCTAssertGreaterThan(inside.r, 200)
        XCTAssertGreaterThan(inside.g, 200)
        XCTAssertLessThan(inside.b, 200)
        XCTAssertGreaterThan(Int(inside.r) - Int(inside.b), 40, "expected a yellow cast: \(inside)")
    }

    func testHighlightIsSelectableAndMovable() {
        let (canvas, document, _) = makeCanvas(zoom: 1)
        let highlight = document.add(Annotation(kind: .highlight(CGRect(x: 40, y: 40,
                                                                        width: 100, height: 30))))
        XCTAssertTrue(highlight.hitTest(CGPoint(x: 90, y: 55)))
        XCTAssertFalse(highlight.hitTest(CGPoint(x: 300, y: 200)))
        // The generic rect handling gives it the eight box handles.
        XCTAssertEqual(highlight.kind.selectionHandles, SelectionHandle.boxHandles)

        canvas.setActiveTool(.select)
        drag(canvas, from: CGPoint(x: 90, y: 55), to: CGPoint(x: 110, y: 75), steps: 5)
        XCTAssertEqual(document.annotations.first?.kind.rectValue,
                       CGRect(x: 60, y: 60, width: 100, height: 30))
    }

    // MARK: - Blur

    func testBlurDragCreatesOneBlurAnnotation() {
        let (canvas, document, settings) = makeCanvas(zoom: 1)
        settings.style.strokeWidth = 6

        canvas.setActiveTool(.blur)
        drag(canvas, from: CGPoint(x: 30, y: 30), to: CGPoint(x: 130, y: 110), steps: 6)

        XCTAssertEqual(document.annotations.count, 1)
        XCTAssertEqual(document.annotations[0].kind.rectValue,
                       CGRect(x: 30, y: 30, width: 100, height: 80))
        // The stroke width rides along as the block size (width * 3).
        XCTAssertEqual(document.annotations[0].style.strokeWidth, 6)
    }

    func testBlurChangesPixelsOnlyInsideItsRect() {
        let base = makeStripedImage(width: 200, height: 200)
        let rect = CGRect(x: 60, y: 50, width: 80, height: 60)

        let plain = EditorDocument(image: base)
        let blurred = EditorDocument(image: base)
        blurred.add(Annotation(kind: .blur(rect),
                               style: AnnotationStyle(strokeWidth: 8)))

        guard let before = Renderer.renderImage(document: plain),
              let after = Renderer.renderImage(document: blurred) else {
            return XCTFail("expected two rendered images")
        }
        XCTAssertEqual(before.width, after.width)
        XCTAssertEqual(before.height, after.height)

        let beforePixels = TestSupport.pixels(of: before)
        let afterPixels = TestSupport.pixels(of: after)

        var changedInside = 0
        var changedOutside = 0
        for y in 0..<beforePixels.height {
            for x in 0..<beforePixels.width {
                let offset = (y * beforePixels.width + x) * 4
                let same = beforePixels.data[offset] == afterPixels.data[offset]
                    && beforePixels.data[offset + 1] == afterPixels.data[offset + 1]
                    && beforePixels.data[offset + 2] == afterPixels.data[offset + 2]
                guard !same else { continue }
                if rect.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) {
                    changedInside += 1
                } else {
                    changedOutside += 1
                }
            }
        }

        XCTAssertGreaterThan(changedInside, 100, "the blur should repaint its own region")
        XCTAssertEqual(changedOutside, 0, "the blur leaked outside its rect")

        // A pixel just outside the rect is byte-for-byte what it was.
        for point in [CGPoint(x: 58, y: 80), CGPoint(x: 142, y: 80),
                      CGPoint(x: 100, y: 48), CGPoint(x: 100, y: 112)] {
            XCTAssertEqual(TestSupport.color(of: after, x: Int(point.x), y: Int(point.y)),
                           TestSupport.color(of: before, x: Int(point.x), y: Int(point.y)),
                           "pixel \(point) just outside the blur changed")
        }
    }

    func testBlurBlockSizeFollowsTheStrokeWidth() {
        let base = makeStripedImage(width: 200, height: 200)
        let rect = CGRect(x: 40, y: 40, width: 120, height: 120)

        func render(strokeWidth: CGFloat) -> [UInt8] {
            let document = EditorDocument(image: base)
            document.add(Annotation(kind: .blur(rect),
                                    style: AnnotationStyle(strokeWidth: strokeWidth)))
            guard let image = Renderer.renderImage(document: document) else { return [] }
            return TestSupport.pixels(of: image).data
        }

        let fine = render(strokeWidth: 1)
        let coarse = render(strokeWidth: 12)
        XCTAssertFalse(fine.isEmpty)
        XCTAssertNotEqual(fine, coarse, "the stroke width slider should change the block size")
    }

    // MARK: - Freehand pen

    func testPenDragCommitsOnePathInOneUndoStep() {
        let (canvas, document, settings) = makeCanvas(zoom: 1)
        settings.style.strokeColor = .blue
        settings.style.strokeWidth = 5
        canvas.setActiveTool(.pen)

        // 40 samples one pixel apart: closer than the 2px minimum spacing, so
        // the tool has to thin them out.
        let sampleCount = 40
        let tool = canvas.activeTool
        tool.mouseDown(at: CGPoint(x: 20, y: 20), modifiers: [], canvas: canvas)
        for step in 1...sampleCount {
            tool.mouseDragged(at: CGPoint(x: 20 + CGFloat(step), y: 20 + CGFloat(step) * 0.5),
                              modifiers: [], canvas: canvas)
        }
        tool.mouseUp(at: CGPoint(x: 20 + CGFloat(sampleCount), y: 20 + CGFloat(sampleCount) * 0.5),
                     modifiers: [], canvas: canvas)

        XCTAssertEqual(document.annotations.count, 1)
        guard case .path(let points) = document.annotations[0].kind else {
            return XCTFail("expected a freehand path")
        }
        XCTAssertGreaterThan(points.count, 1)
        XCTAssertLessThanOrEqual(points.count, sampleCount + 1)
        XCTAssertLessThan(points.count, sampleCount, "points closer than 2px should be dropped")
        XCTAssertEqual(points.first, CGPoint(x: 20, y: 20))
        XCTAssertEqual(points.last?.x, 60)

        XCTAssertEqual(document.annotations[0].style.strokeColor, .blue)
        XCTAssertEqual(document.annotations[0].style.strokeWidth, 5)

        // One drag, one undo step.
        XCTAssertTrue(document.undoManager.canUndo)
        document.undoManager.undo()
        XCTAssertTrue(document.annotations.isEmpty)
        XCTAssertFalse(document.undoManager.canUndo)
    }

    func testPenClickWithoutMovementDrawsNothing() {
        let (canvas, document, _) = makeCanvas(zoom: 1)
        canvas.setActiveTool(.pen)

        drag(canvas, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 50.5, y: 50.5), steps: 2)

        XCTAssertTrue(document.annotations.isEmpty)
        XCTAssertFalse(document.undoManager.canUndo)
    }

    func testPathHitTestingFollowsTheStrokeAndMoveWorks() {
        let (canvas, document, _) = makeCanvas(zoom: 1)
        let path = document.add(Annotation(kind: .path([CGPoint(x: 20, y: 20),
                                                        CGPoint(x: 120, y: 20),
                                                        CGPoint(x: 120, y: 120)]),
                                           style: AnnotationStyle(strokeWidth: 4)))

        XCTAssertTrue(path.hitTest(CGPoint(x: 70, y: 21)), "on the stroke")
        XCTAssertFalse(path.hitTest(CGPoint(x: 70, y: 90)), "inside the bend but off the stroke")
        // Paths are moved, not resized.
        XCTAssertTrue(path.kind.selectionHandles.isEmpty)

        canvas.setActiveTool(.select)
        drag(canvas, from: CGPoint(x: 70, y: 20), to: CGPoint(x: 80, y: 40), steps: 4)
        guard case .path(let moved) = document.annotations[0].kind else {
            return XCTFail("expected a freehand path")
        }
        XCTAssertEqual(moved.first, CGPoint(x: 30, y: 40))
    }

    func testPenRendersInItsStrokeColour() {
        let document = EditorDocument(image: TestSupport.makeImage(width: 100, height: 100))
        document.add(Annotation(kind: .path([CGPoint(x: 10, y: 50), CGPoint(x: 90, y: 50)]),
                                style: AnnotationStyle(strokeColor: .red, strokeWidth: 6)))

        guard let image = Renderer.renderImage(document: document) else {
            return XCTFail("expected a rendered image")
        }
        XCTAssertTrue(TestSupport.color(of: image, x: 50, y: 50).isRedish)
        XCTAssertTrue(TestSupport.color(of: image, x: 50, y: 10).isWhite)
    }

    // MARK: - Registry

    func testMilestoneFourToolsAreRegistered() {
        for kind in [ToolKind.crop, .highlight, .blur, .pen] {
            XCTAssertTrue(ToolRegistry.isImplemented(kind), "\(kind) should be implemented")
            XCTAssertEqual(ToolRegistry.makeTool(for: kind).kind, kind)
        }
    }
}
