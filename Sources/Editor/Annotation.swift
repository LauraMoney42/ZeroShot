//
//  Annotation.swift
//  ZeroShot
//
//  The annotation value model. Deliberately free of AppKit so it can be
//  unit tested and reasoned about without a running app.
//
//  COORDINATE CONVENTION (whole app, see also CaptureService and Renderer):
//  Document space == image PIXEL space. Origin is TOP-LEFT, +x right, +y down.
//  A 2x Retina capture of a 1440x900 point screen is a 2880x1800 document.
//  Nothing in the model knows about display points; the canvas view is the only
//  place allowed to scale document coordinates for on-screen display.
//

import Foundation
import CoreGraphics

// MARK: - Color

/// A plain Codable RGBA color. Kept as a value type so `Annotation` stays
/// Codable and Equatable without dragging in NSColor/CGColor reference types.
/// Components are in the sRGB color space, 0...1.
struct CodableColor: Codable, Equatable, Hashable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat

    init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    static let red = CodableColor(red: 1, green: 0.15, blue: 0.15)
    static let black = CodableColor(red: 0, green: 0, blue: 0)
    static let white = CodableColor(red: 1, green: 1, blue: 1)
    static let yellow = CodableColor(red: 1, green: 0.9, blue: 0.2)
    static let blue = CodableColor(red: 0.1, green: 0.45, blue: 1)

    /// sRGB CGColor for drawing.
    var cgColor: CGColor {
        CGColor(colorSpace: CodableColor.colorSpace,
                components: [red, green, blue, alpha]) ?? CGColor(gray: 0, alpha: alpha)
    }

    /// The same color with a different alpha (used for highlighter fills).
    func withAlpha(_ newAlpha: CGFloat) -> CodableColor {
        CodableColor(red: red, green: green, blue: blue, alpha: newAlpha)
    }

    static let colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        ?? CGColorSpaceCreateDeviceRGB()
}

// MARK: - Style

/// Everything about how an annotation looks. One struct for all kinds; kinds
/// simply ignore the fields they do not use.
struct AnnotationStyle: Codable, Equatable {
    var strokeColor: CodableColor
    /// `nil` means "no fill". Rectangles and ellipses are stroke-only by default.
    var fillColor: CodableColor?
    var strokeWidth: CGFloat
    var fontSize: CGFloat
    var badgeRadius: CGFloat

    init(strokeColor: CodableColor = .red,
         fillColor: CodableColor? = nil,
         strokeWidth: CGFloat = 3,
         fontSize: CGFloat = 28,
         badgeRadius: CGFloat = 26) {
        self.strokeColor = strokeColor
        self.fillColor = fillColor
        self.strokeWidth = strokeWidth
        self.fontSize = fontSize
        self.badgeRadius = badgeRadius
    }

    static let `default` = AnnotationStyle()
}

// MARK: - Kind

/// The geometry half of an annotation. All rects and points are in document
/// (image pixel, top-left origin) space.
enum AnnotationKind: Codable, Equatable {
    case rectangle(CGRect)
    case ellipse(CGRect)
    case arrow(from: CGPoint, to: CGPoint)
    case line(from: CGPoint, to: CGPoint)
    case text(rect: CGRect, string: String)
    case badge(center: CGPoint, number: Int)
    case highlight(CGRect)
    case blur(CGRect)
    case path([CGPoint])

    /// True for kinds whose hit test should be stroke proximity rather than
    /// area containment.
    var isStrokeBased: Bool {
        switch self {
        case .arrow, .line, .path: return true
        default: return false
        }
    }

