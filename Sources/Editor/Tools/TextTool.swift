//
//  TextTool.swift
//  ZeroShot
//
//  Click (or drag out a starting box) to place a text annotation and type into
//  it straight away. While editing, a real `NSTextView` sits on top of the
//  canvas at the annotation's position, scaled to the current zoom, so what you
//  type is what `Renderer` later draws.
//
//  WHY AN OVERLAY AND NOT CUSTOM CARET DRAWING
//  -------------------------------------------
//  Text input on macOS means input methods, marked text, emoji, dead keys and
//  the standard editing key bindings. An NSTextView gets all of that for free;
//  hand-rolling a caret would get none of it.
//
//  LIFECYCLE
//  ---------
//  `TextEditingSession` owns one editing pass. It is parked on the canvas
//  (`canvas.textEditingSession`) so that a tool switch, a click elsewhere, or
//  the window closing can all commit it. Commit rules:
//
//    * Esc, Cmd+Return, clicking elsewhere, or switching tools -> commit.
//    * An empty string commits to nothing: a new annotation is never added and
//      an existing one is deleted.
//
//  UNDO POLICY: one step per editing pass. A new annotation is only handed to
//  the document on commit, so a cancelled edit leaves the undo stack alone.
//  When re-editing an existing annotation the document copy is blanked while
//  the overlay is up (so the text is not drawn twice); the original string is
//  put back with `registersUndo: false` before the real edit, which keeps the
//  snapshot honest.
//

import AppKit
import CoreGraphics
import Foundation

// MARK: - Double click hook

/// Opt-in double-click handling for tools.
///
/// Declared here rather than in `Tool.swift` so the shared tool contract file
/// stays untouched: `CanvasView` asks `activeTool as? DoubleClickHandling`, and
/// tools that do not care are unaffected.
@MainActor
protocol DoubleClickHandling: CanvasTool {
    /// Return true when the tool consumed the double click.
    func doubleClick(at point: CGPoint, modifiers: NSEvent.ModifierFlags, canvas: CanvasView) -> Bool
}

// MARK: - The tool

@MainActor
final class TextTool: CanvasTool {

    let kind: ToolKind = .text

    var cursor: NSCursor { .iBeam }

    /// Drags shorter than this many POINTS are treated as a plain click, which
    /// still opens an editor at a default size.
    static let minimumDragPoints: CGFloat = 4

    private var origin: CGPoint?
    private var current: CGPoint?

    // MARK: Mouse

    func mouseDown(at point: CGPoint, modifiers: NSEvent.ModifierFlags, canvas: CanvasView) {
        origin = point
        current = point
    }

    func mouseDragged(at point: CGPoint, modifiers: NSEvent.ModifierFlags, canvas: CanvasView) {
        guard origin != nil else { return }
        current = point
        canvas.needsDisplay = true
    }

    func mouseUp(at point: CGPoint, modifiers: NSEvent.ModifierFlags, canvas: CanvasView) {
        guard let start = origin else { return }
        origin = nil
        current = nil
        canvas.needsDisplay = true

        let style = canvas.settings.style
        let threshold = canvas.documentLength(fromView: TextTool.minimumDragPoints)
        let dragged = hypot(point.x - start.x, point.y - start.y) >= threshold

        // A drag sets the origin and a minimum box; a click uses one line at
        // the current font size. Either way the box grows with the text.
        let rect: CGRect
        if dragged {
            rect = AnnotationGeometry.rect(from: start, to: point)
        } else {
            rect = CGRect(x: start.x, y: start.y,
                          width: max(style.fontSize, 1) * 4,
                          height: max(style.fontSize, 1) * 1.3)
        }

        let annotation = Annotation(kind: .text(rect: rect, string: ""), style: style)
        TextEditingSession.begin(annotation: annotation, isNew: true, canvas: canvas)
    }

    /// A tool switch, Esc on the canvas, or the window going away. An in-flight
    /// edit is committed rather than thrown away, which is what the rest of the
    /// app does with half-finished work.
    func cancel(canvas: CanvasView) {
        origin = nil
        current = nil
        canvas.commitTextEditing()
    }

    // MARK: Overlay

    /// Marching-ants preview of the box being dragged out.
    func draw(overlayIn ctx: CGContext, canvas: CanvasView) {
        guard let start = origin, let end = current else { return }
        let rect = canvas.viewRect(fromDocument: AnnotationGeometry.rect(from: start, to: end))
        guard rect.width > 1 || rect.height > 1 else { return }

        ctx.saveGState()
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.stroke(rect)
        ctx.restoreGState()
    }
}

// MARK: - Double click to re-edit with the Select tool

/// Double-clicking a text annotation with the Select tool re-opens the editor.
/// Implemented as an extension here so `SelectTool.swift` does not have to
/// know that the text tool exists.
extension SelectTool: DoubleClickHandling {

