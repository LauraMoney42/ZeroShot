//
//  EditorWindow.swift
//  ZeroShot
//
//  One window per capture. SwiftUI owns the chrome (tool buttons and the style
//  inspector); the image area is the AppKit `CanvasView`, hosted through
//  `CanvasRepresentable`.
//
//  Tool state and the style for new annotations live in a shared
//  `CanvasSettings` object, which is what lets a single-key shortcut typed on
//  the canvas light up the matching toolbar button and vice versa.
//

import AppKit
import SwiftUI

// MARK: - Window controller

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {

    /// Strong references to every open editor. Without this the controller (and
    /// therefore the window) would be released the moment the caller returns.
    private static var openControllers: [EditorWindowController] = []

    /// Named `editorDocument` rather than `document` because NSWindowController
    /// already declares an `AnyObject?` property called `document`.
    let editorDocument: EditorDocument

    init(document: EditorDocument) {
        self.editorDocument = document

        let contentSize = EditorWindowController.initialContentSize(for: document)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ZeroShot"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 420)
        window.center()

        super.init(window: window)
        // Set after super.init so the Done button can close this controller.
        window.contentView = NSHostingView(
            rootView: EditorView(document: document, onDone: { [weak self] in self?.close() })
        )
        window.delegate = self
        // Route Cmd+Z / Shift+Cmd+Z in this window to the document's stack.
        window.isRestorable = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EditorWindowController is created in code only")
    }

    /// Opens the window and brings the app forward. Needed because a
    /// LSUIElement app is not active when the capture finishes.
    func present() {
        if !EditorWindowController.openControllers.contains(where: { $0 === self }) {
            EditorWindowController.openControllers.append(self)
        }
        // Cascade so a second capture does not land exactly on the first.
        if let window, EditorWindowController.openControllers.count > 1 {
            let offset = CGFloat((EditorWindowController.openControllers.count - 1) % 6) * 24
            window.setFrameOrigin(NSPoint(x: window.frame.origin.x + offset,
                                          y: window.frame.origin.y - offset))
        }
        // Become a regular app while an editor is open so ZeroShot shows in
        // the Dock and in Cmd+Tab. It drops back to a menu bar agent when the
        // last editor closes, so it stays out of the way between captures.
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        // Activation right after a policy change is ignored on macOS 14+, and
        // plain activate() defers to whichever app the user last clicked
        // (which, after the picker, is not us). Hop one run loop turn and
        // insist, so the editor lands in front of every other app.
        WindowActivation.bringToFront(window)
    }

    /// Focus arrived: drop back to a normal window level so the editor can
    /// go behind other windows again like any regular document window.
    func windowDidBecomeKey(_ notification: Notification) {
        WindowActivation.settle(window)
    }

    /// Undo support: AppKit asks the window delegate for the undo manager, so
    /// Cmd+Z reaches the document's stack from anywhere in the window.
    /// `CanvasView.performKeyEquivalent` also handles Cmd+Z directly, because a
    /// menu bar app has no Edit menu of its own to hang the shortcut on.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        editorDocument.undoManager
    }

    func windowWillClose(_ notification: Notification) {
        EditorWindowController.openControllers.removeAll { $0 === self }
        if EditorWindowController.openControllers.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Asks before throwing away unsaved edits. `ExportController.performDefault`
    /// (the same call the Done button makes) always marks the document saved
    /// once it runs, so "Save and Close" and a later re-entrant `close()` do
    /// not loop back into this alert.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard editorDocument.hasUnsavedChanges else { return true }
        guard let window else { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save changes before closing?"
        alert.informativeText = "Your annotations have not been saved."
        alert.addButton(withTitle: "Save and Close")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn: // Save and Close
                ExportController.shared.performDefault(document: self.editorDocument)
                self.close()
            case .alertSecondButtonReturn: // Discard
                self.editorDocument.markSaved()
                self.close()
            default: // Cancel
                break
            }
        }
        return false
    }

    /// Fits the capture on screen at 100% when it is small, otherwise opens at a
    /// comfortable default and lets the canvas fit-to-window take over.
    private static func initialContentSize(for document: EditorDocument) -> NSSize {
        let output = document.outputRect.size
        // Document space is pixels; a 2x capture is twice its point size, so
        // halve by the main screen scale for a sensible first guess.
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let points = NSSize(width: output.width / scale, height: output.height / scale)

        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let maxWidth = visible.width * 0.85
        let maxHeight = visible.height * 0.85

        let width = min(max(points.width + 32, 900), maxWidth)
        let height = min(max(points.height + EditorView.toolbarHeight + 32, 520), maxHeight)
        return NSSize(width: width, height: height)
    }
}

