//
//  CanvasGeometryTests.swift
//  ZeroShotTests
//
//  Canvas geometry and tool behaviour, with no UI presentation: the CanvasView
//  is built offscreen with an explicit frame and driven by calling the tool
//  protocol directly, the same way real mouse events reach it.
//
//  All document coordinates are image pixels, top-left origin.
//

import AppKit
import CoreGraphics
import XCTest
@testable import ZeroShot

@MainActor
final class CanvasGeometryTests: XCTestCase {

    // MARK: Fixtures

    private func makeCanvas(documentSize: CGSize = CGSize(width: 400, height: 300),
                            viewSize: CGSize = CGSize(width: 800, height: 600),
                            zoom: CGFloat = 1)
    -> (CanvasView, EditorDocument, CanvasSettings) {
        let image = TestSupport.makeImage(width: Int(documentSize.width),
                                          height: Int(documentSize.height))
        let document = EditorDocument(image: image)
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

    // MARK: - Coordinate conversion

    func testViewToDocumentRoundTripAtSeveralZoomFactors() {
        for zoom in [CGFloat(0.25), 0.5, 1, 2] {
            let (canvas, _, _) = makeCanvas(zoom: zoom)
            let documentPoints = [CGPoint(x: 0, y: 0),
                                  CGPoint(x: 133, y: 77),
                                  CGPoint(x: 400, y: 300)]
            for point in documentPoints {
                let back = canvas.documentPoint(fromView: canvas.viewPoint(fromDocument: point))
                XCTAssertEqual(back.x, point.x, accuracy: 0.001, "zoom \(zoom)")
                XCTAssertEqual(back.y, point.y, accuracy: 0.001, "zoom \(zoom)")
            }
        }
    }

    func testDocumentOriginMapsToCentredImageOrigin() {
        // 400x300 document at 1:1 inside an 800x600 view is centred: (200, 150).
        let (canvas, _, _) = makeCanvas(zoom: 1)
        XCTAssertEqual(canvas.imageOrigin, CGPoint(x: 200, y: 150))
        XCTAssertEqual(canvas.viewPoint(fromDocument: .zero), CGPoint(x: 200, y: 150))
        XCTAssertEqual(canvas.documentPoint(fromView: CGPoint(x: 200, y: 150)), .zero)
    }

    func testConversionScalesWithZoomAndKeepsTopLeftOrientation() {
        let (canvas, _, _) = makeCanvas(zoom: 0.5)
        // Content is 200x150 in an 800x600 view, so the origin is (300, 225).
        XCTAssertEqual(canvas.imageOrigin, CGPoint(x: 300, y: 225))

        let view = canvas.viewPoint(fromDocument: CGPoint(x: 100, y: 100))
        XCTAssertEqual(view.x, 350, accuracy: 0.001)
        XCTAssertEqual(view.y, 275, accuracy: 0.001)

        // +y is DOWN in both spaces: a larger document y is a larger view y.
        let lower = canvas.viewPoint(fromDocument: CGPoint(x: 100, y: 200))
        XCTAssertGreaterThan(lower.y, view.y)
    }

    func testConversionAccountsForACrop() {
        let (canvas, document, _) = makeCanvas(zoom: 1)
        document.setCrop(CGRect(x: 50, y: 40, width: 200, height: 150))
        canvas.setZoom(1)

        // The crop origin, not the image origin, sits at the top-left of the
        // drawn area.
        XCTAssertEqual(canvas.viewPoint(fromDocument: CGPoint(x: 50, y: 40)), canvas.imageOrigin)
        let centre = canvas.documentPoint(fromView: canvas.imageOrigin)
        XCTAssertEqual(centre.x, 50, accuracy: 0.001)
        XCTAssertEqual(centre.y, 40, accuracy: 0.001)
    }

    func testLengthConversionIsTheInverseOfZoom() {
        let (canvas, _, _) = makeCanvas(zoom: 2)
        XCTAssertEqual(canvas.viewLength(fromDocument: 10), 20, accuracy: 0.001)
        XCTAssertEqual(canvas.documentLength(fromView: 10), 5, accuracy: 0.001)
    }

    // MARK: - Zoom

    func testFitToWindowMakesARetinaCaptureFitTheView() {
        // A 2880x1800 (2x) capture in a modest 1000x700 point window.
        let (canvas, _, _) = makeCanvas(documentSize: CGSize(width: 2880, height: 1800),
                                        viewSize: CGSize(width: 1000, height: 700))
        canvas.zoomToFit()

        XCTAssertLessThanOrEqual(canvas.contentSize.width, 1000)
        XCTAssertLessThanOrEqual(canvas.contentSize.height, 700)
        XCTAssertGreaterThan(canvas.zoom, 0)
    }

    func testActualSizeIsOneImagePixelPerScreenPixel() {
        let (canvas, _, _) = makeCanvas(documentSize: CGSize(width: 2880, height: 1800),
                                        viewSize: CGSize(width: 1000, height: 700))
        canvas.zoomToActualSize()
        XCTAssertEqual(canvas.zoom, canvas.actualSizeZoom, accuracy: 0.0001)
        XCTAssertEqual(canvas.zoomPercent, 100)
    }

    func testZoomInAndOutAreInverse() {
        let (canvas, _, _) = makeCanvas(zoom: 1)
        canvas.zoomIn()
        canvas.zoomOut()
        XCTAssertEqual(canvas.zoom, 1, accuracy: 0.0001)
    }

    // MARK: - Handle hit testing

    func testHandleHitTestingFindsTheEightBoxHandles() {
        let (canvas, document, _) = makeCanvas(zoom: 1)
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        let annotation = document.add(Annotation(kind: .rectangle(rect)))
        document.selectedIDs = [annotation.id]

        let expected: [SelectionHandle: CGPoint] = [
            .topLeft: CGPoint(x: 100, y: 100),
            .top: CGPoint(x: 200, y: 100),
            .topRight: CGPoint(x: 300, y: 100),
            .right: CGPoint(x: 300, y: 150),
            .bottomRight: CGPoint(x: 300, y: 200),
            .bottom: CGPoint(x: 200, y: 200),
            .bottomLeft: CGPoint(x: 100, y: 200),
            .left: CGPoint(x: 100, y: 150)
        ]
        for (handle, point) in expected {
            XCTAssertEqual(canvas.handle(atDocument: point)?.handle, handle,
                           "handle \(handle) at \(point)")
        }
    }

    func testHandleHitTestingMissesWhenNothingIsSelectedOrThePointIsFarAway() {
        let (canvas, document, _) = makeCanvas(zoom: 1)
        let annotation = document.add(Annotation(kind: .rectangle(CGRect(x: 100, y: 100,
                                                                        width: 200, height: 100))))

        // Not selected: no handles at all.
        XCTAssertNil(canvas.handle(atDocument: CGPoint(x: 100, y: 100)))

        document.selectedIDs = [annotation.id]
        XCTAssertNotNil(canvas.handle(atDocument: CGPoint(x: 100, y: 100)))
        XCTAssertNil(canvas.handle(atDocument: CGPoint(x: 160, y: 140)))
    }

    func testHandleGrabAreaGrowsWhenZoomedOut() {
        let (canvas, document, _) = makeCanvas(zoom: 1)
        let annotation = document.add(Annotation(kind: .rectangle(CGRect(x: 100, y: 100,
                                                                        width: 200, height: 100))))
        document.selectedIDs = [annotation.id]

        // 14 document pixels away: outside the 8pt grab box at 1:1...
        XCTAssertNil(canvas.handle(atDocument: CGPoint(x: 114, y: 100)))
        // ...but inside it at 25%, where 8 points cover 32 document pixels.
        canvas.setZoom(0.25)
        XCTAssertEqual(canvas.handle(atDocument: CGPoint(x: 114, y: 100))?.handle, .topLeft)
    }

    func testLineExposesTwoEndpointHandles() {
        let (canvas, document, _) = makeCanvas(zoom: 1)
        let annotation = document.add(Annotation(kind: .line(from: CGPoint(x: 20, y: 20),
                                                             to: CGPoint(x: 220, y: 120))))
        document.selectedIDs = [annotation.id]

        XCTAssertEqual(annotation.kind.selectionHandles, [.start, .end])
        XCTAssertEqual(canvas.handle(atDocument: CGPoint(x: 20, y: 20))?.handle, .start)
        XCTAssertEqual(canvas.handle(atDocument: CGPoint(x: 220, y: 120))?.handle, .end)
    }

    func testBadgeOffersNoResizeHandles() {
        let badge = Annotation(kind: .badge(center: CGPoint(x: 50, y: 50), number: 1))
        XCTAssertTrue(badge.kind.selectionHandles.isEmpty)
    }

    // MARK: - Creating shapes

    func testCreateDragAddsExactlyOneAnnotationInOneUndoStep() {
        let (canvas, document, _) = makeCanvas(zoom: 1)
        canvas.setActiveTool(.rectangle)
        XCTAssertFalse(document.undoManager.canUndo)

        drag(canvas, from: CGPoint(x: 20, y: 30), to: CGPoint(x: 120, y: 110), steps: 8)

        XCTAssertEqual(document.annotations.count, 1)
        XCTAssertEqual(document.annotations[0].kind.rectValue,
                       CGRect(x: 20, y: 30, width: 100, height: 80))
        // The new shape is selected and the tool stays active (Greenshot).
        XCTAssertEqual(document.selectedIDs, [document.annotations[0].id])
        XCTAssertEqual(canvas.activeTool.kind, .rectangle)

        // Exactly one undo step: one undo empties the document and there is
        // nothing left to undo.
        XCTAssertTrue(document.undoManager.canUndo)
        document.undoManager.undo()
        XCTAssertEqual(document.annotations.count, 0)
        XCTAssertFalse(document.undoManager.canUndo)
    }

    func testTinyDragIsDiscarded() {
        let (canvas, document, _) = makeCanvas(zoom: 1)
        canvas.setActiveTool(.rectangle)

        drag(canvas, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 51, y: 51), steps: 2)

        XCTAssertTrue(document.annotations.isEmpty)
        XCTAssertFalse(document.undoManager.canUndo)
    }

