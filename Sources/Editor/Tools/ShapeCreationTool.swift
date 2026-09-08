//
//  ShapeCreationTool.swift
//  ZeroShot
//
//  Shared behaviour for every "press, drag out a shape, release" tool.
//
//  Subclasses only implement `makeKind(from:to:constrained:)`. The base class
//  handles the live preview, the Shift constraint, the minimum drag distance,
//  the single undo step, and Greenshot's rule that the new shape becomes the
//  selection while the tool stays active.
//

import AppKit
import CoreGraphics
import Foundation

@MainActor
class ShapeCreationTool: CanvasTool {

    /// Drags shorter than this many POINTS on screen are treated as a stray
    /// click and thrown away, so a mis-click never litters the canvas.
    static let minimumDragPoints: CGFloat = 3

    var kind: ToolKind { .rectangle }

    var cursor: NSCursor { .crosshair }

    private var origin: CGPoint?
    private var current: CGPoint?
    private var isConstrained = false

    // MARK: Subclass hook

    /// Build the annotation geometry for a drag. `constrained` is Shift.
    func makeKind(from start: CGPoint, to end: CGPoint, constrained: Bool) -> AnnotationKind {
        .rectangle(AnnotationGeometry.rect(from: start, to: end))
    }

    /// Style for the new annotation. Rect-like tools drop the fill when the
    /// inspector's fill toggle is off; the default is stroke only.
    func style(for settings: CanvasSettings) -> AnnotationStyle {
        var style = settings.style
        if !kind.supportsFill { style.fillColor = nil }
        return style
    }

    // MARK: Mouse

    func mouseDown(at point: CGPoint, modifiers: NSEvent.ModifierFlags, canvas: CanvasView) {
        origin = point
        current = point
        isConstrained = modifiers.contains(.shift)
        canvas.needsDisplay = true
    }

    func mouseDragged(at point: CGPoint, modifiers: NSEvent.ModifierFlags, canvas: CanvasView) {
        guard origin != nil else { return }
        current = point
        isConstrained = modifiers.contains(.shift)
        canvas.needsDisplay = true
    }

    func mouseUp(at point: CGPoint, modifiers: NSEvent.ModifierFlags, canvas: CanvasView) {
        defer { reset(canvas: canvas) }
        guard let start = origin else { return }
        let constrained = modifiers.contains(.shift)

        // The threshold is in points, so it feels the same zoomed in or out.
        let threshold = canvas.documentLength(fromView: ShapeCreationTool.minimumDragPoints)
        guard hypot(point.x - start.x, point.y - start.y) >= threshold else { return }

        let annotation = Annotation(kind: makeKind(from: start, to: point, constrained: constrained),
                                    style: style(for: canvas.settings))
        // One undo step for the whole creation, and the shape lands selected.
        canvas.commitNewAnnotation(annotation)
    }

    func cancel(canvas: CanvasView) {
        reset(canvas: canvas)
    }

    // MARK: Overlay

    func draw(overlayIn ctx: CGContext, canvas: CanvasView) {
        guard let start = origin, let end = current else { return }
        guard hypot(end.x - start.x, end.y - start.y) > 0.5 else { return }

        // The preview is the real thing: build a throwaway annotation and let
        // `Renderer` draw it, so what you drag is what you get.
        let preview = Annotation(kind: makeKind(from: start, to: end, constrained: isConstrained),
                                 style: style(for: canvas.settings))

        ctx.saveGState()
        ctx.clip(to: canvas.contentRect)
        canvas.applyDocumentTransform(to: ctx)
        Renderer.drawPreview(preview, document: canvas.document, in: ctx)
        ctx.restoreGState()
    }

    private func reset(canvas: CanvasView) {
        origin = nil
        current = nil
        isConstrained = false
        canvas.needsDisplay = true
    }
}

// MARK: - Concrete shapes

@MainActor
final class RectangleTool: ShapeCreationTool {
    override var kind: ToolKind { .rectangle }

    override func makeKind(from start: CGPoint, to end: CGPoint, constrained: Bool) -> AnnotationKind {
        .rectangle(constrained ? AnnotationGeometry.squaredRect(from: start, to: end)
                               : AnnotationGeometry.rect(from: start, to: end))
    }
}

@MainActor
final class EllipseTool: ShapeCreationTool {
    override var kind: ToolKind { .ellipse }

    override func makeKind(from start: CGPoint, to end: CGPoint, constrained: Bool) -> AnnotationKind {
        .ellipse(constrained ? AnnotationGeometry.squaredRect(from: start, to: end)
                             : AnnotationGeometry.rect(from: start, to: end))
    }
}

@MainActor
final class ArrowTool: ShapeCreationTool {
    override var kind: ToolKind { .arrow }

    override func makeKind(from start: CGPoint, to end: CGPoint, constrained: Bool) -> AnnotationKind {
        .arrow(from: start,
               to: constrained ? AnnotationGeometry.snapTo45Degrees(from: start, to: end) : end)
    }
}

@MainActor
final class LineTool: ShapeCreationTool {
    override var kind: ToolKind { .line }

    override func makeKind(from start: CGPoint, to end: CGPoint, constrained: Bool) -> AnnotationKind {
        .line(from: start,
              to: constrained ? AnnotationGeometry.snapTo45Degrees(from: start, to: end) : end)
    }
}
