//
//  Tool.swift
//  ZeroShot
//
//  The canvas tool contract plus the tool catalogue.
//
//  DESIGN NOTE (read before adding a tool)
//  ---------------------------------------
//  `CanvasView` knows nothing about individual tools. It asks `ToolRegistry`
//  for an object conforming to `CanvasTool` and forwards mouse and key events
//  to it. A later agent adding the badge, text, crop, highlight, blur or pen
//  tool therefore only has to:
//
//    1. create Sources/Editor/Tools/<Name>Tool.swift with a class conforming
//       to `CanvasTool`,
//    2. call `ToolRegistry.register(.badge) { BadgeTool() }` from that file's
//       `ToolRegistry.registerBuiltInTools()` hook (see the bottom of this
//       file),
//
//  and nothing in `CanvasView` or `EditorWindow` changes. Unregistered kinds
//  still appear in the toolbar; they simply resolve to `UnimplementedTool`,
//  which does nothing but keeps the UI honest.
//
//  COORDINATE CONVENTION: every point handed to a tool is in DOCUMENT space
//  (image pixels, top-left origin, +y down). The only exception is
//  `draw(overlayIn:canvas:)`, which paints in VIEW space; use the canvas's
//  `viewPoint(fromDocument:)` helpers to convert.
//

import AppKit
import CoreGraphics
import Foundation

// MARK: - Tool kinds

/// Every tool the editor offers, in toolbar order.
enum ToolKind: String, CaseIterable, Identifiable, Hashable {
    case select
    case crop
    case rectangle
    case ellipse
    case arrow
    case line
    case text
    case badge
    case highlight
    case blur
    case pen

    var id: String { rawValue }

    /// SF Symbol shown in the toolbar.
    var symbolName: String {
        switch self {
        case .select:    return "cursorarrow"
        case .crop:      return "crop"
        case .rectangle: return "rectangle"
        case .ellipse:   return "circle"
        case .arrow:     return "arrow.up.right"
        case .line:      return "line.diagonal"
        case .text:      return "textformat"
        case .badge:     return "1.circle.fill"
        case .highlight: return "highlighter"
        case .blur:      return "square.grid.3x3.fill"
        case .pen:       return "scribble"
        }
    }

    var displayName: String {
        switch self {
        case .select:    return "Select"
        case .crop:      return "Crop"
        case .rectangle: return "Rectangle"
        case .ellipse:   return "Ellipse"
        case .arrow:     return "Arrow"
        case .line:      return "Line"
        case .text:      return "Text"
        case .badge:     return "Number"
        case .highlight: return "Highlighter"
        case .blur:      return "Blur"
        case .pen:       return "Freehand"
        }
    }

    /// Single-key shortcut, matching the documented set V C R E A L T N H B P.
    var shortcut: Character {
        switch self {
        case .select:    return "v"
        case .crop:      return "c"
        case .rectangle: return "r"
        case .ellipse:   return "e"
        case .arrow:     return "a"
        case .line:      return "l"
        case .text:      return "t"
        case .badge:     return "n"
        case .highlight: return "h"
        case .blur:      return "b"
        case .pen:       return "p"
        }
    }

    /// Uppercase form for tooltips.
    var shortcutLabel: String { String(shortcut).uppercased() }

    /// True when the inspector's fill toggle means anything for this tool.
    var supportsFill: Bool {
        self == .rectangle || self == .ellipse
    }

    static func kind(forShortcut character: Character) -> ToolKind? {
        let lowered = Character(String(character).lowercased())
        return allCases.first { $0.shortcut == lowered }
    }
}

// MARK: - Selection handles

/// Where a drag grabbed a selected annotation. Rect-like kinds expose the
/// eight box handles; arrows and lines expose their two endpoints.
enum SelectionHandle: Hashable, CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    case start, end

    static let boxHandles: [SelectionHandle] = [
        .topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left
    ]

    /// Unit position inside the annotation's box, x and y in 0...1.
    var unitPoint: CGPoint {
        switch self {
        case .topLeft:     return CGPoint(x: 0, y: 0)
        case .top:         return CGPoint(x: 0.5, y: 0)
        case .topRight:    return CGPoint(x: 1, y: 0)
        case .right:       return CGPoint(x: 1, y: 0.5)
        case .bottomRight: return CGPoint(x: 1, y: 1)
        case .bottom:      return CGPoint(x: 0.5, y: 1)
        case .bottomLeft:  return CGPoint(x: 0, y: 1)
        case .left:        return CGPoint(x: 0, y: 0.5)
        case .start:       return CGPoint(x: 0, y: 0)
        case .end:         return CGPoint(x: 1, y: 1)
        }
    }

    var movesLeftEdge: Bool { [.topLeft, .left, .bottomLeft].contains(self) }
    var movesRightEdge: Bool { [.topRight, .right, .bottomRight].contains(self) }
    var movesTopEdge: Bool { [.topLeft, .top, .topRight].contains(self) }
    var movesBottomEdge: Bool { [.bottomLeft, .bottom, .bottomRight].contains(self) }
}