    /// Geometric bounds ignoring stroke width and badge radius.
    /// Use `Annotation.boundingRect` for the drawn bounds.
    var rawBounds: CGRect {
        switch self {
        case .rectangle(let r), .ellipse(let r), .highlight(let r), .blur(let r):
            return r.standardized
        case .text(let r, _):
            return r.standardized
        case .arrow(let a, let b), .line(let a, let b):
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                          width: abs(a.x - b.x), height: abs(a.y - b.y))
        case .badge(let c, _):
            return CGRect(x: c.x, y: c.y, width: 0, height: 0)
        case .path(let points):
            return AnnotationKind.bounds(of: points)
        }
    }

    static func bounds(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Returns a copy shifted by `offset`.
    func translated(by offset: CGPoint) -> AnnotationKind {
        func move(_ r: CGRect) -> CGRect { r.offsetBy(dx: offset.x, dy: offset.y) }
        func move(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + offset.x, y: p.y + offset.y) }

        switch self {
        case .rectangle(let r):          return .rectangle(move(r))
        case .ellipse(let r):            return .ellipse(move(r))
        case .highlight(let r):          return .highlight(move(r))
        case .blur(let r):               return .blur(move(r))
        case .text(let r, let s):        return .text(rect: move(r), string: s)
        case .arrow(let a, let b):       return .arrow(from: move(a), to: move(b))
        case .line(let a, let b):        return .line(from: move(a), to: move(b))
        case .badge(let c, let n):       return .badge(center: move(c), number: n)
        case .path(let pts):             return .path(pts.map(move))
        }
    }

    /// Short label used by undo action names and the future inspector.
    var displayName: String {
        switch self {
        case .rectangle: return "Rectangle"
        case .ellipse:   return "Ellipse"
        case .arrow:     return "Arrow"
        case .line:      return "Line"
        case .text:      return "Text"
        case .badge:     return "Number"
        case .highlight: return "Highlight"
        case .blur:      return "Blur"
        case .path:      return "Freehand"
        }
    }
}

// MARK: - Annotation

struct Annotation: Identifiable, Equatable, Codable {
    var id: UUID
    var kind: AnnotationKind
    var style: AnnotationStyle

    init(id: UUID = UUID(), kind: AnnotationKind, style: AnnotationStyle = .default) {
        self.id = id
        self.kind = kind
        self.style = style
    }

    /// The rect the annotation actually paints into, including half the stroke
    /// width and, for badges, the circle radius. Selection handles and dirty
    /// rects should use this.
    var boundingRect: CGRect {
        switch kind {
        case .badge(let center, _):
            let r = max(style.badgeRadius, 1)
            return CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        case .highlight, .blur:
            return kind.rawBounds
        case .text:
            return kind.rawBounds
        default:
            let pad = max(style.strokeWidth, 1) / 2
            return kind.rawBounds.insetBy(dx: -pad, dy: -pad)
        }
    }

    /// Returns a copy of the annotation moved by `offset`. Identity is kept so
    /// selection survives a drag.
    func translated(by offset: CGPoint) -> Annotation {
        var copy = self
        copy.kind = kind.translated(by: offset)
        return copy
    }

    /// Hit testing in document space.
    /// Stroke-based kinds (line, arrow, freehand path) use distance to the
    /// stroke; everything else uses containment in the drawn bounds.
    /// `tolerance` is extra slack in document pixels, so callers can widen the
    /// target when the canvas is zoomed out.
    func hitTest(_ point: CGPoint, tolerance: CGFloat = 4) -> Bool {
        let slack = max(tolerance, 0) + max(style.strokeWidth, 1) / 2

        switch kind {
        case .line(let a, let b), .arrow(let a, let b):
            return Annotation.distance(from: point, toSegment: a, b: b) <= slack

        case .path(let points):
            guard points.count > 1 else {
                if let only = points.first {
                    return Annotation.distance(from: point, to: only) <= slack
                }
                return false
            }
            for i in 0..<(points.count - 1) {
                if Annotation.distance(from: point, toSegment: points[i], b: points[i + 1]) <= slack {
                    return true
                }
            }
            return false

        case .badge(let center, _):
            return Annotation.distance(from: point, to: center) <= style.badgeRadius + max(tolerance, 0)

        case .ellipse(let rect):
            // Outline-only ellipses are still easiest to grab by their box.
            return rect.standardized.insetBy(dx: -slack, dy: -slack).contains(point)

        default:
            return boundingRect.insetBy(dx: -max(tolerance, 0), dy: -max(tolerance, 0)).contains(point)
        }
    }

    // MARK: Geometry helpers

    static func distance(from p: CGPoint, to q: CGPoint) -> CGFloat {
        hypot(p.x - q.x, p.y - q.y)
    }

    /// Shortest distance from `p` to the finite segment a-b.
    static func distance(from p: CGPoint, toSegment a: CGPoint, b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return distance(from: p, to: a) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared
        t = min(max(t, 0), 1)
        let projection = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        return distance(from: p, to: projection)
    }
}

// MARK: - Badge convenience

extension Annotation {
    /// The number of a badge annotation, or nil for every other kind.
    var badgeNumber: Int? {
        if case .badge(_, let n) = kind { return n }
        return nil
    }

    /// Returns a copy of a badge annotation with a new number. No-op otherwise.
    func withBadgeNumber(_ number: Int) -> Annotation {
        guard case .badge(let center, _) = kind else { return self }
        var copy = self
        copy.kind = .badge(center: center, number: number)
        return copy
    }
}
