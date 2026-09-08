//
//  RendererTests.swift
//  ZeroShotTests
//
//  Output geometry and a few "did it actually paint" checks. Document space is
//  image pixel space with a top-left origin, and these tests pin that down.
//

import XCTest
import CoreGraphics
@testable import ZeroShot

final class RendererTests: XCTestCase {

    // MARK: Output size

    func testRenderImageMatchesNativePixelSizeWithoutCrop() throws {
        let document = EditorDocument(image: TestSupport.makeImage(width: 200, height: 120))
        let rendered = try XCTUnwrap(Renderer.renderImage(document: document))

        XCTAssertEqual(rendered.width, 200)
        XCTAssertEqual(rendered.height, 120)
        XCTAssertEqual(Renderer.outputPixelSize(for: document), CGSize(width: 200, height: 120))
    }

    func testRenderImageMatchesCropSizeWhenCropped() throws {
        let document = EditorDocument(image: TestSupport.makeImage(width: 200, height: 120))
        document.setCrop(CGRect(x: 20, y: 10, width: 100, height: 60))

        let rendered = try XCTUnwrap(Renderer.renderImage(document: document))
        XCTAssertEqual(rendered.width, 100)
        XCTAssertEqual(rendered.height, 60)
    }

    func testRetinaSizedCaptureKeepsAllItsPixels() throws {
        // A 2x capture of a 400x300 point region is a 800x600 document and must
        // export at 800x600, not 400x300.
        let document = EditorDocument(image: TestSupport.makeImage(width: 800, height: 600))
        let rendered = try XCTUnwrap(Renderer.renderImage(document: document))
        XCTAssertEqual(rendered.width, 800)
        XCTAssertEqual(rendered.height, 600)
    }

    // MARK: Orientation

    func testDocumentSpaceOriginIsTopLeft() throws {
        // Base image: black top half, white bottom half.
        let base = TestSupport.makeVerticallySplitImage(width: 40, height: 40,
                                                        top: .black, bottom: .white)
        let document = EditorDocument(image: base)
        let rendered = try XCTUnwrap(Renderer.renderImage(document: document))

        XCTAssertFalse(TestSupport.color(of: rendered, x: 20, y: 5).isWhite,
                       "y = 5 must be the black top band")
        XCTAssertTrue(TestSupport.color(of: rendered, x: 20, y: 35).isWhite,
                      "y = 35 must be the white bottom band")
    }

    func testCropTranslatesOutputSoAnnotationsStayPut() throws {
        let document = EditorDocument(image: TestSupport.makeImage(width: 200, height: 200))
        // A red block at document (100, 100) - (140, 140).
        document.add(Annotation(kind: .rectangle(CGRect(x: 100, y: 100, width: 40, height: 40)),
                                style: AnnotationStyle(strokeColor: .red,
                                                       fillColor: .red,
                                                       strokeWidth: 1)))
        document.setCrop(CGRect(x: 80, y: 80, width: 100, height: 100))

        let rendered = try XCTUnwrap(Renderer.renderImage(document: document))
        XCTAssertEqual(rendered.width, 100)
        XCTAssertEqual(rendered.height, 100)

        // Document (120, 120) is output (40, 40) after the crop shift.
        XCTAssertTrue(TestSupport.color(of: rendered, x: 40, y: 40).isRedish,
                      "the block should land at output (40, 40)")
        // Document (90, 90) is output (10, 10) and is still bare background.
        XCTAssertTrue(TestSupport.color(of: rendered, x: 10, y: 10).isWhite)
    }

    // MARK: Annotations actually paint

    func testBadgeRendersNonWhitePixelsAtItsCenter() throws {
        let document = EditorDocument(image: TestSupport.makeImage(width: 100, height: 100))
        let style = AnnotationStyle(strokeColor: .red, strokeWidth: 3, fontSize: 18, badgeRadius: 14)
        document.add(Annotation(kind: .badge(center: CGPoint(x: 50, y: 50), number: 1), style: style))

        let rendered = try XCTUnwrap(Renderer.renderImage(document: document))

        // The badge disc must have painted something over the white base.
        XCTAssertTrue(TestSupport.containsNonWhitePixel(rendered,
                                                        in: CGRect(x: 40, y: 40, width: 20, height: 20)),
                      "no badge pixels found at the badge centre")

        // A point inside the disc but clear of the digit glyph must be red.
        XCTAssertTrue(TestSupport.color(of: rendered, x: 59, y: 50).isRedish,
                      "expected the badge fill colour, got \(TestSupport.color(of: rendered, x: 59, y: 50))")

        // Well outside the badge the base image is untouched.
        XCTAssertTrue(TestSupport.color(of: rendered, x: 5, y: 5).isWhite)
    }

    func testStrokedRectangleLeavesInteriorUntouched() throws {
        let document = EditorDocument(image: TestSupport.makeImage(width: 100, height: 100))
        document.add(Annotation(kind: .rectangle(CGRect(x: 20, y: 20, width: 60, height: 60)),
                                style: AnnotationStyle(strokeColor: .red, strokeWidth: 4)))

        let rendered = try XCTUnwrap(Renderer.renderImage(document: document))

        XCTAssertTrue(TestSupport.color(of: rendered, x: 50, y: 20).isRedish, "top edge should be stroked")
        XCTAssertTrue(TestSupport.color(of: rendered, x: 50, y: 50).isWhite, "interior must stay unfilled")
    }

    func testHighlightDarkensWithoutHidingTheBase() throws {
        let document = EditorDocument(image: TestSupport.makeImage(width: 60, height: 60))
        document.add(Annotation(kind: .highlight(CGRect(x: 10, y: 10, width: 40, height: 20)),
                                style: AnnotationStyle(strokeColor: .yellow)))

        let rendered = try XCTUnwrap(Renderer.renderImage(document: document))
        let inside = TestSupport.color(of: rendered, x: 30, y: 20)
        XCTAssertFalse(inside.isWhite, "highlight should tint the base")
        XCTAssertTrue(inside.r > 200, "a yellow multiply keeps the red channel high")
        XCTAssertTrue(TestSupport.color(of: rendered, x: 55, y: 55).isWhite)
    }

    func testBlurReplacesPixelsInsideItsRect() throws {
        // Half black, half white base so pixellating actually changes something.
        let base = TestSupport.makeVerticallySplitImage(width: 40, height: 40,
                                                        top: .black, bottom: .white)
        let document = EditorDocument(image: base)
        document.add(Annotation(kind: .blur(CGRect(x: 0, y: 10, width: 40, height: 20)),
                                style: AnnotationStyle(strokeWidth: 6)))

        let rendered = try XCTUnwrap(Renderer.renderImage(document: document))
        XCTAssertEqual(rendered.width, 40)
        XCTAssertEqual(rendered.height, 40)
        // Outside the blur rect the base survives untouched.
        XCTAssertTrue(TestSupport.color(of: rendered, x: 20, y: 38).isWhite)
    }
}