/// One handle of one annotation, as returned by `CanvasView.handle(at:)`.
struct HandleHit: Equatable {
    var annotationID: UUID
    var handle: SelectionHandle
}

// MARK: - The tool protocol

/// A tool owns the interpretation of one drag on the canvas.
///
/// Tools are reference types because almost all of them carry drag state, and
/// because `CanvasView` keeps exactly one live instance per activation.
@MainActor
protocol CanvasTool: AnyObject {

    /// Which toolbar entry this tool implements.
    var kind: ToolKind { get }

    /// Cursor shown while the tool is active.
    var cursor: NSCursor { get }

    /// Called when the tool becomes / stops being the active tool. Use it to
    /// commit or throw away in-flight state (a half-typed text box, say).
    func activate(canvas: CanvasView)
    func deactivate(canvas: CanvasView)

    /// Mouse events. `point` is in DOCUMENT space.
    func mouseDown(at point: CGPoint, modifiers: NSEvent.ModifierFlags, canvas: CanvasView)
    func mouseDragged(at point: CGPoint, modifiers: NSEvent.ModifierFlags, canvas: CanvasView)
    func mouseUp(at point: CGPoint, modifiers: NSEvent.ModifierFlags, canvas: CanvasView)

    /// Extra chrome drawn on top of the rendered document, in VIEW space.
    /// The default implementation draws nothing.
    func draw(overlayIn ctx: CGContext, canvas: CanvasView)

    /// Esc, a tool switch mid-drag, or the window closing. Drop any in-flight
    /// edit and leave the document as it was.
    func cancel(canvas: CanvasView)

    /// Give a tool first refusal on a key press before the canvas handles it.
    /// Return true when the tool consumed the event. Default: false.
    func handleKeyDown(_ event: NSEvent, canvas: CanvasView) -> Bool
}

/// Defaults, so a new tool file only implements what it actually needs.
extension CanvasTool {
    var cursor: NSCursor { .crosshair }
    func activate(canvas: CanvasView) {}
    func deactivate(canvas: CanvasView) { cancel(canvas: canvas) }
    func draw(overlayIn ctx: CGContext, canvas: CanvasView) {}
    func cancel(canvas: CanvasView) {}
    func handleKeyDown(_ event: NSEvent, canvas: CanvasView) -> Bool { false }
}

// MARK: - Placeholder for kinds that are not built yet

/// Keeps unimplemented toolbar buttons selectable without crashing or making
/// spurious edits. Milestones 3 and 4 replace these one at a time.
@MainActor
final class UnimplementedTool: CanvasTool {
    let kind: ToolKind

    init(kind: ToolKind) {
        self.kind = kind
    }

    var cursor: NSCursor { .operationNotAllowed }

    func mouseDown(at point: CGPoint, modifiers: NSEvent.ModifierFlags, canvas: CanvasView) {}
    func mouseDragged(at point: CGPoint, modifiers: NSEvent.ModifierFlags, canvas: CanvasView) {}
    func mouseUp(at point: CGPoint, modifiers: NSEvent.ModifierFlags, canvas: CanvasView) {}
}

// MARK: - Registry

/// Maps a `ToolKind` to a factory. Later tool files register themselves here
/// instead of editing `CanvasView`.
@MainActor
enum ToolRegistry {

    private static var factories: [ToolKind: () -> CanvasTool] = [:]
    private static var didRegisterBuiltIns = false

    /// Registers (or replaces) the factory for one kind.
    static func register(_ kind: ToolKind, factory: @escaping () -> CanvasTool) {
        factories[kind] = factory
    }

    /// True when a real implementation exists. The toolbar dims the rest.
    static func isImplemented(_ kind: ToolKind) -> Bool {
        registerBuiltInToolsIfNeeded()
        return factories[kind] != nil
    }

    /// Always returns a usable tool; unregistered kinds get `UnimplementedTool`.
    static func makeTool(for kind: ToolKind) -> CanvasTool {
        registerBuiltInToolsIfNeeded()
        if let factory = factories[kind] {
            return factory()
        }
        return UnimplementedTool(kind: kind)
    }

    /// The one place milestone-2 tools are wired up. Add a line here (or call
    /// `ToolRegistry.register` from your own file's initializer) when a new
    /// tool file lands.
    static func registerBuiltInToolsIfNeeded() {
        guard !didRegisterBuiltIns else { return }
        didRegisterBuiltIns = true

        register(.select)    { SelectTool() }
        register(.rectangle) { RectangleTool() }
        register(.ellipse)   { EllipseTool() }
        register(.arrow)     { ArrowTool() }
        register(.line)      { LineTool() }

        register(.badge)     { BadgeTool() }
        register(.text)      { TextTool() }
        register(.crop)      { CropTool() }
        register(.highlight) { HighlightTool() }
        register(.blur)      { BlurTool() }
        register(.pen)       { PenTool() }
    }
}
