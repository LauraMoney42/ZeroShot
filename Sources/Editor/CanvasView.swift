//
//  CanvasView.swift
//  ZeroShot
//
//  The one AppKit view in the app. It shows the document through `Renderer`
//  (never its own copy of the drawing code), converts mouse positions into
//  document space, routes events to the active `CanvasTool`, and paints the
//  selection layer on top.
//
//  COORDINATE CONVENTION
//  ---------------------
//  Document space == image PIXEL space, origin TOP-LEFT, +y down.
//  `isFlipped` is true so view space has the same orientation; the only
//  difference between the two is the `zoom` factor and the centering offset.
//  This view is the ONLY place in the app allowed to know about display scale.
//
//  ZOOM
//  ----
//  `zoom` is document pixels per view point. 100% in the UI means one document
//  pixel per PHYSICAL screen pixel, i.e. `zoom == 1 / backingScaleFactor`, so a
//  2880x1800 Retina capture shows at 1440x900 points and is pixel-sharp.
//  Cmd+1 is actual size, Cmd+9 is fit to window (Cmd+0 is the global capture
//  hotkey and is deliberately left alone).
//

import AppKit
import CoreGraphics
import Observation
import SwiftUI

// MARK: - Shared editor settings

/// Tool selection and the style new annotations get. Owned by the SwiftUI
/// editor view, read and written by both the toolbar and the canvas, which is
/// how a single-key shortcut in the canvas lights up the right toolbar button.
/// Not `@MainActor` for the same reason `EditorDocument` is not: it has to be
/// creatable from a SwiftUI property initialiser and from tests. Touch it from
/// the main thread only.
@Observable
final class CanvasSettings {
    var toolKind: ToolKind = .select
    var style: AnnotationStyle = .default

    /// Number badges carry their own color, kept apart from the shape stroke
    /// color so a red arrow and a blue badge can coexist. Seeded from
    /// Preferences, then owned by the inspector for the life of the window.
    var badgeColor: CodableColor = Preferences.shared.defaultBadgeColor

    /// Radius in document pixels of a newly dropped badge. Small/medium/large
    /// in the inspector map to 18/26/36.
    var badgeRadius: CGFloat = max(Preferences.shared.defaultBadgeRadius, 6)

    /// Style for a badge dropped right now: the shared style with the badge's
    /// own color and radius patched in.
    var badgeStyle: AnnotationStyle {
        var badge = style
        badge.strokeColor = badgeColor
        badge.fillColor = nil
        badge.badgeRadius = badgeRadius
        return badge
    }

    /// Convenience for the toolbar's fill toggle.
    var isFilled: Bool {
        get { style.fillColor != nil }
        set {
            if newValue {
                style.fillColor = style.fillColor ?? style.strokeColor.withAlpha(0.25)
            } else {
                style.fillColor = nil
            }
        }
    }
}

// MARK: - Canvas

@MainActor
final class CanvasView: NSView {

    // MARK: Configuration

    let document: EditorDocument
    let settings: CanvasSettings

    /// Empty margin kept around the image when fitting to the window.
    static let fitPadding: CGFloat = 16

    /// On-screen size of a selection handle, in points, so handles stay the
    /// same physical size at every zoom.
    static let handleSize: CGFloat = 8

    /// How close, in points, the pointer has to be to grab something.
    static let hitTolerance: CGFloat = 5

    // MARK: Zoom state

    enum ZoomMode: Equatable {
        case fit
        case manual
    }

    private(set) var zoomMode: ZoomMode = .fit

    /// Document pixels per view point. Never set directly from outside; use
    /// `setZoom`, `zoomIn`, `zoomOut`, `zoomToActualSize`, `zoomToFit`.
    private(set) var zoom: CGFloat = 1

    /// 1.0 would mean one document pixel per view POINT, which on a 2x display
    /// is a 200% view. Actual size is one document pixel per screen pixel.
    var actualSizeZoom: CGFloat {
        1 / max(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2, 1)
    }

