//
//  DebugLaunch.swift
//  ZeroShot
//
//  Opens an editor window straight from a PNG on disk, so the canvas can be
//  worked on without going through the capture picker (and without the Screen
//  Recording permission prompt) every time.
//
//  Usage:
//      ZEROSHOT_OPEN_IMAGE=/tmp/zs-test.png open build/DD-canvas/Build/Products/Debug/ZeroShot.app
//  or set the variable in the Xcode scheme's Run action.
//
//  INTEGRATOR NOTE: this does nothing until it is called. Add exactly one line
//  to AppDelegate.applicationDidFinishLaunching in Sources/App/ZeroShotApp.swift:
//
//      DebugLaunch.openIfRequested()
//
//  It is a no-op in every build where the environment variable is absent, and
//  the whole type is compiled out of Release builds.
//

#if DEBUG

import AppKit
import CoreGraphics
import Foundation
import ImageIO

enum DebugLaunch {

    static let environmentKey = "ZEROSHOT_OPEN_IMAGE"

    /// Opens `$ZEROSHOT_OPEN_IMAGE` in an editor window if that variable names
    /// a readable image. Safe to call unconditionally at launch.
    @MainActor
    static func openIfRequested() {
        guard let path = ProcessInfo.processInfo.environment[environmentKey],
              !path.isEmpty else { return }

        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let image = loadImage(at: url) else {
            NSLog("ZeroShot: \(environmentKey) is set to \(path) but no image could be read there")
            return
        }

        let document = EditorDocument(image: image, sourceURL: url)
        if ProcessInfo.processInfo.environment[demoKey] == "1" {
            seedDemoAnnotations(in: document)
        }
        let controller = EditorWindowController(document: document)
        controller.present()
        // One turn later: the SwiftUI hosting view has not built the canvas yet
        // at the moment the window is presented.
        DispatchQueue.main.async { selectRequestedTool(in: controller) }
    }

    // MARK: Debug-only scripting hooks
    //
    // These exist because an agent driving the app from a terminal cannot click
    // in it: they make a specific tool and some sample annotations reachable
    // from the command line so a screenshot can show real layout.

    static let toolKey = "ZEROSHOT_DEBUG_TOOL"
    static let demoKey = "ZEROSHOT_DEBUG_DEMO"

    /// Activates `$ZEROSHOT_DEBUG_TOOL` (a `ToolKind` raw value, e.g. "badge").
    @MainActor
    private static func selectRequestedTool(in controller: EditorWindowController) {
        guard let raw = ProcessInfo.processInfo.environment[toolKey],
              let kind = ToolKind(rawValue: raw),
              let root = controller.window?.contentView,
              let canvas = findCanvas(in: root) else { return }
        canvas.setActiveTool(kind)
    }

    @MainActor
    private static func findCanvas(in view: NSView) -> CanvasView? {
        if let canvas = view as? CanvasView { return canvas }
        for subview in view.subviews {
            if let canvas = findCanvas(in: subview) { return canvas }
        }
        return nil
    }

    /// A badge, a two-digit badge and a line of text, so the renderer can be
    /// eyeballed without drawing anything by hand.
    private static func seedDemoAnnotations(in document: EditorDocument) {
        var badgeStyle = AnnotationStyle()
        badgeStyle.strokeColor = .red
        badgeStyle.badgeRadius = 20
        document.add(Annotation(kind: .badge(center: CGPoint(x: 120, y: 140), number: 1),
                                style: badgeStyle))
        document.add(Annotation(kind: .badge(center: CGPoint(x: 220, y: 140), number: 12),
                                style: badgeStyle))

        var textStyle = AnnotationStyle()
        textStyle.strokeColor = .blue
        textStyle.fontSize = 36
        document.add(Annotation(kind: .text(rect: CGRect(x: 300, y: 110, width: 320, height: 46),
                                            string: "Text annotation"),
                                style: textStyle))
        document.selectedIDs = [document.annotations[1].id]
    }

    private static func loadImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

#endif
