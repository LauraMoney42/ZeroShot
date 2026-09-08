//
//  SelectTool.swift
//  ZeroShot
//
//  Click to select, shift-click to extend, drag to move, drag a handle to
//  resize (or to move an arrow/line endpoint), drag empty space to rubber-band
//  select.
//
//  UNDO POLICY
//  -----------
//  One undo step per DRAG, not per mouse-moved event. The first mutation of a
//  drag is wrapped in an explicit undo group opened lazily (so a click that
//  moves nothing registers nothing) and every later mutation of the same drag
//  passes `registersUndo: false`.
//

import AppKit
import CoreGraphics
import Foundation

@MainActor
final class SelectTool: CanvasTool {

    let kind: ToolKind = .select

    var cursor: NSCursor { .arrow }

    // MARK: Drag state

    private enum Drag {
        case none
        /// Moving the whole selection.
        case moving(origin: CGPoint, originals: [Annotation])
        /// Dragging one handle of one annotation.
        case resizing(hit: HandleHit, original: Annotation)
        /// Rubber band over empty canvas.
        case band(origin: CGPoint, current: CGPoint, additive: Bool, base: Set<UUID>)
    }

    private var drag: Drag = .none
    /// True once this drag has opened an undo group and mutated the document.
    private var didOpenUndoGroup = false
    private var didMutate = false

    // MARK: Mouse

    func mouseDown(at point: CGPoint, modifiers: NSEvent.ModifierFlags, canvas: CanvasView) {
        didOpenUndoGroup = false
        didMutate = false
        let document = canvas.document
        let extending = modifiers.contains(.shift)

        // 1. A handle of something already selected wins over everything else.
        if !extending, let hit = canvas.handle(atDocument: point),
           let original = document.annotation(withID: hit.annotationID) {
            drag = .resizing(hit: hit, original: original)
            return
        }

        // 2. An annotation body.
        if let target = canvas.annotation(atDocument: point) {
            if extending {
                if document.selectedIDs.contains(target.id) {
                    document.selectedIDs.remove(target.id)
                } else {
                    document.selectedIDs.insert(target.id)
                }
            } else if !document.selectedIDs.contains(target.id) {
                document.selectedIDs = [target.id]
            }
            canvas.needsDisplay = true
            drag = .moving(origin: point, originals: document.selectedAnnotations)
            return
        }

        // 3. Empty space: start a rubber band, clearing first unless extending.
        if !extending {
            document.selectedIDs = []
        }
        canvas.needsDisplay = true
        drag = .band(origin: point, current: point,
                     additive: extending, base: document.selectedIDs)
    }

    func mouseDragged(at point: CGPoint, modifiers: NSEvent.ModifierFlags, canvas: CanvasView) {
        switch drag {

        case .none:
            break

        case .moving(let origin, let originals):
            let offset = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
            // Ignore sub-pixel jitter so a plain click never registers a move.
            guard abs(offset.x) >= 0.5 || abs(offset.y) >= 0.5 else { return }
            beginUndoGroupIfNeeded(canvas: canvas, actionName: "Move")
            for original in originals {
                canvas.document.update(original.translated(by: offset),
                                       registersUndo: firstMutationRegistersUndo(),
                                       actionName: "Move")
            }
            canvas.needsDisplay = true

        case .resizing(let hit, let original):
            beginUndoGroupIfNeeded(canvas: canvas, actionName: "Resize")
            let resized = original.resized(handle: hit.handle,
                                           to: point,
                                           constrainProportion: modifiers.contains(.shift))
            canvas.document.update(resized,
                                   registersUndo: firstMutationRegistersUndo(),
                                   actionName: "Resize")
            canvas.needsDisplay = true

        case .band(let origin, _, let additive, let base):
            drag = .band(origin: origin, current: point, additive: additive, base: base)
            applyBandSelection(canvas: canvas, origin: origin, current: point,
                               additive: additive, base: base)
            canvas.needsDisplay = true
        }
    }

    func mouseUp(at point: CGPoint, modifiers: NSEvent.ModifierFlags, canvas: CanvasView) {
        if case .band(let origin, _, let additive, let base) = drag {
            applyBandSelection(canvas: canvas, origin: origin, current: point,
                               additive: additive, base: base)
        }
        finishDrag(canvas: canvas)
    }

    func cancel(canvas: CanvasView) {
        // Undoing the open group is the cheapest correct way to roll a drag
        // back: the group already holds the pre-drag snapshot.
        if didOpenUndoGroup {
            canvas.document.endUndoGroup()
            didOpenUndoGroup = false
            if didMutate, canvas.document.undoManager.canUndo {
                canvas.document.undoManager.undo()
            }
        }
        drag = .none
        didMutate = false
        canvas.needsDisplay = true
    }

    // MARK: Overlay

    func draw(overlayIn ctx: CGContext, canvas: CanvasView) {
        guard case .band(let origin, let current, _, _) = drag else { return }
        let rect = canvas.viewRect(fromDocument: AnnotationGeometry.rect(from: origin, to: current))
        guard rect.width > 1 || rect.height > 1 else { return }

        ctx.saveGState()
        ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor)
        ctx.fill(rect)
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.stroke(rect)
        ctx.restoreGState()
    }

    // MARK: Helpers

    private func applyBandSelection(canvas: CanvasView,
                                    origin: CGPoint,
                                    current: CGPoint,
                                    additive: Bool,
                                    base: Set<UUID>) {
        let band = AnnotationGeometry.rect(from: origin, to: current)
        var selected = additive ? base : []
        for annotation in canvas.document.annotations
        where band.intersects(annotation.boundingRect) {
            selected.insert(annotation.id)
        }
        canvas.document.selectedIDs = selected
    }

    /// Opens the drag's undo group the first time the drag actually changes
    /// something, so a click with no movement leaves the undo stack alone.
    private func beginUndoGroupIfNeeded(canvas: CanvasView, actionName: String) {
        guard !didOpenUndoGroup else { return }
        canvas.document.beginUndoGroup(actionName: actionName)
        didOpenUndoGroup = true
    }

    /// True exactly once per drag: only the first mutation needs to snapshot
    /// the pre-drag state into the group.
    private func firstMutationRegistersUndo() -> Bool {
        if didMutate { return false }
        didMutate = true
        return true
    }

    private func finishDrag(canvas: CanvasView) {
        if didOpenUndoGroup {
            canvas.document.endUndoGroup()
            didOpenUndoGroup = false
        }
        didMutate = false
        drag = .none
        canvas.needsDisplay = true
    }
}
