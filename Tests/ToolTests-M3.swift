//
//  ToolTests-M3.swift
//  ZeroShotTests
//
//  Milestone 3: the number badge tool and the text tool.
//
//  The tools are driven through the `CanvasTool` protocol exactly the way
//  `CanvasView` drives them from real mouse events, so no UI is presented and
//  no window is needed. Document coordinates are image pixels, top-left origin.
//

import AppKit
import CoreGraphics
import XCTest
@testable import ZeroShot

@MainActor
final class ToolTestsM3: XCTestCase {

    // MARK: Fixtures

    private func makeCanvas(documentSize: CGSize = CGSize(width: 400, height: 300),
                            viewSize: CGSize = CGSize(width: 800, height: 600),
                            baseColor: CodableColor = .white)
    -> (CanvasView, EditorDocument, CanvasSettings) {
        let image = TestSupport.makeImage(width: Int(documentSize.width),
                                          height: Int(documentSize.height),
                                          color: baseColor)
        let document = EditorDocument(image: image)
        let settings = CanvasSettings()
        let canvas = CanvasView(document: document, settings: settings)
        canvas.frame = NSRect(origin: .zero, size: viewSize)
        canvas.setZoom(1)
        return (canvas, document, settings)
    }

    /// A press and release with no movement, which is all the badge tool needs.
    private func click(_ canvas: CanvasView, at point: CGPoint) {
        let tool = canvas.activeTool
        tool.mouseDown(at: point, modifiers: [], canvas: canvas)
        tool.mouseUp(at: point, modifiers: [], canvas: canvas)
    }

    // MARK: - Badge placement

    func testEachBadgeClickDropsTheNextNumber() {
        let (canvas, document, _) = makeCanvas()
        canvas.setActiveTool(.badge)

        click(canvas, at: CGPoint(x: 60, y: 60))
        XCTAssertEqual(document.annotations.count, 1)
        XCTAssertEqual(document.annotations[0].badgeNumber, 1)
        XCTAssertEqual(document.peekNextBadgeNumber(), 2)

        click(canvas, at: CGPoint(x: 120, y: 60))
        XCTAssertEqual(document.annotations.count, 2)
        XCTAssertEqual(document.annotations[1].badgeNumber, 2)
        XCTAssertEqual(document.peekNextBadgeNumber(), 3)

        // The tool stays active so 1, 2, 3 can be dropped without a detour to
        // the toolbar.
        XCTAssertEqual(canvas.activeTool.kind, .badge)
    }

    func testBadgeUsesTheInspectorColorAndRadiusNotTheStrokeColor() {
        let (canvas, document, settings) = makeCanvas()
        settings.style.strokeColor = .red
        settings.badgeColor = .blue
        settings.badgeRadius = 20
        canvas.setActiveTool(.badge)

        click(canvas, at: CGPoint(x: 100, y: 100))

        let badge = try? XCTUnwrap(document.annotations.first)
        XCTAssertEqual(badge?.style.strokeColor, .blue)
        XCTAssertEqual(badge?.style.badgeRadius, 20)
    }

    func testDraggingBeforeReleaseMovesTheBadgeAndKeepsOneUndoStep() {
        let (canvas, document, _) = makeCanvas()
        canvas.setActiveTool(.badge)
        let tool = canvas.activeTool

        tool.mouseDown(at: CGPoint(x: 50, y: 50), modifiers: [], canvas: canvas)
        tool.mouseDragged(at: CGPoint(x: 90, y: 70), modifiers: [], canvas: canvas)
        tool.mouseUp(at: CGPoint(x: 120, y: 80), modifiers: [], canvas: canvas)

        XCTAssertEqual(document.annotations.count, 1)
        if case .badge(let center, let number) = document.annotations[0].kind {
            XCTAssertEqual(center, CGPoint(x: 120, y: 80))
            XCTAssertEqual(number, 1)
        } else {
            XCTFail("expected a badge annotation")
        }

        // Placing and nudging is one edit, so a single undo clears it.
        document.undoManager.undo()
        XCTAssertTrue(document.annotations.isEmpty)
    }

    // MARK: - Badge counter and undo