// MARK: - SwiftUI content

struct EditorView: View {
    /// Height reserved for the toolbar strip, used by the window sizing math.
    static let toolbarHeight: CGFloat = 44

    let document: EditorDocument
    /// Called by the export slot's Done button once the capture is out.
    var onDone: () -> Void = {}

    /// Shared with the canvas: which tool is active and what style new
    /// annotations get.
    @State private var settings = CanvasSettings()

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar(document: document, settings: settings, onDone: onDone)
            Divider()
            CanvasRepresentable(document: document, settings: settings)
        }
        .frame(minWidth: 760, minHeight: 420)
    }
}

// MARK: - Toolbar

struct EditorToolbar: View {

    let document: EditorDocument
    @Bindable var settings: CanvasSettings
    var onDone: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            toolButtons

            Divider().frame(height: 22)

            inspector

            Spacer(minLength: 8)

            // EXPORT SLOT: ExportToolbarItems(document:) goes here.
            // Owned by Sources/Export/*; this is the only place it is used.
            ExportToolbarItems(document: document, onDone: onDone)
        }
        .padding(.horizontal, 10)
        .frame(height: EditorView.toolbarHeight)
        .background(.bar)
    }

    // MARK: Tools

    private var toolButtons: some View {
        HStack(spacing: 2) {
            ForEach(ToolKind.allCases) { kind in
                let isActive = settings.toolKind == kind
                let isReady = ToolRegistry.isImplemented(kind)
                Button {
                    settings.toolKind = kind
                } label: {
                    Image(systemName: kind.symbolName)
                        .frame(width: 24, height: 22)
                        .background(isActive ? Color.accentColor.opacity(0.25) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(isReady ? Color.primary : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help(isReady
                      ? "\(kind.displayName) (\(kind.shortcutLabel))"
                      : "\(kind.displayName) (\(kind.shortcutLabel)) - not implemented yet")
            }
        }
    }

    // MARK: Inspector

    private var inspector: some View {
        HStack(spacing: 10) {
            // Icon in front of each color picker: shapes and text use the
            // stroke color, badges have their own, and without a label the two
            // wells look identical when both are on screen.
            HStack(spacing: 3) {
                Image(systemName: "paintpalette")
                    .foregroundStyle(.secondary)
                ColorPicker("Color", selection: colorBinding, supportsOpacity: false)
                    .labelsHidden()
            }
            .help("Color of the selected items, or of new items drawn with the current tool")

            // Stroke and font controls hide while the Number tool is in use
            // (and nothing but badges is selected), so the toolbar only shows
            // controls that affect what the user is doing right now.
            if shapeControlsAreRelevant {
                HStack(spacing: 4) {
                    Image(systemName: "lineweight")
                        .foregroundStyle(.secondary)
                    Slider(value: strokeWidthBinding, in: 1...12, step: 1)
                        .frame(width: 90)
                    Text("\(Int(settings.style.strokeWidth))")
                        .font(.caption.monospacedDigit())
                        .frame(width: 16, alignment: .trailing)
                }
                .help("Stroke width")

                Toggle(isOn: fillBinding) {
                    Image(systemName: settings.isFilled ? "square.fill" : "square")
                }
                .toggleStyle(.button)
                .disabled(!fillIsRelevant)
                .help("Fill rectangles and ellipses")

                HStack(spacing: 4) {
                    Image(systemName: "textformat.size")
                        .foregroundStyle(.secondary)
                    Stepper(value: fontSizeBinding, in: 8...96, step: 2) {
                        Text("\(Int(settings.style.fontSize))")
                            .font(.caption.monospacedDigit())
                            .frame(width: 20, alignment: .trailing)
                    }
                }
                .help("Font size, used by the text tool")
            }

            if badgeInspectorIsRelevant {
                Divider().frame(height: 22)
                badgeInspector
            }
        }
    }

    /// False only when the Number tool is active and the selection holds
    /// nothing but badges: then width, fill and font size would be noise.
    private var shapeControlsAreRelevant: Bool {
        let selected = document.selectedAnnotations
        if selected.contains(where: { $0.badgeNumber == nil }) { return true }
        return settings.toolKind != .badge
    }

    /// Live sample of the badge the next click will drop (or the selected
    /// one), drawn with the real color and relative size. It doubles as the
    /// label for the number controls beside it.
    private var badgePreview: some View {
        let number = selectedBadges.first?.badgeNumber ?? document.peekNextBadgeNumber()
        let radius = CGFloat(EditorToolbar.mediumBadgeRadius)
        let size = 22 * (max(settings.badgeRadius, 6) / radius).squareRoot()
        return ZStack {
            Circle().fill(Color(codable: settings.badgeColor))
            Text("\(number)")
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
        }
        .frame(width: size, height: size)
        .frame(width: 28, height: 28)
        .help(selectedBadges.isEmpty ? "Next number: \(number)" : "Selected number")
    }

    // MARK: Badge inspector

    /// Shown while the badge tool is active or a badge is selected, so the
    /// toolbar stays short the rest of the time.
    private var badgeInspectorIsRelevant: Bool {
        settings.toolKind == .badge || !selectedBadges.isEmpty
    }

    private var selectedBadges: [Annotation] {
        document.selectedAnnotations.filter { $0.badgeNumber != nil }
    }

    private var badgeInspector: some View {
        HStack(spacing: 8) {
            badgePreview

            VStack(alignment: .leading, spacing: 1) {
                Text("Number")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Picker("Badge size", selection: badgeRadiusBinding) {
                    Text("S").tag(EditorToolbar.smallBadgeRadius)
                    Text("M").tag(EditorToolbar.mediumBadgeRadius)
                    Text("L").tag(EditorToolbar.largeBadgeRadius)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 84)
                .help("Size of the number circle")
            }

            // Editing the number of exactly one selected badge. With several
            // selected there is no single number to show.
            if selectedBadges.count == 1 {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Value")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("Number", value: badgeNumberBinding, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 44)
                        .help("Change the number shown in the selected circle")
                }
            }

            Button("Renumber") {
                document.renumberBadges()
            }
            .controlSize(.small)
            .help("Re-sequence every number from 1 in the order they were added")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color(codable: settings.badgeColor).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(Color(codable: settings.badgeColor).opacity(0.35), lineWidth: 1))
    }

    // MARK: Sizes and relevance

    /// Radii in document pixels for the S / M / L badge sizes. Captures are
    /// 2x on Retina, so these read as half that many points on screen.
    static let smallBadgeRadius: Double = 18
    static let mediumBadgeRadius: Double = 26
    static let largeBadgeRadius: Double = 36

    /// Fill only means something for rectangles and ellipses.
    private var fillIsRelevant: Bool {
        if settings.toolKind.supportsFill { return true }
        return document.selectedAnnotations.contains { annotation in
            switch annotation.kind {
            case .rectangle, .ellipse: return true
            default: return false
            }
        }
    }

    // MARK: Bindings
    //
    // Every inspector control does the same two things: update the default
    // style for new annotations, and, when something is selected, apply the
    // change to the selection as one undo step.

    /// The one color control. It edits whatever is selected; with nothing
    /// selected it edits the color new items will get from the current tool.
    /// Badges keep a color of their own (so red arrows and blue numbers can
    /// coexist), but the user only ever sees a single well: it shows the
    /// badge color while the Number tool is active or a badge is selected.
    private var colorBinding: Binding<Color> {
        Binding(
            get: {
                if let first = document.selectedAnnotations.first {
                    return Color(codable: first.style.strokeColor)
                }
                if settings.toolKind == .badge {
                    return Color(codable: settings.badgeColor)
                }
                return Color(codable: settings.style.strokeColor)
            },
            set: { newValue in
                let color = newValue.codableColor
                let selected = document.selectedAnnotations

                if selected.isEmpty {
                    if settings.toolKind == .badge {
                        settings.badgeColor = color
                    } else {
                        setDefaultStrokeColor(color)
                    }
                    return
                }

                // Remember the choice as the default for the kinds that were
                // recolored, so the next badge or shape matches.
                if selected.contains(where: { $0.badgeNumber != nil }) {
                    settings.badgeColor = color
                }
                if selected.contains(where: { $0.badgeNumber == nil }) {
                    setDefaultStrokeColor(color)
                }
                document.applyStyleToSelection(actionName: "Change Color") { style in
                    style.strokeColor = color
                    if style.fillColor != nil { style.fillColor = color.withAlpha(0.25) }
                }
            })
    }

    private func setDefaultStrokeColor(_ color: CodableColor) {
        settings.style.strokeColor = color
        if settings.style.fillColor != nil {
            settings.style.fillColor = color.withAlpha(0.25)
        }
    }

    private var strokeWidthBinding: Binding<Double> {
        Binding(
            get: { Double(settings.style.strokeWidth) },
            set: { newValue in
                let width = CGFloat(newValue.rounded())
                settings.style.strokeWidth = width
                document.applyStyleToSelection(actionName: "Change Stroke Width") { style in
                    style.strokeWidth = width
                }
            })
    }

    private var fillBinding: Binding<Bool> {
        Binding(
            get: { settings.isFilled },
            set: { newValue in
                settings.isFilled = newValue
                let fill = newValue ? settings.style.strokeColor.withAlpha(0.25) : nil
                document.applyStyleToSelection(actionName: "Change Fill") { style in
                    style.fillColor = fill
                }
            })
    }

    private var fontSizeBinding: Binding<Double> {
        Binding(
            get: { Double(settings.style.fontSize) },
            set: { newValue in
                let size = CGFloat(newValue)
                settings.style.fontSize = size
                document.applyStyleToSelection(actionName: "Change Font Size") { style in
                    style.fontSize = size
                }
            })
    }

    // MARK: Badge bindings
    //
    // Badge color and size live outside `style` because a badge is not drawn in
    // the stroke color. Both follow the same rule as every other control: set
    // the default for new badges, and apply to selected badges as one undo step.

    private var badgeRadiusBinding: Binding<Double> {
        Binding(
            get: {
                // Snap whatever is stored to the nearest offered size so the
                // segmented control always shows one selected segment.
                let current = Double(settings.badgeRadius)
                let choices = [EditorToolbar.smallBadgeRadius,
                               EditorToolbar.mediumBadgeRadius,
                               EditorToolbar.largeBadgeRadius]
                return choices.min { abs($0 - current) < abs($1 - current) }
                    ?? EditorToolbar.mediumBadgeRadius
            },
            set: { newValue in
                let radius = CGFloat(newValue)
                settings.badgeRadius = radius
                document.applyStyleToSelectedBadges(actionName: "Change Badge Size") { style in
                    style.badgeRadius = radius
                }
            })
    }

    /// The number of the one selected badge. Reads 0 when the selection is not
    /// a single badge, which the inspector never shows.
    private var badgeNumberBinding: Binding<Int> {
        Binding(
            get: { selectedBadges.first?.badgeNumber ?? 0 },
            set: { newValue in
                guard let badge = selectedBadges.first else { return }
                let clamped = max(newValue, 0)
                guard clamped != badge.badgeNumber else { return }
                document.update(badge.withBadgeNumber(clamped),
                                registersUndo: true,
                                actionName: "Change Badge Number")
            })
    }
}

// MARK: - Style edits on the selection

extension EditorDocument {

    /// Applies a style change to every selected annotation as ONE undo step.
    /// Only the first mutation snapshots, so the group holds a single state.
    func applyStyleToSelection(actionName: String, _ transform: (inout AnnotationStyle) -> Void) {
        let selected = selectedAnnotations
        guard !selected.isEmpty else { return }

        beginUndoGroup(actionName: actionName)
        var isFirst = true
        for annotation in selected {
            var updated = annotation
            transform(&updated.style)
            // A text box is sized for its font; keep it that way after a
            // font-size change so the selection handles and hit area match.
            if case .text(let rect, let string) = updated.kind,
               updated.style.fontSize != annotation.style.fontSize {
                let needed = Renderer.measureText(string, style: updated.style)
                updated.kind = .text(rect: CGRect(origin: rect.origin, size: needed), string: string)
            }
            guard updated != annotation else { continue }
            update(updated, registersUndo: isFirst, actionName: actionName)
            isFirst = false
        }
        endUndoGroup()
    }

    /// Same, but only for the badges in the selection. The badge color control
    /// must not repaint a selected arrow that happens to be selected too.
    func applyStyleToSelectedBadges(actionName: String,
                                    _ transform: (inout AnnotationStyle) -> Void) {
        let badges = selectedAnnotations.filter { $0.badgeNumber != nil }
        guard !badges.isEmpty else { return }

        beginUndoGroup(actionName: actionName)
        var isFirst = true
        for annotation in badges {
            var updated = annotation
            transform(&updated.style)
            guard updated != annotation else { continue }
            update(updated, registersUndo: isFirst, actionName: actionName)
            isFirst = false
        }
        endUndoGroup()
    }
}

// MARK: - Color bridging

extension Color {
    init(codable: CodableColor) {
        self.init(.sRGB,
                  red: Double(codable.red),
                  green: Double(codable.green),
                  blue: Double(codable.blue),
                  opacity: Double(codable.alpha))
    }

    /// SwiftUI colors can live in any color space; the model is sRGB only.
    var codableColor: CodableColor {
        let converted = NSColor(self).usingColorSpace(.sRGB)
        guard let converted else { return .red }
        return CodableColor(red: converted.redComponent,
                            green: converted.greenComponent,
                            blue: converted.blueComponent,
                            alpha: converted.alphaComponent)
    }
}
