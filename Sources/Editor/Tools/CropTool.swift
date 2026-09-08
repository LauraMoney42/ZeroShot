//
//  CropTool.swift
//  ZeroShot
//
//  Drag a rectangle, adjust it with eight handles, then apply it. The crop is
//  NON-DESTRUCTIVE: `EditorDocument` keeps the original capture and only stores
//  a rect, annotations keep their original pixel coordinates, and undo puts the
//  previous crop back. `Renderer` clips to `outputRect`, so a flattened export
//  comes out at the cropped size.
//
//  APPLYING AND CANCELLING
//  -----------------------
//  Return (or Enter, or a double-click inside the rectangle, or the Apply pill
//  in the overlay) commits the crop through `document.setCrop`, which is a
//  single undo step. Esc drops the in-flight rectangle and leaves the document
//  as it was.
//
//  RE-CROPPING AND REMOVING A CROP
//  -------------------------------
//  Once a crop is applied the canvas shows only the cropped area, so there is
//  nothing outside it left to drag. Picking the crop tool therefore sets
//  `document.isSuspendingCropForEditing`, which makes the CANVAS (and only the
//  canvas, never export) show the whole capture again with everything outside
//  the current crop dimmed, ready to be re-dragged. Two pills in the overlay
//  drive the rest:
//
//    * "Reset crop" removes the crop completely and is the documented way to
//      get the full image back. It is a button rather than a Cmd+Shift+R key
//      equivalent because `CanvasView.performKeyEquivalent` owns the Cmd
//      shortcuts and a menu bar app has no menu to hang another one on, so a
//      visible control is both simpler and discoverable.
//    * "Adjust crop" re-enters the whole-image view after an apply.
//
//  Overlay chrome is drawn in VIEW space (it keeps its on-screen size at every
//  zoom); the crop rectangle itself is kept in DOCUMENT space.
//

import AppKit
import CoreGraphics
import Foundation

@MainActor
final class CropTool: CanvasTool {

    let kind: ToolKind = .crop

    var cursor: NSCursor { .crosshair }

    /// Smallest crop the tool will apply, in document pixels.
    static let minimumCropSize: CGFloat = 8

    /// On-screen size of a crop handle, in points.
    static let handleSize: CGFloat = 10

    // MARK: State

    /// The rectangle being edited, in document space. `nil` means "nothing
    /// drawn yet".
    private(set) var pending: CGRect?

    private enum Drag {
        case none
        case creating(origin: CGPoint)
        case moving(grab: CGPoint, original: CGRect)
        case resizing(handle: SelectionHandle, original: CGRect)
    }

    private var drag: Drag = .none
    /// Restored when a drag turns out to be too small to be a crop.
    private var pendingBeforeDrag: CGRect?

    /// The overlay pills, recomputed from the canvas on every draw and every
    /// click so the two can never disagree.
    private enum Action {
        case apply, adjust, reset

        var title: String {
            switch self {
            case .apply:  return "Apply crop"
            case .adjust: return "Adjust crop"
            case .reset:  return "Reset crop"
            }
        }
    }

    // MARK: - Activation

    func activate(canvas: CanvasView) {
        let document = canvas.document
        pending = document.cropRect
        canvas.deselectAll()
        if document.cropRect != nil {
            // Show the whole capture again so the applied crop can be re-drawn.
            document.isSuspendingCropForEditing = true
            canvas.zoomToFit()
        }
        canvas.needsDisplay = true
    }

    func deactivate(canvas: CanvasView) {
        cancel(canvas: canvas)
    }

    func cancel(canvas: CanvasView) {
        let document = canvas.document
        let wasSuspending = document.isSuspendingCropForEditing
        document.isSuspendingCropForEditing = false
        pending = document.cropRect
        pendingBeforeDrag = nil
        drag = .none
        if wasSuspending { canvas.zoomToFit() }
        canvas.needsDisplay = true
    }

    // MARK: - Mouse

