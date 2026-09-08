//
//  AnnotationTests.swift
//  ZeroShotTests
//
//  Geometry and document-mutation tests. All coordinates are document space
//  (image pixels, top-left origin).
//

import XCTest
import CoreGraphics
@testable import ZeroShot

final class AnnotationTests: XCTestCase {

    // MARK: Hit testing

    func testLineHitTestUsesStrokeProximityNotBoundingBox() {
        // Diagonal from (0,0) to (100,100), 2pt stroke.
        let style = AnnotationStyle(strokeWidth: 2)
        let line = Annotation(kind: .line(from: CGPoint(x: 0, y: 0),
                                          to: CGPoint(x: 100, y: 100)),
                              style: style)

        // On the line.
        XCTAssertTrue(line.hitTest(CGPoint(x: 50, y: 50), tolerance: 2))
        // Just beside the line, inside tolerance.
        XCTAssertTrue(line.hitTest(CGPoint(x: 52, y: 50), tolerance: 3))
        // Inside the bounding box but far from the stroke: must miss.
        XCTAssertFalse(line.hitTest(CGPoint(x: 90, y: 10), tolerance: 4))
        // Past the end of the segment: must miss.
        XCTAssertFalse(line.hitTest(CGPoint(x: 120, y: 120), tolerance: 4))
    }

    func testRectangleHitTestUsesContainment() {
        let rect = Annotation(kind: .rectangle(CGRect(x: 10, y: 10, width: 100, height: 50)))
        XCTAssertTrue(rect.hitTest(CGPoint(x: 60, y: 30)))
        XCTAssertFalse(rect.hitTest(CGPoint(x: 200, y: 30)))
    }

    func testBadgeHitTestIsCircular() {
        let style = AnnotationStyle(badgeRadius: 14)
        let badge = Annotation(kind: .badge(center: CGPoint(x: 50, y: 50), number: 1), style: style)
        XCTAssertTrue(badge.hitTest(CGPoint(x: 50, y: 60), tolerance: 0))
        // Corner of the bounding box is outside the circle.
        XCTAssertFalse(badge.hitTest(CGPoint(x: 63, y: 63), tolerance: 0))
    }

    func testPathHitTestFollowsTheStroke() {
        let path = Annotation(kind: .path([CGPoint(x: 0, y: 0),
                                           CGPoint(x: 50, y: 0),
                                           CGPoint(x: 50, y: 50)]))
        XCTAssertTrue(path.hitTest(CGPoint(x: 25, y: 0), tolerance: 2))
        XCTAssertTrue(path.hitTest(CGPoint(x: 50, y: 25), tolerance: 2))
        XCTAssertFalse(path.hitTest(CGPoint(x: 10, y: 40), tolerance: 2))
    }

    // MARK: Translation

    func testTranslatedMovesEveryKindAndKeepsIdentity() {
        let offset = CGPoint(x: 10, y: -5)

        let rect = Annotation(kind: .rectangle(CGRect(x: 0, y: 0, width: 20, height: 20)))
        let movedRect = rect.translated(by: offset)
        XCTAssertEqual(movedRect.id, rect.id, "translation must not change identity")
        XCTAssertEqual(movedRect.kind, .rectangle(CGRect(x: 10, y: -5, width: 20, height: 20)))

        let arrow = Annotation(kind: .arrow(from: CGPoint(x: 1, y: 2), to: CGPoint(x: 3, y: 4)))
        XCTAssertEqual(arrow.translated(by: offset).kind,
                       .arrow(from: CGPoint(x: 11, y: -3), to: CGPoint(x: 13, y: -1)))

        let badge = Annotation(kind: .badge(center: CGPoint(x: 5, y: 5), number: 7))
        XCTAssertEqual(badge.translated(by: offset).kind,
                       .badge(center: CGPoint(x: 15, y: 0), number: 7))

        let path = Annotation(kind: .path([CGPoint(x: 0, y: 0), CGPoint(x: 2, y: 2)]))
        XCTAssertEqual(path.translated(by: offset).kind,
                       .path([CGPoint(x: 10, y: -5), CGPoint(x: 12, y: -3)]))
    }

