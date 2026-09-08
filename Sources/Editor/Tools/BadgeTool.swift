//
//  BadgeTool.swift
//  ZeroShot
//
//  The auto-numbered badge tool: one click drops the next number (1, 2, 3...)
//  and the tool stays active, so a whole set of callouts can be dropped without
//  going back to the toolbar.
//
//  COUNTER OWNERSHIP (read before changing this file)
//  --------------------------------------------------
//  `EditorDocument` owns the counter. `peekNextBadgeNumber()` READS it without
//  consuming it, and `add(_:)` is what bumps it, using the number carried by
//  the annotation. So the tool must peek, build, and add: peeking and then
//  incrementing by hand would skip a number, and the undo snapshot taken inside
//  `add` is also what restores the counter when the badge is undone.
//
//  UNDO POLICY: one step per placement. `add` opens and closes its own group,
//  and the drag-before-release that nudges the badge passes
//  `registersUndo: false` so it folds into that same step.
//

import AppKit
import CoreGraphics
import Foundation

@MainActor
final class BadgeTool: CanvasTool {

    let kind: ToolKind = .badge

    var cursor: NSCursor { .crosshair }

    /// The badge placed by the press that is still down, so dragging can move
    /// it before the mouse comes up.
    private var placedID: UUID?

    // MARK: Mouse

    func mouseDown(at point: CGPoint, modifiers: NSEvent.ModifierFlags, canvas: CanvasView) {
        let document = canvas.document
        let number = document.peekNextBadgeNumber()

        let annotation = Annotation(kind: .badge(center: point, number: number),
                                    style: canvas.settings.badgeStyle)

        // Adds, bumps the counter, selects, and leaves this tool active.
        canvas.commitNewAnnotation(annotation)
        placedID = annotation.id
    }

    func mouseDragged(at point: CGPoint, modifiers: NSEvent.ModifierFlags, canvas: CanvasView) {
        moveIfPlaced(to: point, canvas: canvas)
    }

    func mouseUp(at point: CGPoint, modifiers: NSEvent.ModifierFlags, canvas: CanvasView) {
        moveIfPlaced(to: point, canvas: canvas)
        placedID = nil
    }

    /// Esc or a tool switch mid-press. The badge is already committed, so all
    /// there is to drop is the reference to it.
    func cancel(canvas: CanvasView) {
        placedID = nil
    }

    // MARK: Helpers

    private func moveIfPlaced(to point: CGPoint, canvas: CanvasView) {
        guard let id = placedID,
              let existing = canvas.document.annotation(withID: id),
              case .badge(let center, let number) = existing.kind else { return }
        guard abs(center.x - point.x) >= 0.5 || abs(center.y - point.y) >= 0.5 else { return }

        var moved = existing
        moved.kind = .badge(center: point, number: number)
        canvas.document.update(moved, registersUndo: false)
        canvas.needsDisplay = true
    }
}
