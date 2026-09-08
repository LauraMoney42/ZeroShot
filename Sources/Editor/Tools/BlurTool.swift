//
//  BlurTool.swift
//  ZeroShot
//
//  Drag out a region to pixellate. The annotation stores nothing but the rect:
//  `Renderer` runs `CIPixellate` over that region of the BASE image at draw
//  time, so the effect follows the rect when it is moved or resized and is
//  thrown away completely when the annotation is deleted.
//
//  STRENGTH
//  --------
//  There is no separate control in the inspector. The stroke width slider
//  doubles as the blur strength: block size is `strokeWidth * 3`, so the
//  1...12 slider covers 3...36 pixel blocks. `Renderer.drawPixellated` is the
//  other half of that contract.
//
//  Pixellate rather than a gaussian blur on purpose: it is not reversible, so a
//  redacted password stays redacted.
//

import AppKit
import CoreGraphics
import Foundation

@MainActor
final class BlurTool: RectDragTool {

    override var kind: ToolKind { .blur }

    override func makeKind(from start: CGPoint, to end: CGPoint, constrained: Bool) -> AnnotationKind {
        .blur(constrained ? AnnotationGeometry.squaredRect(from: start, to: end)
                          : AnnotationGeometry.rect(from: start, to: end))
    }

    /// Blur ignores the stroke colour, but the stroke WIDTH is the block size,
    /// so it has to be carried over from the inspector like any other style.
    override func style(for settings: CanvasSettings) -> AnnotationStyle {
        var style = settings.style
        style.fillColor = nil
        return style
    }
}