    func mouseDown(at point: CGPoint, modifiers: NSEvent.ModifierFlags, canvas: CanvasView) {
        drag = .none
        pendingBeforeDrag = pending

        // 1. The overlay pills win over anything on the canvas.
        let viewPoint = canvas.viewPoint(fromDocument: point)
        for (rect, action) in buttonLayout(canvas: canvas) where rect.contains(viewPoint) {
            perform(action, canvas: canvas)
            return
        }

        // 2. Double-click inside the rectangle applies it, the same as Return.
        let clickCount = NSApp.currentEvent?.clickCount ?? 1
        if clickCount >= 2, let rect = pending, rect.contains(point) {
            perform(.apply, canvas: canvas)
            return
        }

        if let rect = pending {
            // 3. A handle adjusts one edge or corner.
            let grab = canvas.documentLength(fromView: CropTool.handleSize)
            if let handle = handle(at: point, in: rect, grab: grab) {
                drag = .resizing(handle: handle, original: rect)
                return
            }
            // 4. Inside the rectangle moves the whole thing.
            if rect.contains(point) {
                drag = .moving(grab: point, original: rect)
                return
            }
        }

        // 5. Anywhere else starts a new rectangle.
        let clamped = clamp(point, canvas: canvas)
        drag = .creating(origin: clamped)
        pending = CGRect(origin: clamped, size: .zero)
        canvas.needsDisplay = true
    }

    func mouseDragged(at point: CGPoint, modifiers: NSEvent.ModifierFlags, canvas: CanvasView) {
        let bounds = canvas.document.displayRect
        let clamped = clamp(point, canvas: canvas)

        switch drag {
        case .none:
            return

        case .creating(let origin):
            pending = AnnotationGeometry.rect(from: origin, to: clamped)

        case .moving(let grab, let original):
            let offset = CGPoint(x: point.x - grab.x, y: point.y - grab.y)
            var moved = original.offsetBy(dx: offset.x, dy: offset.y)
            // Keep the rectangle inside the image instead of letting it walk
            // off the edge and get clipped to a different shape on apply.
            moved.origin.x = min(max(moved.minX, bounds.minX), bounds.maxX - moved.width)
            moved.origin.y = min(max(moved.minY, bounds.minY), bounds.maxY - moved.height)
            pending = moved

        case .resizing(let handle, let original):
            pending = resize(original, handle: handle, to: clamped)
        }
        canvas.needsDisplay = true
    }

    func mouseUp(at point: CGPoint, modifiers: NSEvent.ModifierFlags, canvas: CanvasView) {
        var wasDragging = true
        if case .none = drag { wasDragging = false }

        if wasDragging {
            mouseDragged(at: point, modifiers: modifiers, canvas: canvas)
            // A stray click that produced nothing usable leaves the previous
            // rectangle alone rather than wiping it.
            if let rect = pending, !isUsable(rect) {
                pending = pendingBeforeDrag
            }
        }

        drag = .none
        pendingBeforeDrag = nil
        canvas.needsDisplay = true
    }

    // MARK: - Keyboard

    func handleKeyDown(_ event: NSEvent, canvas: CanvasView) -> Bool {
        // Return, Enter and the numeric keypad's Enter all apply the crop.
        let isReturn = event.keyCode == 36 || event.keyCode == 76
            || (event.charactersIgnoringModifiers ?? "").contains { $0 == "\r" || $0 == "\n" }
        guard isReturn else { return false }
        perform(.apply, canvas: canvas)
        return true
    }

    // MARK: - Actions

    private func perform(_ action: Action, canvas: CanvasView) {
        let document = canvas.document

        switch action {
        case .apply:
            guard let rect = pending, isUsable(rect) else { return }
            let applied = rect.standardized.intersection(document.imageRect).integral
            guard !applied.isNull, applied != document.cropRect else {
                document.isSuspendingCropForEditing = false
                canvas.zoomToFit()
                canvas.needsDisplay = true
                return
            }
            // Stop suspending BEFORE the mutation so the undo snapshot and the
            // new layout both describe the same, real, state.
            document.isSuspendingCropForEditing = false
            document.setCrop(applied)
            pending = document.cropRect
            canvas.zoomToFit()

        case .adjust:
            guard document.cropRect != nil else { return }
            document.isSuspendingCropForEditing = true
            pending = document.cropRect
            canvas.zoomToFit()

        case .reset:
            guard document.cropRect != nil else { return }
            document.isSuspendingCropForEditing = false
            document.setCrop(nil, actionName: "Reset Crop")
            pending = nil
            canvas.zoomToFit()
        }

        canvas.needsDisplay = true
    }

    // MARK: - Geometry helpers