    /// What the toolbar shows: 100% == one image pixel per screen pixel.
    var zoomPercent: Int {
        Int((zoom / actualSizeZoom * 100).rounded())
    }

    private var minimumZoom: CGFloat { actualSizeZoom / 16 }
    private var maximumZoom: CGFloat { actualSizeZoom * 16 }

    // MARK: Tool state

    private(set) var activeTool: CanvasTool = UnimplementedTool(kind: .select)
    private var isDraggingWithTool = false

    /// The live text-editing overlay, when one is open. Parked here rather than
    /// inside `TextTool` because a double-click with the Select tool can open
    /// one too, and because switching tools or closing the window has to be able
    /// to commit it. See TextTool.swift.
    var textEditingSession: TextEditingSession?

    /// Finishes any in-flight text edit. Safe to call when there is none.
    func commitTextEditing() {
        textEditingSession?.commit()
        textEditingSession = nil
    }

    // MARK: Internals

    private var isUpdatingLayout = false
    private var lastVisibleSize: CGSize = .zero
    /// Displayed document size at the last layout pass, so a crop change
    /// re-fits even when the window did not move.
    private var lastOutputSize: CGSize = .zero
    private var observationToken = 0

    // MARK: Init

    init(document: EditorDocument, settings: CanvasSettings) {
        self.document = document
        self.settings = settings
        super.init(frame: NSRect(origin: .zero, size: document.displayRect.size))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        activeTool = ToolRegistry.makeTool(for: settings.toolKind)
        activeTool.activate(canvas: self)
        startObservingDocument()
        startObservingSettings()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CanvasView is created in code only")
    }

    // MARK: View plumbing