    func doubleClick(at point: CGPoint, modifiers: NSEvent.ModifierFlags, canvas: CanvasView) -> Bool {
        guard let target = canvas.annotation(atDocument: point),
              case .text = target.kind else { return false }
        TextEditingSession.begin(annotation: target, isNew: false, canvas: canvas)
        return true
    }
}

// MARK: - Editing session

@MainActor
final class TextEditingSession: NSObject, NSTextViewDelegate {

    private weak var canvas: CanvasView?
    private let textView: TextOverlayView

    private let annotationID: UUID
    private let isNew: Bool

    /// Style the committed annotation will carry. Starts as the annotation's
    /// own style and then FOLLOWS the toolbar while the overlay is open, so
    /// changing the font size or color mid-typing is visible at once instead
    /// of being ignored until the next text box.
    private var style: AnnotationStyle

    /// Pre-edit state, used to make the undo snapshot correct and to restore a
    /// cancelled edit.
    private let originalRect: CGRect
    private let originalString: String

    /// Current box in DOCUMENT space; grows as the text is typed.
    private(set) var rect: CGRect

    private var isFinished = false

    /// Typing must never land on the document's undo stack: the window hands
    /// `NSTextView` the document's manager otherwise.
    private let editingUndoManager = UndoManager()

    // MARK: Start

    /// Opens an editor for `annotation`. Any session already running on this
    /// canvas is committed first.
    @discardableResult
    static func begin(annotation: Annotation, isNew: Bool, canvas: CanvasView) -> TextEditingSession? {
        guard case .text(let rect, let string) = annotation.kind else { return nil }
        canvas.commitTextEditing()

        let session = TextEditingSession(annotationID: annotation.id,
                                         isNew: isNew,
                                         style: annotation.style,
                                         rect: rect.standardized,
                                         string: string,
                                         canvas: canvas)
        canvas.textEditingSession = session
        session.attach(to: canvas, initialString: string)
        return session
    }

    private init(annotationID: UUID,
                 isNew: Bool,
                 style: AnnotationStyle,
                 rect: CGRect,
                 string: String,
                 canvas: CanvasView) {
        self.annotationID = annotationID
        self.isNew = isNew
        self.style = style
        self.rect = rect
        self.originalRect = rect
        self.originalString = string
        self.canvas = canvas
        self.textView = TextOverlayView(frame: NSRect(origin: .zero, size: CGSize(width: 40, height: 20)))
        super.init()
    }