    func testUndoingTheSecondBadgePutsTheCounterBackToTwo() {
        let (canvas, document, _) = makeCanvas()
        canvas.setActiveTool(.badge)

        click(canvas, at: CGPoint(x: 60, y: 60))
        click(canvas, at: CGPoint(x: 160, y: 60))
        XCTAssertEqual(document.peekNextBadgeNumber(), 3)

        document.undoManager.undo()

        XCTAssertEqual(document.annotations.count, 1)
        XCTAssertEqual(document.peekNextBadgeNumber(), 2,
                       "undoing a badge must hand its number back")

        // And the next click really does reuse 2 rather than skipping to 3.
        click(canvas, at: CGPoint(x: 200, y: 120))
        XCTAssertEqual(document.annotations.last?.badgeNumber, 2)
    }

    func testTheCounterStartsAtOneForEveryDocument() {
        let (_, first, _) = makeCanvas()
        XCTAssertEqual(first.peekNextBadgeNumber(), 1)
        let (_, second, _) = makeCanvas()
        XCTAssertEqual(second.peekNextBadgeNumber(), 1)
    }

    // MARK: - Renumbering

    func testRenumberResequencesAfterTheMiddleBadgeIsDeleted() {
        let (canvas, document, _) = makeCanvas()
        canvas.setActiveTool(.badge)

        click(canvas, at: CGPoint(x: 40, y: 40))
        click(canvas, at: CGPoint(x: 100, y: 40))
        click(canvas, at: CGPoint(x: 160, y: 40))
        XCTAssertEqual(document.annotations.compactMap(\.badgeNumber), [1, 2, 3])

        let middle = document.annotations[1]
        document.remove(ids: [middle.id])

        // Deleting deliberately leaves the gap (Greenshot behaviour).
        XCTAssertEqual(document.annotations.compactMap(\.badgeNumber), [1, 3])

        document.renumberBadges()
        XCTAssertEqual(document.annotations.compactMap(\.badgeNumber), [1, 2])
        XCTAssertEqual(document.peekNextBadgeNumber(), 3)

        document.undoManager.undo()
        XCTAssertEqual(document.annotations.compactMap(\.badgeNumber), [1, 3])
    }

    // MARK: - Text tool

    func testTextToolDragOpensAnEditorAndCommitsWhatWasTyped() {
        let (canvas, document, _) = makeCanvas()
        canvas.setActiveTool(.text)
        let tool = canvas.activeTool

        tool.mouseDown(at: CGPoint(x: 40, y: 40), modifiers: [], canvas: canvas)
        tool.mouseDragged(at: CGPoint(x: 200, y: 80), modifiers: [], canvas: canvas)
        tool.mouseUp(at: CGPoint(x: 200, y: 80), modifiers: [], canvas: canvas)

        let session = try? XCTUnwrap(canvas.textEditingSession)
        XCTAssertNotNil(session)
        // Nothing is in the document until the edit is committed.
        XCTAssertTrue(document.annotations.isEmpty)

        session?.setString("Hello")
        session?.commit()

        XCTAssertNil(canvas.textEditingSession)
        XCTAssertEqual(document.annotations.count, 1)
        if case .text(let rect, let string) = document.annotations[0].kind {
            XCTAssertEqual(string, "Hello")
            XCTAssertEqual(rect.origin.x, 40, accuracy: 0.5)
            XCTAssertEqual(rect.origin.y, 40, accuracy: 0.5)
            XCTAssertGreaterThan(rect.width, 0)
            XCTAssertGreaterThan(rect.height, 0)
        } else {
            XCTFail("expected a text annotation")
        }
    }

    func testCommittingAnEmptyNewTextAddsNothing() {
        let (canvas, document, _) = makeCanvas()
        canvas.setActiveTool(.text)
        click(canvas, at: CGPoint(x: 100, y: 100))

        let session = try? XCTUnwrap(canvas.textEditingSession)
        session?.commit()

        XCTAssertTrue(document.annotations.isEmpty)
        XCTAssertFalse(document.undoManager.canUndo,
                       "an abandoned text box must not leave an undo step")
    }

    func testCommittingAnEmptyStringRemovesAnExistingTextAnnotation() {
        let (canvas, document, _) = makeCanvas()
        let annotation = Annotation(kind: .text(rect: CGRect(x: 50, y: 50, width: 120, height: 24),
                                                string: "Delete me"))
        document.add(annotation)
        canvas.setActiveTool(.select)

        let handler = canvas.activeTool as? DoubleClickHandling
        XCTAssertNotNil(handler, "the Select tool has to handle double clicks")
        XCTAssertTrue(handler?.doubleClick(at: CGPoint(x: 80, y: 60),
                                           modifiers: [], canvas: canvas) ?? false)

        let session = try? XCTUnwrap(canvas.textEditingSession)
        session?.setString("")
        session?.commit()

        XCTAssertTrue(document.annotations.isEmpty)
    }