    /// Top-left origin, +y down, matching document space.
    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var isOpaque: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        if let clip = enclosingScrollView?.contentView {
            clip.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(visibleAreaChanged),
                name: NSView.frameDidChangeNotification,
                object: clip)
        }
        updateContentLayout(force: true)
        window?.makeFirstResponder(self)
    }

    @objc private func visibleAreaChanged() {
        updateContentLayout(force: false)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Observation

    /// `EditorDocument` is `@Observable`, so tracking has to be re-armed after
    /// every change. Redrawing on the next main-queue turn coalesces bursts.
    private func startObservingDocument() {
        withObservationTracking {
            _ = document.annotations
            _ = document.selectedIDs
            _ = document.cropRect
            // The crop tool flips this to show the whole image again while an
            // applied crop is being re-dragged; the canvas has to re-lay out.
            _ = document.isSuspendingCropForEditing
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateContentLayout(force: false)
                self.needsDisplay = true
                self.startObservingDocument()
            }
        }
    }

    private func startObservingSettings() {
        withObservationTracking {
            _ = settings.toolKind
            _ = settings.style
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.settings.toolKind != self.activeTool.kind {
                    self.setActiveTool(self.settings.toolKind)
                }
                self.needsDisplay = true
                self.startObservingSettings()
            }
        }
    }

    // MARK: - Layout and zoom

    /// Size of the area the image has to fit into.
    private var visibleContentSize: CGSize {
        enclosingScrollView?.contentView.bounds.size ?? bounds.size
    }

    /// Displayed size of the document, in view points.
    var contentSize: CGSize {
        let output = document.displayRect.size
        return CGSize(width: output.width * zoom, height: output.height * zoom)
    }

    /// Where document origin (`displayRect.origin`) lands in view space. The
    /// image is centred when the view is bigger than the content.
    var imageOrigin: CGPoint {
        let content = contentSize
        let x = max((bounds.width - content.width) / 2, 0)
        let y = max((bounds.height - content.height) / 2, 0)
        return CGPoint(x: x.rounded(.down), y: y.rounded(.down))
    }

    /// The rect the image occupies in view space.
    var contentRect: CGRect {
        CGRect(origin: imageOrigin, size: contentSize)
    }

    private func updateContentLayout(force: Bool) {
        guard !isUpdatingLayout else { return }
        let output = document.displayRect.size
        guard output.width > 0, output.height > 0 else { return }

        let visible = visibleContentSize
        let visibleChanged = abs(visible.width - lastVisibleSize.width) > 0.5
            || abs(visible.height - lastVisibleSize.height) > 0.5
        // Applying, adjusting or clearing a crop changes the displayed size
        // without touching the window, so fit-to-window has to be recomputed
        // for that too, not only for a resize.
        let outputChanged = abs(output.width - lastOutputSize.width) > 0.5
            || abs(output.height - lastOutputSize.height) > 0.5
        guard force || visibleChanged || outputChanged || zoomMode == .manual else { return }
        lastVisibleSize = visible
        lastOutputSize = output

        isUpdatingLayout = true
        defer { isUpdatingLayout = false }

        if zoomMode == .fit {
            zoom = clampedZoom(fitZoom(in: visible))
        }

        // Inside a scroll view the document view has to grow with the content
        // and never shrink below the visible area, or centring breaks.
        if enclosingScrollView != nil {
            let content = contentSize
            let target = CGSize(width: max(content.width, visible.width).rounded(.up),
                                height: max(content.height, visible.height).rounded(.up))
            if abs(frame.width - target.width) > 0.5 || abs(frame.height - target.height) > 0.5 {
                setFrameSize(target)
            }
        }
        needsDisplay = true
    }

    private func fitZoom(in visible: CGSize) -> CGFloat {
        let output = document.displayRect.size
        guard output.width > 0, output.height > 0 else { return actualSizeZoom }
        let available = CGSize(width: max(visible.width - CanvasView.fitPadding * 2, 32),
                               height: max(visible.height - CanvasView.fitPadding * 2, 32))
        let fit = min(available.width / output.width, available.height / output.height)
        // Never blow a small capture up past 100%; it just looks soft.
        return min(fit, actualSizeZoom)
    }

    private func clampedZoom(_ value: CGFloat) -> CGFloat {
        min(max(value, minimumZoom), maximumZoom)
    }

    /// Sets an explicit zoom (document pixels per view point).
    func setZoom(_ newZoom: CGFloat) {
        zoomMode = .manual
        zoom = clampedZoom(newZoom)
        updateContentLayout(force: true)
    }

    func zoomToFit() {
        zoomMode = .fit
        updateContentLayout(force: true)
    }

    func zoomToActualSize() {
        setZoom(actualSizeZoom)
    }

    func zoomIn() { setZoom(zoom * 1.25) }

    func zoomOut() { setZoom(zoom / 1.25) }

    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification))
    }

    // MARK: - Coordinate conversion

    /// View point (top-left origin, points) to document point (image pixels).
    func documentPoint(fromView point: CGPoint) -> CGPoint {
        let origin = imageOrigin
        let output = document.displayRect.origin
        return CGPoint(x: (point.x - origin.x) / zoom + output.x,
                       y: (point.y - origin.y) / zoom + output.y)
    }

    /// Document point to view point.
    func viewPoint(fromDocument point: CGPoint) -> CGPoint {
        let origin = imageOrigin
        let output = document.displayRect.origin
        return CGPoint(x: (point.x - output.x) * zoom + origin.x,
                       y: (point.y - output.y) * zoom + origin.y)
    }

    func viewRect(fromDocument rect: CGRect) -> CGRect {
        let a = viewPoint(fromDocument: CGPoint(x: rect.minX, y: rect.minY))
        let b = viewPoint(fromDocument: CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    func documentRect(fromView rect: CGRect) -> CGRect {
        let a = documentPoint(fromView: CGPoint(x: rect.minX, y: rect.minY))
        let b = documentPoint(fromView: CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// A distance in points expressed in document pixels. Use this so grab
    /// targets and minimum drags feel the same at every zoom.
    func documentLength(fromView length: CGFloat) -> CGFloat {
        length / max(zoom, 0.0001)
    }

    func viewLength(fromDocument length: CGFloat) -> CGFloat {
        length * zoom
    }

    /// Hit tolerance in document pixels for the current zoom.
    var documentHitTolerance: CGFloat {
        documentLength(fromView: CanvasView.hitTolerance)
    }

    /// Concatenates the view-space to document-space transform onto `ctx`.
    ///
    /// After this call the context takes DOCUMENT pixel coordinates, still
    /// y-down (the view is flipped), which is exactly what
    /// `Renderer.drawPreview` wants. Tools use it to draw a live preview with
    /// the real renderer instead of a look-alike.
    func applyDocumentTransform(to ctx: CGContext) {
        let origin = imageOrigin
        let output = document.displayRect.origin
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.scaleBy(x: zoom, y: zoom)
        ctx.translateBy(x: -output.x, y: -output.y)
    }

    // MARK: - Selection helpers used by tools

    /// Topmost annotation under a document point, honouring the zoom-adjusted
    /// tolerance.
    func annotation(atDocument point: CGPoint) -> Annotation? {
        document.hitTest(point, tolerance: documentHitTolerance)
    }

    /// The selection handle under a document point, if any. Handles win over
    /// the annotation body, and later (topmost) annotations win over earlier
    /// ones.
    func handle(atDocument point: CGPoint) -> HandleHit? {
        let grab = documentLength(fromView: CanvasView.handleSize)
        for annotation in document.annotations.reversed()
        where document.selectedIDs.contains(annotation.id) {
            for handle in annotation.kind.selectionHandles {
                guard let position = annotation.handlePosition(handle) else { continue }
                if abs(position.x - point.x) <= grab && abs(position.y - point.y) <= grab {
                    return HandleHit(annotationID: annotation.id, handle: handle)
                }
            }
        }
        return nil
    }

    /// Adds a freshly drawn annotation, selects it, and leaves the tool active
    /// (Greenshot behaviour: draw three rectangles without going back to the
    /// toolbar).
    func commitNewAnnotation(_ annotation: Annotation) {
        document.add(annotation)
        document.selectedIDs = [annotation.id]
        needsDisplay = true
    }

    /// Applies a change to every selected annotation as ONE undo step.
    func applyToSelection(actionName: String, _ transform: (Annotation) -> Annotation) {
        let selected = document.selectedAnnotations
        guard !selected.isEmpty else { return }
        document.beginUndoGroup(actionName: actionName)
        var isFirst = true
        for annotation in selected {
            let updated = transform(annotation)
            guard updated != annotation else { continue }
            document.update(updated, registersUndo: isFirst, actionName: actionName)
            isFirst = false
        }
        document.endUndoGroup()
        needsDisplay = true
    }

    func selectAll() {
        document.selectedIDs = Set(document.annotations.map(\.id))
        needsDisplay = true
    }

    func deselectAll() {
        guard !document.selectedIDs.isEmpty else { return }
        document.selectedIDs = []
        needsDisplay = true
    }

    // MARK: - Tools

    func setActiveTool(_ kind: ToolKind) {
        guard kind != activeTool.kind else {
            if settings.toolKind != kind { settings.toolKind = kind }
            return
        }
        // A half-typed text box belongs to the document, not to the tool that
        // opened it, so leaving that tool commits it.
        commitTextEditing()
        activeTool.deactivate(canvas: self)
        activeTool = ToolRegistry.makeTool(for: kind)
        activeTool.activate(canvas: self)
        if settings.toolKind != kind { settings.toolKind = kind }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: activeTool.cursor)
    }

    // MARK: - Context menu

    /// Right-click anywhere on the canvas: "Copy Image" copies the current
    /// flattened result (base image plus every annotation, cropped if
    /// cropped) to the clipboard, independent of the Done button and the
    /// copy-on-capture preference.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy Image", action: #selector(copyImageMenuAction), keyEquivalent: "")
            .target = self
        return menu
    }

    @objc private func copyImageMenuAction() {
        ExportController.shared.copyOnly(document: document)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = documentPoint(fromView: convert(event.locationInWindow, from: nil))

        // Double clicks are offered to the tool first (the Select tool uses one
        // to re-open a text annotation). See DoubleClickHandling in TextTool.
        if event.clickCount == 2,
           let handler = activeTool as? DoubleClickHandling,
           handler.doubleClick(at: point, modifiers: event.modifierFlags, canvas: self) {
            isDraggingWithTool = false
            return
        }

        isDraggingWithTool = true
        activeTool.mouseDown(at: point, modifiers: event.modifierFlags, canvas: self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggingWithTool else { return }
        let point = documentPoint(fromView: convert(event.locationInWindow, from: nil))
        activeTool.mouseDragged(at: point, modifiers: event.modifierFlags, canvas: self)
        autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDraggingWithTool else { return }
        isDraggingWithTool = false
        let point = documentPoint(fromView: convert(event.locationInWindow, from: nil))
        activeTool.mouseUp(at: point, modifiers: event.modifierFlags, canvas: self)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        // Never steal keys from a text field or the future text overlay.
        guard window == nil || window?.firstResponder === self else {
            super.keyDown(with: event)
            return
        }
        if activeTool.handleKeyDown(event, canvas: self) { return }

        let characters = event.charactersIgnoringModifiers ?? ""
        guard let first = characters.unicodeScalars.first else {
            super.keyDown(with: event)
            return
        }

        switch Int(first.value) {
        case NSDeleteCharacter, NSBackspaceCharacter, NSDeleteFunctionKey:
            if !document.selectedIDs.isEmpty {
                document.removeSelected()
                needsDisplay = true
            }
            return

        case 0x1B:
            // Esc: drop any in-flight drag, then the selection. Text editing
            // has already consumed its own Esc in TextOverlayView.cancelOperation
            // before this ever runs, so it never reaches here. If Esc found
            // nothing to cancel or deselect, it closes the window instead
            // (windowShouldClose asks about unsaved changes).
            let wasIdle = !isDraggingWithTool
                && document.selectedIDs.isEmpty
                && !document.isSuspendingCropForEditing
            activeTool.cancel(canvas: self)
            isDraggingWithTool = false
            deselectAll()
            if wasIdle {
                window?.close()
            }
            return

        case NSLeftArrowFunctionKey:
            nudgeSelection(dx: -1, dy: 0, modifiers: event.modifierFlags); return
        case NSRightArrowFunctionKey:
            nudgeSelection(dx: 1, dy: 0, modifiers: event.modifierFlags); return
        case NSUpArrowFunctionKey:
            nudgeSelection(dx: 0, dy: -1, modifiers: event.modifierFlags); return
        case NSDownArrowFunctionKey:
            nudgeSelection(dx: 0, dy: 1, modifiers: event.modifierFlags); return

        default:
            break
        }

        // Single-key tool shortcuts. Modifier-carrying keys were already tried
        // as key equivalents, so anything reaching here is a bare press.
        if !event.modifierFlags.contains(.command),
           let character = characters.first,
           let kind = ToolKind.kind(forShortcut: character) {
            setActiveTool(kind)
            return
        }

        super.keyDown(with: event)
    }

    /// Moves the selection by whole document pixels. One undo step per press.
    func nudgeSelection(dx: CGFloat, dy: CGFloat, modifiers: NSEvent.ModifierFlags) {
        guard !document.selectedIDs.isEmpty else { return }
        let step: CGFloat = modifiers.contains(.shift) ? 10 : 1
        let offset = CGPoint(x: dx * step, y: dy * step)
        applyToSelection(actionName: "Move") { $0.translated(by: offset) }
    }

    /// Cmd shortcuts. Handled here rather than in a menu because ZeroShot is a
    /// menu bar app: it has no Edit menu of its own to hang them on.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // While the text overlay has focus every shortcut is the text view's:
        // Cmd+A must select the typed characters, not every annotation.
        if let responder = window?.firstResponder as? NSView,
           responder !== self, responder.isDescendant(of: self) {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        let characters = (event.charactersIgnoringModifiers ?? "").lowercased()
        let hasShift = flags.contains(.shift)

        switch characters {
        case "z":
            let manager = document.undoManager
            if hasShift {
                if manager.canRedo { manager.redo() }
            } else if manager.canUndo {
                manager.undo()
            }
            needsDisplay = true
            return true

        case "a":
            selectAll()
            return true

        case "+", "=":
            zoomIn()
            return true

        case "-":
            zoomOut()
            return true

        case "1":
            // Cmd+1 rather than Cmd+0: Cmd+0 is the global capture hotkey.
            zoomToActualSize()
            return true

        case "9":
            zoomToFit()
            return true

        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        NSColor.underPageBackgroundColor.setFill()
        dirtyRect.fill()

        let output = document.displayRect
        guard output.width > 0, output.height > 0 else { return }

        let origin = imageOrigin
        let displayed = contentSize

        // Paper drop shadow, so the capture reads as a document on the canvas.
        let paper = CGRect(origin: origin, size: displayed)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 6,
                      color: NSColor.black.withAlphaComponent(0.35).cgColor)
        NSColor.white.setFill()
        paper.fill()
        ctx.restoreGState()

        // Hand `Renderer` the bottom-left, unit-scale context it documents.
        // The view is flipped, so the y axis is inverted back and then scaled;
        // the net effect maps document pixel (x, y) to view point
        // (origin.x + x * zoom, origin.y + y * zoom).
        ctx.saveGState()
        ctx.clip(to: paper)
        ctx.translateBy(x: origin.x, y: origin.y + displayed.height)
        ctx.scaleBy(x: zoom, y: -zoom)
        Renderer.draw(document: document, in: ctx, includeSelection: false)
        ctx.restoreGState()

        // Selection and tool chrome live in view space so they keep their
        // on-screen size no matter how far the canvas is zoomed.
        drawSelectionLayer(in: ctx)
        activeTool.draw(overlayIn: ctx, canvas: self)
    }

    private func drawSelectionLayer(in ctx: CGContext) {
        let selected = document.selectedAnnotations
        guard !selected.isEmpty else { return }

        ctx.saveGState()
        defer { ctx.restoreGState() }

        let accent = NSColor.controlAccentColor.cgColor
        let handle = CanvasView.handleSize

        for annotation in selected {
            let box = viewRect(fromDocument: annotation.boundingRect).insetBy(dx: -3, dy: -3)

            if case .badge(let center, _) = annotation.kind {
                // Badges are round; a ring reads better than a box.
                let point = viewPoint(fromDocument: center)
                let radius = viewLength(fromDocument: annotation.style.badgeRadius) + 4
                ctx.setStrokeColor(accent)
                ctx.setLineWidth(2)
                ctx.strokeEllipse(in: CGRect(x: point.x - radius, y: point.y - radius,
                                             width: radius * 2, height: radius * 2))
                continue
            }

            ctx.setStrokeColor(accent)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.stroke(box)
            ctx.setLineDash(phase: 0, lengths: [])

            for kindHandle in annotation.kind.selectionHandles {
                guard let position = annotation.handlePosition(kindHandle) else { continue }
                let point = viewPoint(fromDocument: position)
                let rect = CGRect(x: point.x - handle / 2, y: point.y - handle / 2,
                                  width: handle, height: handle)
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.setStrokeColor(accent)
                ctx.setLineWidth(1)
                if kindHandle == .start || kindHandle == .end {
                    ctx.fillEllipse(in: rect)
                    ctx.strokeEllipse(in: rect)
                } else {
                    ctx.fill(rect)
                    ctx.stroke(rect)
                }
            }
        }
    }
}

// MARK: - SwiftUI bridge

/// Hosts `CanvasView` inside a scroll view for SwiftUI.
struct CanvasRepresentable: NSViewRepresentable {

    let document: EditorDocument
    let settings: CanvasSettings

    func makeNSView(context: Context) -> NSScrollView {
        let canvas = CanvasView(document: document, settings: settings)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.documentView = canvas
        // Zoom is applied when drawing, not by magnifying a bitmap, so the
        // image stays sharp at actual size on a Retina display.
        scrollView.allowsMagnification = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let canvas = scrollView.documentView as? CanvasView else { return }
        if canvas.activeTool.kind != settings.toolKind {
            canvas.setActiveTool(settings.toolKind)
        }
        canvas.needsDisplay = true
    }
}