    func testBoundingRectIncludesStrokeAndBadgeRadius() {
        let line = Annotation(kind: .line(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 10, y: 0)),
                              style: AnnotationStyle(strokeWidth: 4))
        XCTAssertEqual(line.boundingRect, CGRect(x: -2, y: -2, width: 14, height: 4))

        let badge = Annotation(kind: .badge(center: CGPoint(x: 30, y: 30), number: 2),
                               style: AnnotationStyle(badgeRadius: 10))
        XCTAssertEqual(badge.boundingRect, CGRect(x: 20, y: 20, width: 20, height: 20))
    }

    // MARK: Codable

    func testAnnotationRoundTripsThroughJSON() throws {
        let original = Annotation(kind: .text(rect: CGRect(x: 1, y: 2, width: 30, height: 12),
                                              string: "hello"),
                                  style: AnnotationStyle(strokeColor: .blue,
                                                         fillColor: .yellow,
                                                         strokeWidth: 5,
                                                         fontSize: 22,
                                                         badgeRadius: 9))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Annotation.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: Document

    func testAddRegistersUndoAndBumpsBadgeCounter() {
        let document = EditorDocument(image: TestSupport.makeImage(width: 40, height: 40))
        XCTAssertEqual(document.nextBadgeNumber, 1)

        document.add(Annotation(kind: .badge(center: CGPoint(x: 10, y: 10),
                                             number: document.peekNextBadgeNumber())))
        XCTAssertEqual(document.annotations.count, 1)
        XCTAssertEqual(document.nextBadgeNumber, 2)
        XCTAssertTrue(document.hasUnsavedChanges)

        document.undoManager.undo()
        XCTAssertEqual(document.annotations.count, 0)
        XCTAssertEqual(document.nextBadgeNumber, 1)

        document.undoManager.redo()
        XCTAssertEqual(document.annotations.count, 1)
        XCTAssertEqual(document.nextBadgeNumber, 2)
    }

    func testSetCropClampsToImageAndUndoes() {
        let document = EditorDocument(image: TestSupport.makeImage(width: 100, height: 80))
        XCTAssertEqual(document.outputRect, CGRect(x: 0, y: 0, width: 100, height: 80))

        document.setCrop(CGRect(x: 10, y: 10, width: 500, height: 500))
        XCTAssertEqual(document.outputRect, CGRect(x: 10, y: 10, width: 90, height: 70))

        document.undoManager.undo()
        XCTAssertNil(document.cropRect)
        XCTAssertEqual(document.outputRect, CGRect(x: 0, y: 0, width: 100, height: 80))
    }

    func testRenumberBadgesResequencesByDrawOrder() {
        let document = EditorDocument(image: TestSupport.makeImage(width: 60, height: 60))
        document.add(Annotation(kind: .badge(center: CGPoint(x: 5, y: 5), number: 1)))
        document.add(Annotation(kind: .rectangle(CGRect(x: 0, y: 0, width: 5, height: 5))))
        document.add(Annotation(kind: .badge(center: CGPoint(x: 15, y: 5), number: 2)))
        document.add(Annotation(kind: .badge(center: CGPoint(x: 25, y: 5), number: 3)))

        // Delete the middle badge: the others keep their numbers (Greenshot).
        let second = document.annotations[2]
        document.remove(second)
        XCTAssertEqual(document.annotations.compactMap(\.badgeNumber), [1, 3])

        document.renumberBadges()
        XCTAssertEqual(document.annotations.compactMap(\.badgeNumber), [1, 2])
        XCTAssertEqual(document.nextBadgeNumber, 3)
    }

    func testDocumentHitTestReturnsTopmost() {
        let document = EditorDocument(image: TestSupport.makeImage(width: 100, height: 100))
        let bottom = Annotation(kind: .rectangle(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let top = Annotation(kind: .rectangle(CGRect(x: 20, y: 20, width: 20, height: 20)))
        document.add(bottom)
        document.add(top)

        XCTAssertEqual(document.hitTest(CGPoint(x: 30, y: 30))?.id, top.id)
        XCTAssertEqual(document.hitTest(CGPoint(x: 90, y: 90))?.id, bottom.id)
        XCTAssertNil(document.hitTest(CGPoint(x: 500, y: 500)))
    }
}