    private func attach(to canvas: CanvasView, initialString: String) {
        textView.session = self
        textView.delegate = self
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = false
        textView.importsGraphics = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.size = CGSize(width: CGFloat.greatestFiniteMagnitude,
                                              height: CGFloat.greatestFiniteMagnitude)
        textView.drawsBackground = true
        textView.backgroundColor = NSColor.white.withAlphaComponent(0.55)
        textView.wantsLayer = true
        textView.layer?.borderWidth = 1
        textView.layer?.borderColor = NSColor.controlAccentColor.cgColor

        let color = NSColor(cgColor: style.strokeColor.cgColor) ?? .red
        textView.textColor = color
        textView.insertionPointColor = color
        textView.string = initialString

        // While the overlay shows the text, the document copy must not also
        // draw it. Blanked without touching undo; put back in `commit`.
        if !isNew {
            blankDocumentCopy(canvas: canvas)
            // Re-editing: show this text's size and color in the toolbar so
            // the stepper starts from what the user is looking at.
            canvas.settings.style.fontSize = style.fontSize
            canvas.settings.style.strokeColor = style.strokeColor
        }
        observeToolbarStyle()

        canvas.addSubview(textView)
        syncGeometry()
        canvas.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (initialString as NSString).length, length: 0))
        canvas.needsDisplay = true
    }

    // MARK: Live toolbar style

    /// `CanvasSettings` is `@Observable`; re-arm after every change because
    /// observation tracking fires once.
    private func observeToolbarStyle() {
        guard let canvas = canvas, !isFinished else { return }
        withObservationTracking {
            _ = canvas.settings.style.fontSize
            _ = canvas.settings.style.strokeColor
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self, !self.isFinished, let canvas = self.canvas else { return }
                self.style.fontSize = canvas.settings.style.fontSize
                self.style.strokeColor = canvas.settings.style.strokeColor
                let color = NSColor(cgColor: self.style.strokeColor.cgColor) ?? .red
                self.textView.textColor = color
                self.textView.insertionPointColor = color
                self.syncGeometry()
                canvas.needsDisplay = true
                self.observeToolbarStyle()
            }
        }
    }

    // MARK: Text access (also the seam the tests drive)

    var string: String { textView.string }

    /// Replaces the whole string as if it had been typed.
    func setString(_ newValue: String) {
        textView.string = newValue
        syncGeometry()
    }

    // MARK: Geometry

    /// Re-measures the text and grows the overlay and the document rect to fit.
    func syncGeometry() {
        guard let canvas = canvas else { return }
        let zoom = max(canvas.zoom, 0.01)
        let scaledFont = NSFont.systemFont(ofSize: max(style.fontSize * zoom, 1))
        if textView.font != scaledFont { textView.font = scaledFont }

        let lineHeight = max(scaledFont.ascender - scaledFont.descender + scaledFont.leading,
                             scaledFont.pointSize * 1.2)
        var width = max(originalRect.width * zoom, scaledFont.pointSize * 3)
        var height = lineHeight

        if let layoutManager = textView.layoutManager, let container = textView.textContainer {
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container)
            // A little slack so the caret at the end of a line is visible and
            // so `Renderer` never wraps a line the overlay did not wrap.
            width = max(width, used.width + scaledFont.pointSize * 0.6)
            height = max(height, used.height)
        }

        let viewOrigin = canvas.viewPoint(fromDocument: rect.origin)
        textView.frame = NSRect(x: viewOrigin.x.rounded(), y: viewOrigin.y.rounded(),
                                width: width.rounded(.up), height: height.rounded(.up))
        rect = CGRect(x: rect.origin.x, y: rect.origin.y,
                      width: width / zoom, height: height / zoom)
    }

    // MARK: Finishing

    /// Commits the edit and tears the overlay down. Safe to call twice.
    func commit() {
        guard !isFinished else { return }
        isFinished = true

        let text = textView.string
        let canvas = self.canvas
        detach()

        guard let canvas = canvas else { return }
        let document = canvas.document
        let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if isNew {
            // An empty new annotation was never added, so there is nothing to
            // remove and nothing to undo.
            guard !isEmpty else {
                canvas.needsDisplay = true
                return
            }
            let annotation = Annotation(id: annotationID,
                                        kind: .text(rect: rect, string: text),
                                        style: style)
            canvas.commitNewAnnotation(annotation)
            return
        }

        // Restore the pre-edit state first, without registering undo, so that
        // the snapshot the real mutation takes is the state the user saw.
        restoreDocumentCopy(canvas: canvas)

        guard var existing = document.annotation(withID: annotationID) else { return }
        if isEmpty {
            document.remove(ids: [annotationID], actionName: "Delete Text")
            canvas.needsDisplay = true
            return
        }
        existing.kind = .text(rect: rect, string: text)
        guard existing != document.annotation(withID: annotationID) else {
            canvas.needsDisplay = true
            return
        }
        document.update(existing, registersUndo: true, actionName: "Edit Text")
        document.selectedIDs = [annotationID]
        canvas.needsDisplay = true
    }

    /// Throws the edit away and puts the document back exactly as it was.
    func cancelEditing() {
        guard !isFinished else { return }
        isFinished = true
        let canvas = self.canvas
        detach()
        guard let canvas = canvas else { return }
        if !isNew { restoreDocumentCopy(canvas: canvas) }
        canvas.needsDisplay = true
    }

    private func detach() {
        textView.session = nil
        textView.delegate = nil
        let canvas = self.canvas
        if textView.superview != nil { textView.removeFromSuperview() }
        if let canvas = canvas {
            if canvas.textEditingSession === self { canvas.textEditingSession = nil }
            if canvas.window?.firstResponder === textView || canvas.window?.firstResponder == nil {
                canvas.window?.makeFirstResponder(canvas)
            }
        }
    }

    private func blankDocumentCopy(canvas: CanvasView) {
        guard var existing = canvas.document.annotation(withID: annotationID) else { return }
        existing.kind = .text(rect: originalRect, string: "")
        canvas.document.update(existing, registersUndo: false)
    }

    private func restoreDocumentCopy(canvas: CanvasView) {
        guard var existing = canvas.document.annotation(withID: annotationID) else { return }
        existing.kind = .text(rect: originalRect, string: originalString)
        canvas.document.update(existing, registersUndo: false)
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        syncGeometry()
    }

    /// Keeps typing off the document's undo stack.
    func undoManager(for view: NSTextView) -> UndoManager? {
        editingUndoManager
    }
}

// MARK: - The overlay view

/// An `NSTextView` that reports the keys the editor cares about back to its
/// session, and commits when it stops being the first responder (which is what
/// makes "click somewhere else to finish" work).
@MainActor
final class TextOverlayView: NSTextView {

    weak var session: TextEditingSession?

    override var isFlipped: Bool { true }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, let session = session {
            // Not synchronously: AppKit is mid-way through swapping responders.
            DispatchQueue.main.async { session.commit() }
        }
        return resigned
    }

    /// Esc finishes the edit rather than leaving the caret parked in a box.
    override func cancelOperation(_ sender: Any?) {
        session?.commit()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command),
           let first = (event.charactersIgnoringModifiers ?? "").unicodeScalars.first,
           first.value == 13 || first.value == 3 {   // Return, Enter
            session?.commit()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