    func testDoubleClickReEditKeepsTheOriginalTextUndoable() {
        let (canvas, document, _) = makeCanvas()
        let annotation = Annotation(kind: .text(rect: CGRect(x: 50, y: 50, width: 120, height: 24),
                                                string: "before"))
        document.add(annotation)
        canvas.setActiveTool(.select)

        let handler = canvas.activeTool as? DoubleClickHandling
        _ = handler?.doubleClick(at: CGPoint(x: 80, y: 60), modifiers: [], canvas: canvas)

        // The document copy is blanked while the overlay shows the text, so it
        // is never drawn twice.
        if case .text(_, let live) = document.annotations[0].kind {
            XCTAssertEqual(live, "")
        }

        canvas.textEditingSession?.setString("after")
        canvas.textEditingSession?.commit()

        if case .text(_, let committed) = document.annotations[0].kind {
            XCTAssertEqual(committed, "after")
        } else {
            XCTFail("expected a text annotation")
        }

        // One undo step for the whole edit, back to the original string.
        document.undoManager.undo()
        if case .text(_, let restored) = document.annotations[0].kind {
            XCTAssertEqual(restored, "before")
        } else {
            XCTFail("expected the original text annotation back")
        }
    }

    func testSwitchingToolsCommitsAnOpenTextEditor() {
        let (canvas, document, _) = makeCanvas()
        canvas.setActiveTool(.text)
        click(canvas, at: CGPoint(x: 100, y: 100))
        canvas.textEditingSession?.setString("kept")

        canvas.setActiveTool(.select)

        XCTAssertNil(canvas.textEditingSession)
        XCTAssertEqual(document.annotations.count, 1)
        if case .text(_, let string) = document.annotations[0].kind {
            XCTAssertEqual(string, "kept")
        }
    }

    func testFontSizeChangeAppliesToSelectedTextAsOneUndoStep() {
        let (_, document, _) = makeCanvas()
        var annotation = Annotation(kind: .text(rect: CGRect(x: 10, y: 10, width: 80, height: 20),
                                                string: "size me"))
        annotation.style.fontSize = 18
        document.add(annotation)
        document.selectedIDs = [annotation.id]

        document.applyStyleToSelection(actionName: "Change Font Size") { style in
            style.fontSize = 36
        }
        XCTAssertEqual(document.annotations[0].style.fontSize, 36)

        document.undoManager.undo()
        XCTAssertEqual(document.annotations[0].style.fontSize, 18)
    }

    // MARK: - Badge rendering

    func testBadgeDrawsWhiteDigitsInsideAColouredCircle() throws {
        let image = TestSupport.makeImage(width: 200, height: 200, color: .black)
        let document = EditorDocument(image: image)
        var style = AnnotationStyle()
        style.strokeColor = .red
        style.badgeRadius = 20
        document.add(Annotation(kind: .badge(center: CGPoint(x: 100, y: 100), number: 12),
                                style: style))

        let rendered = try XCTUnwrap(Renderer.renderImage(document: document))
        let buffer = TestSupport.pixels(of: rendered)

        // The digits are white and sit in the middle of the circle.
        var whiteNearCentre = 0
        for y in 90..<110 {
            for x in 90..<110 where pixel(buffer, x: x, y: y).isWhite {
                whiteNearCentre += 1
            }
        }
        XCTAssertGreaterThan(whiteNearCentre, 10, "two digits should paint white pixels")

        // The rim is the badge colour, not the base image.
        XCTAssertTrue(pixel(buffer, x: 117, y: 100).isRedish)
        XCTAssertTrue(pixel(buffer, x: 83, y: 100).isRedish)
        XCTAssertTrue(pixel(buffer, x: 100, y: 117).isRedish)

        // And just outside it, the untouched base image.
        let outside = pixel(buffer, x: 100, y: 140)
        XCTAssertLessThan(Int(outside.r), 40)
    }

