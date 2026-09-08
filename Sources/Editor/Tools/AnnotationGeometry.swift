//
//  AnnotationGeometry.swift
//  ZeroShot
//
//  Resize and endpoint helpers used by the canvas tools.
//
//  These live here rather than in Annotation.swift on purpose: Annotation.swift
//  is the shared model file that several agents depend on, and none of this is
//  needed by the model itself. Everything below is pure geometry in DOCUMENT
//  space (image pixels, top-left origin).
//

import CoreGraphics
import Foundation

extension AnnotationKind {

    /// The rect for box-shaped kinds, `nil` for the rest.
    var rectValue: CGRect? {
        switch self {
        case .rectangle(let r), .ellipse(let r), .highlight(let r), .blur(let r):
            return r.standardized
        case .text(let r, _):
            return r.standardized
        default:
            return nil
        }
    }

    /// The two ends of a straight kind, `nil` for the rest.
    var endpoints: (from: CGPoint, to: CGPoint)? {
        switch self {
        case .arrow(let a, let b), .line(let a, let b):
            return (a, b)
        default:
            return nil
        }
    }

    /// A copy with a new rect. No-op for kinds that are not box-shaped.
    func withRect(_ rect: CGRect) -> AnnotationKind {
        let r = rect.standardized
        switch self {
        case .rectangle:            return .rectangle(r)
        case .ellipse:              return .ellipse(r)
        case .highlight:            return .highlight(r)
        case .blur:                 return .blur(r)
        case .text(_, let string):  return .text(rect: r, string: string)
        default:                    return self
        }
    }

    /// A copy with new endpoints. No-op for kinds that are not straight.
    func withEndpoints(from a: CGPoint, to b: CGPoint) -> AnnotationKind {
        switch self {
        case .arrow: return .arrow(from: a, to: b)
        case .line:  return .line(from: a, to: b)
        default:     return self
        }
    }

    /// Which handles the selection layer should offer for this kind.
    var selectionHandles: [SelectionHandle] {
        if rectValue != nil { return SelectionHandle.boxHandles }
        if endpoints != nil { return [.start, .end] }
        // Badges show a ring, freehand paths are moved but not resized.
        return []
    }
}

extension Annotation {

    /// Document-space position of one handle, or nil when this annotation does
    /// not offer that handle.
    func handlePosition(_ handle: SelectionHandle) -> CGPoint? {
        if let ends = kind.endpoints {
            switch handle {
            case .start: return ends.from
            case .end:   return ends.to
            default:     return nil
            }
        }
        guard let rect = kind.rectValue else { return nil }
        let unit = handle.unitPoint
        return CGPoint(x: rect.minX + rect.width * unit.x,
                       y: rect.minY + rect.height * unit.y)
    }

    /// Returns a copy resized by dragging `handle` to `point`.
    ///
    /// `constrainProportion` (Shift) keeps box kinds square and snaps endpoint
    /// kinds to 45 degree steps. A minimum size stops a rect from collapsing to
    /// nothing and becoming unselectable.
    func resized(handle: SelectionHandle,
                 to point: CGPoint,
                 constrainProportion: Bool,
                 minimumSize: CGFloat = 4) -> Annotation {
        var copy = self

        if let ends = kind.endpoints {
            switch handle {
            case .start:
                let anchor = ends.to
                let moved = constrainProportion
                    ? AnnotationGeometry.snapTo45Degrees(from: anchor, to: point)
                    : point
                copy.kind = kind.withEndpoints(from: moved, to: anchor)
            case .end:
                let anchor = ends.from
                let moved = constrainProportion
                    ? AnnotationGeometry.snapTo45Degrees(from: anchor, to: point)
                    : point
                copy.kind = kind.withEndpoints(from: anchor, to: moved)
            default:
                break
            }
            return copy
        }

        guard let rect = kind.rectValue else { return copy }

        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY

        if handle.movesLeftEdge   { minX = point.x }
        if handle.movesRightEdge  { maxX = point.x }
        if handle.movesTopEdge    { minY = point.y }
        if handle.movesBottomEdge { maxY = point.y }

        var newRect = CGRect(x: min(minX, maxX), y: min(minY, maxY),
                             width: abs(maxX - minX), height: abs(maxY - minY))

        if constrainProportion, handle.movesLeftEdge || handle.movesRightEdge,
           handle.movesTopEdge || handle.movesBottomEdge {
            // Corner drag with Shift: keep it square, anchored on the opposite
            // corner so the handle under the pointer is the one that moves.
            let side = max(newRect.width, newRect.height)
            let anchorX = handle.movesLeftEdge ? rect.maxX : rect.minX
            let anchorY = handle.movesTopEdge ? rect.maxY : rect.minY
            let originX = handle.movesLeftEdge ? anchorX - side : anchorX
            let originY = handle.movesTopEdge ? anchorY - side : anchorY
            newRect = CGRect(x: originX, y: originY, width: side, height: side)
        }

        newRect.size.width = max(newRect.size.width, minimumSize)
        newRect.size.height = max(newRect.size.height, minimumSize)

        copy.kind = kind.withRect(newRect)
        return copy
    }
}

// MARK: - Shared constraint math

enum AnnotationGeometry {

    /// A square (or circle) rect from a drag, anchored at `origin`, keeping the
    /// direction the pointer went.
    static func squaredRect(from origin: CGPoint, to point: CGPoint) -> CGRect {
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        let side = max(abs(dx), abs(dy))
        let signedX = dx < 0 ? -side : side
        let signedY = dy < 0 ? -side : side
        return CGRect(x: origin.x, y: origin.y, width: signedX, height: signedY).standardized
    }

    static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Snaps `point` onto the nearest line through `origin` at a multiple of 45
    /// degrees, keeping the drag length.
    static func snapTo45Degrees(from origin: CGPoint, to point: CGPoint) -> CGPoint {
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        let length = hypot(dx, dy)
        guard length > 0 else { return point }
        let step = CGFloat.pi / 4
        let snapped = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: origin.x + cos(snapped) * length,
                       y: origin.y + sin(snapped) * length)
    }
}
