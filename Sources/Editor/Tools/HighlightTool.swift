//
//  HighlightTool.swift
//  ZeroShot
//
//  Drag out a translucent highlighter wash. `Renderer` draws `.highlight` with
//  a 40% alpha multiply blend in the annotation's stroke colour, so the text
//  underneath stays readable.
//
//  WHY `RectDragTool` EXISTS RATHER THAN SUBCLASSING `ShapeCreationTool`
//  --------------------------------------------------------------------
//  `ShapeCreationTool` takes `activate`/`deactivate` from the `CanvasTool`
//  protocol EXTENSION, and a Swift subclass cannot override a protocol
//  extension member: calls through the protocol would always land on the
//  default no-op. The highlighter needs a real `activate` (that is where the
//  yellow default is set), so the milestone-4 rect tools get their own small
//  base class instead. Behaviour is deliberately identical to
//  `ShapeCreationTool`: live preview drawn by the real renderer, Shift for a
//  square, a minimum drag distance, one undo step, and the new annotation is
//  left selected with the tool still active.
//

import AppKit
import CoreGraphics
import Foundation

// MARK: - Shared drag-out-a-rectangle behaviour

@MainActor
class RectDragTool: CanvasTool {

    /// Drags shorter than this many POINTS on screen are a stray click.
    static let minimumDragPoints: CGFloat = 3

    var kind: ToolKind { .highlight }

    var cursor: NSCursor { .crosshair }

    private var origin: CGPoint?
    private var current: CGPoint?
    private var isConstrained = false

    // MARK: Subclass hooks

    /// Build the annotation geometry for a drag. `constrained` is Shift.
    func makeKind(from start: CGPoint, to end: CGPoint, constrained: Bool) -> AnnotationKind {
        .highlight(constrained ? AnnotationGeometry.squaredRect(from: start, to: end)
                               : AnnotationGeometry.rect(from: start, to: end))
    }

    /// Style for the new annotation. Neither highlights nor blurs use a fill.
    func style(for settings: CanvasSettings) -> AnnotationStyle {
        var style = settings.style
        style.fillColor = nil
        return style
    }

    func activate(canvas: CanvasView) {}

    func deactivate(canvas: CanvasView) { cancel(canvas: canvas) }

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

        // The threshold is in points, so it feels the same at every zoom.
        let threshold = canvas.documentLength(fromView: RectDragTool.minimumDragPoints)
        guard hypot(point.x - start.x, point.y - start.y) >= threshold else { return }

        let annotation = Annotation(kind: makeKind(from: start, to: point, constrained: constrained),
                                    style: style(for: canvas.settings))
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

// MARK: - Highlighter

@MainActor
final class HighlightTool: RectDragTool {

    override var kind: ToolKind { .highlight }

    /// The colour the inspector was showing before the highlighter forced
    /// yellow, so ordinary shapes go back to it afterwards.
    private var colorBeforeActivation: CodableColor?

    override func makeKind(from start: CGPoint, to end: CGPoint, constrained: Bool) -> AnnotationKind {
        .highlight(constrained ? AnnotationGeometry.squaredRect(from: start, to: end)
                               : AnnotationGeometry.rect(from: start, to: end))
    }

    /// A highlighter is yellow unless you say otherwise. Picking the tool sets
    /// the shared inspector colour, so the swatch agrees with what gets drawn
    /// and choosing another colour while the tool is active simply wins.
    override func activate(canvas: CanvasView) {
        let current = canvas.settings.style.strokeColor
        guard current != .yellow else { return }
        colorBeforeActivation = current
        canvas.settings.style.strokeColor = .yellow
    }

    /// Leaving the tool restores the previous colour, but only when the user
    /// never touched the colour picker in the meantime.
    override func deactivate(canvas: CanvasView) {
        if let previous = colorBeforeActivation, canvas.settings.style.strokeColor == .yellow {
            canvas.settings.style.strokeColor = previous
        }
        colorBeforeActivation = nil
        cancel(canvas: canvas)
    }
}