    func testThreeDigitBadgeShrinksToFitInsideTheCircle() throws {
        let image = TestSupport.makeImage(width: 120, height: 120, color: .black)
        let document = EditorDocument(image: image)
        var style = AnnotationStyle()
        style.strokeColor = .red
        style.badgeRadius = 14   // the smallest size that must still fit two digits
        let centre = CGPoint(x: 60, y: 60)
        document.add(Annotation(kind: .badge(center: centre, number: 123), style: style))

        let rendered = try XCTUnwrap(Renderer.renderImage(document: document))
        let buffer = TestSupport.pixels(of: rendered)

        var white = 0
        for y in 0..<buffer.height {
            for x in 0..<buffer.width where pixel(buffer, x: x, y: y).isWhite {
                white += 1
                let distance = hypot(CGFloat(x) + 0.5 - centre.x, CGFloat(y) + 0.5 - centre.y)
                XCTAssertLessThanOrEqual(distance, style.badgeRadius,
                                         "digit pixel at (\(x), \(y)) spills out of the badge")
            }
        }
        XCTAssertGreaterThan(white, 10, "three digits should still be drawn")
    }

    /// Two digits have to fit at the default radius as well.
    func testTwoDigitBadgeFitsAtTheDefaultRadius() throws {
        let image = TestSupport.makeImage(width: 120, height: 120, color: .black)
        let document = EditorDocument(image: image)
        var style = AnnotationStyle()
        style.strokeColor = .red
        style.badgeRadius = 14
        let centre = CGPoint(x: 60, y: 60)
        document.add(Annotation(kind: .badge(center: centre, number: 12), style: style))

        let rendered = try XCTUnwrap(Renderer.renderImage(document: document))
        let buffer = TestSupport.pixels(of: rendered)

        var white = 0
        for y in 0..<buffer.height {
            for x in 0..<buffer.width where pixel(buffer, x: x, y: y).isWhite {
                white += 1
                let distance = hypot(CGFloat(x) + 0.5 - centre.x, CGFloat(y) + 0.5 - centre.y)
                XCTAssertLessThanOrEqual(distance, style.badgeRadius,
                                         "digit pixel at (\(x), \(y)) spills out of the badge")
            }
        }
        XCTAssertGreaterThan(white, 10)
    }

    // MARK: Pixel helper

    private func pixel(_ buffer: (width: Int, height: Int, data: [UInt8]),
                       x: Int, y: Int) -> TestSupport.RGBA {
        let offset = (y * buffer.width + x) * 4
        return TestSupport.RGBA(r: buffer.data[offset],
                                g: buffer.data[offset + 1],
                                b: buffer.data[offset + 2],
                                a: buffer.data[offset + 3])
    }
}

// MARK: - Font size changes (added after the first real use)

@MainActor
final class TextFontSizeTests: XCTestCase {

    func testFontSizeChangeRefitsTextBoxAndRendersLarger() throws {
        let document = EditorDocument(image: TestSupport.makeImage(width: 400, height: 300))
        let small = AnnotationStyle(strokeColor: .red, strokeWidth: 3, fontSize: 20, badgeRadius: 26)
        let smallSize = Renderer.measureText("Hello", style: small)
        let text = Annotation(kind: .text(rect: CGRect(origin: CGPoint(x: 10, y: 10), size: smallSize),
                                          string: "Hello"), style: small)
        document.add(text)
        document.selectedIDs = [text.id]

        document.applyStyleToSelection(actionName: "Change Font Size") { style in
            style.fontSize = 60
        }

        let updated = try XCTUnwrap(document.annotation(withID: text.id))
        XCTAssertEqual(updated.style.fontSize, 60)
        guard case .text(let rect, _) = updated.kind else { return XCTFail("not text") }
        XCTAssertGreaterThan(rect.width, smallSize.width)
        XCTAssertGreaterThan(rect.height, smallSize.height)

        document.undoManager.undo()
        XCTAssertEqual(document.annotation(withID: text.id)?.style.fontSize, 20)
    }

    func testMeasureTextGrowsWithFont() {
        let a = Renderer.measureText("Hello", style: AnnotationStyle(fontSize: 20))
        let b = Renderer.measureText("Hello", style: AnnotationStyle(fontSize: 40))
        XCTAssertGreaterThan(b.width, a.width)
        XCTAssertGreaterThan(b.height, a.height)
    }
}