    func testShiftConstrainsARectangleToASquare() {
        let (canvas, document, _) = makeCanvas(zoom: 1)
        canvas.setActiveTool(.rectangle)

        drag(canvas, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 110, y: 50), modifiers: .shift)

        XCTAssertEqual(document.annotations.first?.kind.rectValue,
                       CGRect(x: 10, y: 10, width: 100, height: 100))
    }

    func testShiftSnapsALineTo45Degrees() {
        let (canvas, document, _) = makeCanvas(zoom: 1)
        canvas.setActiveTool(.line)

        // 10 degrees off horizontal snaps back to horizontal.
        drag(canvas, from: CGPoint(x: 10, y: 100), to: CGPoint(x: 110, y: 118), modifiers: .shift)

        guard let ends = document.annotations.first?.kind.endpoints else {
            return XCTFail("expected a line")
        }
        XCTAssertEqual(ends.from, CGPoint(x: 10, y: 100))
        XCTAssertEqual(ends.to.y, 100, accuracy: 0.001)
        XCTAssertGreaterThan(ends.to.x, 100)
    }

    func testEllipseAndArrowToolsProduceTheirOwnKinds() {
        let (canvas, document, _) = makeCanvas(zoom: 1)

        canvas.setActiveTool(.ellipse)
        drag(canvas, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 60))
        canvas.setActiveTool(.arrow)
        drag(canvas, from: CGPoint(x: 100, y: 10), to: CGPoint(x: 180, y: 60))

        XCTAssertEqual(document.annotations.count, 2)
        if case .ellipse = document.annotations[0].kind {} else { XCTFail("expected an ellipse") }
        if case .arrow = document.annotations[1].kind {} else { XCTFail("expected an arrow") }
    }

    func testNewShapeUsesTheCurrentInspectorStyle() {
        let (canvas, document, settings) = makeCanvas(zoom: 1)
        settings.style.strokeColor = .blue
        settings.style.strokeWidth = 7
        canvas.setActiveTool(.rectangle)

        drag(canvas, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 110, y: 90))

        XCTAssertEqual(document.annotations.first?.style.strokeColor, .blue)
        XCTAssertEqual(document.annotations.first?.style.strokeWidth, 7)
    }

    // MARK: - Select tool

    func testClickSelectsAndClickingEmptySpaceDeselects() {
        let (canvas, document, _) = makeCanvas(zoom: 1)
        let annotation = document.add(Annotation(kind: .rectangle(CGRect(x: 40, y: 40,
                                                                        width: 100, height: 60))))
        canvas.setActiveTool(.select)

        drag(canvas, from: CGPoint(x: 90, y: 70), to: CGPoint(x: 90, y: 70), steps: 1)
        XCTAssertEqual(document.selectedIDs, [annotation.id])

        drag(canvas, from: CGPoint(x: 300, y: 250), to: CGPoint(x: 300, y: 250), steps: 1)
        XCTAssertTrue(document.selectedIDs.isEmpty)
    }

    func testShiftClickExtendsTheSelection() {
        let (canvas, document, _) = makeCanvas(zoom: 1)
        let first = document.add(Annotation(kind: .rectangle(CGRect(x: 10, y: 10,
                                                                    width: 50, height: 50))))
        let second = document.add(Annotation(kind: .rectangle(CGRect(x: 100, y: 100,
                                                                     width: 50, height: 50))))
        canvas.setActiveTool(.select)

        drag(canvas, from: CGPoint(x: 35, y: 35), to: CGPoint(x: 35, y: 35), steps: 1)
        drag(canvas, from: CGPoint(x: 125, y: 125), to: CGPoint(x: 125, y: 125),
             steps: 1, modifiers: .shift)

        XCTAssertEqual(document.selectedIDs, [first.id, second.id])
    }

    func testMoveDragIsOneUndoStepNotOnePerMouseMove() {
        let (canvas, document, _) = makeCanvas(zoom: 1)
        let annotation = document.add(Annotation(kind: .rectangle(CGRect(x: 40, y: 40,
                                                                         width: 100, height: 60))))
        document.selectedIDs = [annotation.id]
        canvas.setActiveTool(.select)

        drag(canvas, from: CGPoint(x: 90, y: 70), to: CGPoint(x: 140, y: 100), steps: 20)

        XCTAssertEqual(document.annotations.first?.kind.rectValue,
                       CGRect(x: 90, y: 70, width: 100, height: 60))

        // One undo returns the whole drag; the second removes the annotation
        // that the setup added, so the drag really was a single step.
        document.undoManager.undo()
        XCTAssertEqual(document.annotations.first?.kind.rectValue,
                       CGRect(x: 40, y: 40, width: 100, height: 60))
        document.undoManager.undo()
        XCTAssertTrue(document.annotations.isEmpty)
    }

    func testClickWithoutMovementRegistersNoUndoStep() {
        let (canvas, document, _) = makeCanvas(zoom: 1)
        let annotation = document.add(Annotation(kind: .rectangle(CGRect(x: 40, y: 40,
                                                                         width: 100, height: 60))))
        document.selectedIDs = [annotation.id]
        canvas.setActiveTool(.select)
        document.undoManager.removeAllActions()

        drag(canvas, from: CGPoint(x: 90, y: 70), to: CGPoint(x: 90, y: 70), steps: 3)

        XCTAssertFalse(document.undoManager.canUndo)
    }

    func testHandleDragResizesInOneUndoStep() {
        let (canvas, document, _) = makeCanvas(zoom: 1)
        let annotation = document.add(Annotation(kind: .rectangle(CGRect(x: 40, y: 40,
                                                                         width: 100, height: 60))))
        document.selectedIDs = [annotation.id]
        canvas.setActiveTool(.select)
        document.undoManager.removeAllActions()

        // Grab the bottom-right handle at (140, 100) and pull it out.
        drag(canvas, from: CGPoint(x: 140, y: 100), to: CGPoint(x: 200, y: 160), steps: 10)

        XCTAssertEqual(document.annotations.first?.kind.rectValue,
                       CGRect(x: 40, y: 40, width: 160, height: 120))
        XCTAssertTrue(document.undoManager.canUndo)
        document.undoManager.undo()
        XCTAssertEqual(document.annotations.first?.kind.rectValue,
                       CGRect(x: 40, y: 40, width: 100, height: 60))
        XCTAssertFalse(document.undoManager.canUndo)
    }

    func testEndpointHandleDragMovesOnlyThatEnd() {
        let (canvas, document, _) = makeCanvas(zoom: 1)
        let annotation = document.add(Annotation(kind: .arrow(from: CGPoint(x: 20, y: 20),
                                                              to: CGPoint(x: 120, y: 120))))
        document.selectedIDs = [annotation.id]
        canvas.setActiveTool(.select)

        drag(canvas, from: CGPoint(x: 120, y: 120), to: CGPoint(x: 200, y: 60), steps: 6)

        guard let ends = document.annotations.first?.kind.endpoints else {
            return XCTFail("expected an arrow")
        }
        XCTAssertEqual(ends.from, CGPoint(x: 20, y: 20))
        XCTAssertEqual(ends.to, CGPoint(x: 200, y: 60))
    }

    func testRubberBandSelectsEverythingItTouches() {
        let (canvas, document, _) = makeCanvas(zoom: 1)
        let inside = document.add(Annotation(kind: .rectangle(CGRect(x: 20, y: 20,
                                                                     width: 40, height: 40))))
        let alsoInside = document.add(Annotation(kind: .rectangle(CGRect(x: 80, y: 30,
                                                                         width: 40, height: 40))))
        _ = document.add(Annotation(kind: .rectangle(CGRect(x: 300, y: 250,
                                                             width: 40, height: 40))))
        canvas.setActiveTool(.select)

        drag(canvas, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 150, y: 150), steps: 5)

        XCTAssertEqual(document.selectedIDs, [inside.id, alsoInside.id])
    }

    // MARK: - Keyboard driven edits

    func testNudgeMovesByOnePixelAndTenWithShift() {
        let (canvas, document, _) = makeCanvas(zoom: 1)
        let annotation = document.add(Annotation(kind: .rectangle(CGRect(x: 40, y: 40,
                                                                         width: 20, height: 20))))
        document.selectedIDs = [annotation.id]

        canvas.nudgeSelection(dx: 1, dy: 0, modifiers: [])
        XCTAssertEqual(document.annotations.first?.kind.rectValue?.minX, 41)

        canvas.nudgeSelection(dx: 0, dy: 1, modifiers: .shift)
        XCTAssertEqual(document.annotations.first?.kind.rectValue?.minY, 50)

        // Each press is its own undo step.
        document.undoManager.undo()
        XCTAssertEqual(document.annotations.first?.kind.rectValue?.minY, 40)
        XCTAssertEqual(document.annotations.first?.kind.rectValue?.minX, 41)
    }

    func testSelectAllAndDeselectAll() {
        let (canvas, document, _) = makeCanvas(zoom: 1)
        _ = document.add(Annotation(kind: .rectangle(CGRect(x: 0, y: 0, width: 10, height: 10))))
        _ = document.add(Annotation(kind: .rectangle(CGRect(x: 20, y: 0, width: 10, height: 10))))

        canvas.selectAll()
        XCTAssertEqual(canvas.document.selectedIDs.count, 2)
        canvas.deselectAll()
        XCTAssertTrue(canvas.document.selectedIDs.isEmpty)
    }

    // MARK: - Tool registry

    /// Every kind resolves to a tool that reports its own kind, and the tools
    /// that are meant to exist by now do exist. Deliberately a subset check
    /// rather than an equality check: each milestone adds registrations, and
    /// this test should not need touching every time one lands.
    func testEveryToolKindResolvesAndTheShippedToolsAreImplemented() {
        for kind in ToolKind.allCases {
            XCTAssertEqual(ToolRegistry.makeTool(for: kind).kind, kind)
        }
        let implemented = Set(ToolKind.allCases.filter { ToolRegistry.isImplemented($0) })
        let shipped: Set<ToolKind> = [.select, .rectangle, .ellipse, .arrow, .line, .badge, .text]
        XCTAssertTrue(shipped.isSubset(of: implemented),
                      "missing tools: \(shipped.subtracting(implemented))")
    }

    func testShortcutsCoverTheDocumentedKeys() {
        let expected: [Character: ToolKind] = [
            "v": .select, "c": .crop, "r": .rectangle, "e": .ellipse, "a": .arrow,
            "l": .line, "t": .text, "n": .badge, "h": .highlight, "b": .blur, "p": .pen
        ]
        for (character, kind) in expected {
            XCTAssertEqual(ToolKind.kind(forShortcut: character), kind)
            XCTAssertEqual(ToolKind.kind(forShortcut: Character(String(character).uppercased())), kind)
        }
    }
}