    private func isUsable(_ rect: CGRect) -> Bool {
        let standardized = rect.standardized
        return standardized.width >= CropTool.minimumCropSize
            && standardized.height >= CropTool.minimumCropSize
    }

    private func clamp(_ point: CGPoint, canvas: CanvasView) -> CGPoint {
        let bounds = canvas.document.displayRect
        return CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX),
                       y: min(max(point.y, bounds.minY), bounds.maxY))
    }

    private func handle(at point: CGPoint, in rect: CGRect, grab: CGFloat) -> SelectionHandle? {
        for handle in SelectionHandle.boxHandles {
            let unit = handle.unitPoint
            let position = CGPoint(x: rect.minX + rect.width * unit.x,
                                   y: rect.minY + rect.height * unit.y)
            if abs(position.x - point.x) <= grab && abs(position.y - point.y) <= grab {
                return handle
            }
        }
        return nil
    }

    /// Same edge maths as `Annotation.resized`, kept local because a crop is
    /// not an annotation and has its own minimum size.
    private func resize(_ rect: CGRect, handle: SelectionHandle, to point: CGPoint) -> CGRect {
        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY

        if handle.movesLeftEdge   { minX = point.x }
        if handle.movesRightEdge  { maxX = point.x }
        if handle.movesTopEdge    { minY = point.y }
        if handle.movesBottomEdge { maxY = point.y }

        return CGRect(x: min(minX, maxX), y: min(minY, maxY),
                      width: abs(maxX - minX), height: abs(maxY - minY))
    }

    // MARK: - Overlay

    func draw(overlayIn ctx: CGContext, canvas: CanvasView) {
        let content = canvas.contentRect
        guard content.width > 1, content.height > 1 else { return }

        ctx.saveGState()
        defer { ctx.restoreGState() }

        if let rect = pending, isUsable(rect) || !rect.isEmpty {
            let viewRect = canvas.viewRect(fromDocument: rect).intersection(content)
            drawDimming(around: viewRect, inside: content, ctx: ctx)
            drawFrame(viewRect, ctx: ctx)
            drawHandles(viewRect, ctx: ctx)
            drawSizeLabel(for: rect, at: viewRect, inside: content, ctx: ctx)
        } else {
            // Nothing drawn yet: a light wash plus a hint, so the tool does not
            // look inert.
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.22).cgColor)
            ctx.fill(content)
            drawHint("Drag to choose the area to keep", inside: content, ctx: ctx)
        }

        for (rect, action) in buttonLayout(canvas: canvas) {
            drawPill(action.title, in: rect, emphasised: action == .apply)
        }
    }

    private func drawDimming(around rect: CGRect, inside content: CGRect, ctx: CGContext) {
        let dim = NSColor.black.withAlphaComponent(0.55).cgColor
        ctx.setFillColor(dim)
        // Four bands rather than an even-odd path: no winding surprises, and
        // each band is a plain rect the compositor is happy with.
        ctx.fill(CGRect(x: content.minX, y: content.minY,
                        width: content.width, height: max(rect.minY - content.minY, 0)))
        ctx.fill(CGRect(x: content.minX, y: rect.maxY,
                        width: content.width, height: max(content.maxY - rect.maxY, 0)))
        ctx.fill(CGRect(x: content.minX, y: rect.minY,
                        width: max(rect.minX - content.minX, 0), height: rect.height))
        ctx.fill(CGRect(x: rect.maxX, y: rect.minY,
                        width: max(content.maxX - rect.maxX, 0), height: rect.height))
    }

    private func drawFrame(_ rect: CGRect, ctx: CGContext) {
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))

        // Rule-of-thirds guides, the usual crop affordance.
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(0.5)
        for step in 1...2 {
            let fraction = CGFloat(step) / 3
            let x = (rect.minX + rect.width * fraction).rounded() + 0.5
            let y = (rect.minY + rect.height * fraction).rounded() + 0.5
            ctx.move(to: CGPoint(x: x, y: rect.minY))
            ctx.addLine(to: CGPoint(x: x, y: rect.maxY))
            ctx.move(to: CGPoint(x: rect.minX, y: y))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        ctx.strokePath()
    }

    private func drawHandles(_ rect: CGRect, ctx: CGContext) {
        let size = CropTool.handleSize
        for handle in SelectionHandle.boxHandles {
            let unit = handle.unitPoint
            let centre = CGPoint(x: rect.minX + rect.width * unit.x,
                                 y: rect.minY + rect.height * unit.y)
            let box = CGRect(x: centre.x - size / 2, y: centre.y - size / 2,
                             width: size, height: size)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(box)
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.6).cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(box.insetBy(dx: 0.5, dy: 0.5))
        }
    }

    private func drawSizeLabel(for documentRect: CGRect, at viewRect: CGRect,
                               inside content: CGRect, ctx: CGContext) {
        let rect = documentRect.standardized.integral
        let text = "\(Int(rect.width)) x \(Int(rect.height)) px"
        let attributed = NSAttributedString(string: text, attributes: labelAttributes)
        let size = attributed.size()
        // Above the rectangle when there is room, otherwise just inside it.
        let above = viewRect.minY - size.height - 10
        let y = above >= content.minY ? above : viewRect.minY + 6
        let origin = CGPoint(x: viewRect.midX - size.width / 2 - 6, y: y)
        let box = CGRect(origin: origin, size: CGSize(width: size.width + 12, height: size.height + 4))
        drawCapsule(box, fill: NSColor.black.withAlphaComponent(0.7))
        attributed.draw(at: CGPoint(x: box.minX + 6, y: box.minY + 2))
    }

    private func drawHint(_ text: String, inside content: CGRect, ctx: CGContext) {
        let attributed = NSAttributedString(string: text, attributes: labelAttributes)
        let size = attributed.size()
        let box = CGRect(x: content.midX - size.width / 2 - 10,
                         y: content.midY - size.height / 2 - 5,
                         width: size.width + 20, height: size.height + 10)
        drawCapsule(box, fill: NSColor.black.withAlphaComponent(0.6))
        attributed.draw(at: CGPoint(x: box.minX + 10, y: box.minY + 5))
    }

    private func drawPill(_ title: String, in rect: CGRect, emphasised: Bool) {
        let fill = emphasised
            ? NSColor.controlAccentColor.withAlphaComponent(0.95)
            : NSColor.black.withAlphaComponent(0.72)
        drawCapsule(rect, fill: fill)

        let attributed = NSAttributedString(string: title, attributes: labelAttributes)
        let size = attributed.size()
        attributed.draw(at: CGPoint(x: rect.midX - size.width / 2,
                                    y: rect.midY - size.height / 2))
    }

    private func drawCapsule(_ rect: CGRect, fill: NSColor) {
        let path = NSBezierPath(roundedRect: rect,
                                xRadius: rect.height / 2, yRadius: rect.height / 2)
        fill.setFill()
        path.fill()
    }

    private var labelAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
         .foregroundColor: NSColor.white]
    }

    // MARK: - Overlay buttons

    /// The pills and where they sit, in VIEW space. Both drawing and hit
    /// testing call this, so a pill is always clickable exactly where it is
    /// drawn.
    private func buttonLayout(canvas: CanvasView) -> [(CGRect, Action)] {
        let document = canvas.document
        var actions: [Action] = []

        let isAdjusting = document.isSuspendingCropForEditing || document.cropRect == nil
        if isAdjusting {
            if let rect = pending, isUsable(rect), rect.integral != document.cropRect {
                actions.append(.apply)
            }
        } else if document.cropRect != nil {
            actions.append(.adjust)
        }
        if document.cropRect != nil {
            actions.append(.reset)
        }
        guard !actions.isEmpty else { return [] }

        let height: CGFloat = 24
        let spacing: CGFloat = 8
        let widths = actions.map { action -> CGFloat in
            NSAttributedString(string: action.title, attributes: labelAttributes).size().width + 26
        }
        let total = widths.reduce(0, +) + spacing * CGFloat(actions.count - 1)

        // Anchored to what is actually on screen, so scrolling a zoomed canvas
        // never hides the controls. `visibleRect` is the INFINITE rect for a
        // view with no window (unit tests), hence the intersection.
        let clipped = canvas.visibleRect.intersection(canvas.bounds)
        let visible = (clipped.isNull || clipped.isEmpty) ? canvas.bounds : clipped
        var x = visible.midX - total / 2
        let y = visible.maxY - height - 16

        var layout: [(CGRect, Action)] = []
        for (index, action) in actions.enumerated() {
            let rect = CGRect(x: x, y: y, width: widths[index], height: height)
            layout.append((rect, action))
            x += widths[index] + spacing
        }
        return layout
    }
}
