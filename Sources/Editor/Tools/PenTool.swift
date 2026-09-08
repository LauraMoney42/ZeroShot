//
//  PenTool.swift
//  ZeroShot
//
//  Freehand drawing. Mouse down starts a `.path` annotation, every drag event
//  appends a point, mouse up commits the whole stroke as ONE undo step.
//
//  POINT THINNING
//  --------------
//  A drag can deliver a hundred events a second, most of them a fraction of a
//  pixel apart. Points closer than `minimumSpacingPoints` on screen to the last
//  kept point are dropped, which keeps the annotation small (it is Codable and
//  gets snapshotted on every undo step) without any visible change to the line.
//  The spacing is converted through the canvas, so zooming out does not turn a
//  careful curve into a polygon.
//
//  SELECTION
//  ---------
//  `.path` reports no selection handles (see `AnnotationKind.selectionHandles`),
//  so the select tool moves a stroke but does not resize it. Hit testing walks
//  the segments, which `Annotation.hitTest` already does.
//

import AppKit
import CoreGraphics
import Foundation

@MainActor
final class PenTool: CanvasTool {

    let kind: ToolKind = .pen

    var cursor: NSCursor { .crosshair }

    /// Minimum distance between two kept points, in screen POINTS.
    static let minimumSpacingPoints: CGFloat = 2

    /// A press that never travels this far is a click, not a stroke, and is
    /// thrown away so a mis-click leaves no dot behind.
    static let minimumStrokePoints: CGFloat = 3

    private var points: [CGPoint] = []
    private var isDrawing = false

    // MARK: Mouse

    func mouseDown(at point: CGPoint, modifiers: NSEvent.ModifierFlags, canvas: CanvasView) {
        isDrawing = true
        points = [point]
        canvas.needsDisplay = true
    }

    func mouseDragged(at point: CGPoint, modifiers: NSEvent.ModifierFlags, canvas: CanvasView) {
        guard isDrawing else { return }
        append(point, canvas: canvas)
        canvas.needsDisplay = true
    }

    func mouseUp(at point: CGPoint, modifiers: NSEvent.ModifierFlags, canvas: CanvasView) {
        defer { reset(canvas: canvas) }
        guard isDrawing else { return }
        // The last sample always counts, so the stroke ends where the mouse did.
        append(point, canvas: canvas, force: true)

        guard points.count > 1,
              travelledDistance() >= canvas.documentLength(fromView: PenTool.minimumStrokePoints)
        else { return }

        let annotation = Annotation(kind: .path(points), style: style(for: canvas.settings))
        // `commitNewAnnotation` is a single `document.add`, so the whole stroke
        // is one undo step no matter how many points it holds.
        canvas.commitNewAnnotation(annotation)
    }

    func cancel(canvas: CanvasView) {
        reset(canvas: canvas)
    }

    // MARK: Overlay

    func draw(overlayIn ctx: CGContext, canvas: CanvasView) {
        guard points.count > 1 else { return }

        let preview = Annotation(kind: .path(points), style: style(for: canvas.settings))

        ctx.saveGState()
        ctx.clip(to: canvas.contentRect)
        canvas.applyDocumentTransform(to: ctx)
        Renderer.drawPreview(preview, document: canvas.document, in: ctx)
        ctx.restoreGState()
    }

    // MARK: Helpers

    private func style(for settings: CanvasSettings) -> AnnotationStyle {
        var style = settings.style
        // A freehand line is stroked, never filled.
        style.fillColor = nil
        return style
    }

    private func append(_ point: CGPoint, canvas: CanvasView, force: Bool = false) {
        guard let last = points.last else {
            points.append(point)
            return
        }
        let spacing = max(canvas.documentLength(fromView: PenTool.minimumSpacingPoints),
                          PenTool.minimumSpacingPoints)
        let distance = hypot(point.x - last.x, point.y - last.y)
        guard distance >= spacing || (force && distance > 0.01) else { return }
        points.append(point)
    }

    /// Total length of the stroke so far, used to reject a click.
    private func travelledDistance() -> CGFloat {
        guard points.count > 1 else { return 0 }
        var total: CGFloat = 0
        for index in 0..<(points.count - 1) {
            total += hypot(points[index + 1].x - points[index].x,
                           points[index + 1].y - points[index].y)
        }
        return total
    }

    private func reset(canvas: CanvasView) {
        points = []
        isDrawing = false
        canvas.needsDisplay = true
    }
}
