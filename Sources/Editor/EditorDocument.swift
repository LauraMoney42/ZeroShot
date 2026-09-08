//
//  EditorDocument.swift
//  ZeroShot
//
//  The model behind one editor window: the captured image, an optional
//  non-destructive crop, the annotation list, the selection, and undo.
//
//  COORDINATE CONVENTION: everything here is in document space, which is image
//  PIXEL space with a TOP-LEFT origin (see Annotation.swift).
//
//  Threading: this type is intended to be used from the main thread only. It is
//  not marked @MainActor so that unit tests and the renderer can touch it
//  freely, but do not mutate it from a background queue.
//

import Foundation
import CoreGraphics
import Observation

@Observable
final class EditorDocument {

    // MARK: Image

    /// The untouched capture. Never mutated; crop is applied at render time.
    let baseImage: CGImage

    /// Size of `baseImage` in pixels. Convenience so callers do not have to
    /// keep converting `Int` dimensions.
    let pixelSize: CGSize

    /// Where the capture came from, if it came from a file. Useful for
    /// "reveal in Finder" later.
    var sourceURL: URL?

    // MARK: Editing state

    /// Non-destructive crop in document (pixel) space. `nil` means no crop.
    private(set) var cropRect: CGRect?

    /// Set by `CropTool` while the user is re-drawing an already applied crop.
    ///
    /// Only the ON-SCREEN canvas honours it (through `displayRect`), so the
    /// whole capture can be shown with the current crop dimmed while the
    /// rectangle is adjusted. `outputRect`, and therefore every export, keeps
    /// returning the applied crop; `Renderer.renderImage` additionally clears
    /// the flag for the duration of a render so a flattened image is never
    /// accidentally uncropped.
    var isSuspendingCropForEditing: Bool = false

    /// Draw order: index 0 is drawn first (bottom).
    private(set) var annotations: [Annotation] = []

    /// IDs of the currently selected annotations.
    var selectedIDs: Set<UUID> = []

    /// The number the next dropped badge should use. Starts at 1 and resets per
    /// capture because each document is one capture.
    private(set) var nextBadgeNumber: Int = 1

    /// Set by every mutating method; cleared by the exporter once saved.
    var hasUnsavedChanges: Bool = false

    /// Undo stack for this window. `EditorWindowController` hands this to the
    /// window so Cmd+Z routes here.
    @ObservationIgnored let undoManager = UndoManager()

    // MARK: Init

    init(image: CGImage, sourceURL: URL? = nil) {
        self.baseImage = image
        self.pixelSize = CGSize(width: image.width, height: image.height)
        self.sourceURL = sourceURL
        self.undoManager.groupsByEvent = false
    }

    // MARK: Derived geometry

    /// Full image rect in document space.
    var imageRect: CGRect {
        CGRect(origin: .zero, size: pixelSize)
    }

    /// The rect that will actually be exported: the crop if there is one,
    /// clamped to the image, otherwise the whole image.
    var outputRect: CGRect {
        guard let crop = cropRect else { return imageRect }
        let clamped = crop.standardized.intersection(imageRect)
        return clamped.isNull || clamped.isEmpty ? imageRect : clamped.integral
    }

    /// The rect the on-screen canvas lays out, converts against and draws.
    ///
    /// Identical to `outputRect` except while the crop tool is adjusting an
    /// applied crop, when it widens back out to the whole image so the user can
    /// see what they are about to bring back. Export never uses this.
    var displayRect: CGRect {
        isSuspendingCropForEditing ? imageRect : outputRect
    }

    var selectedAnnotations: [Annotation] {
        annotations.filter { selectedIDs.contains($0.id) }
    }

    func annotation(withID id: UUID) -> Annotation? {
        annotations.first { $0.id == id }
    }

    /// Topmost annotation under `point`, or nil. Later tools use this for
    /// click-to-select, which is why it walks the array backwards.
    func hitTest(_ point: CGPoint, tolerance: CGFloat = 4) -> Annotation? {
        for annotation in annotations.reversed() where annotation.hitTest(point, tolerance: tolerance) {
            return annotation
        }
        return nil
    }

    // MARK: Mutations
    //
    // Every mutation funnels through here so undo registration happens in
    // exactly one place. `registerUndo` snapshots the whole editing state,
    // which is cheap because annotations are value types.

    @discardableResult
    func add(_ annotation: Annotation, actionName: String? = nil) -> Annotation {
        snapshotForUndo(actionName: actionName ?? "Add \(annotation.kind.displayName)")
        annotations.append(annotation)
        if let number = annotation.badgeNumber {
            nextBadgeNumber = max(nextBadgeNumber, number + 1)
        }
        markDirty()
        return annotation
    }

    func add(contentsOf newAnnotations: [Annotation], actionName: String = "Add Annotations") {
        guard !newAnnotations.isEmpty else { return }
        snapshotForUndo(actionName: actionName)
        annotations.append(contentsOf: newAnnotations)
        for annotation in newAnnotations {
            if let number = annotation.badgeNumber {
                nextBadgeNumber = max(nextBadgeNumber, number + 1)
            }
        }
        markDirty()
    }

    /// Replaces an existing annotation, matched by id.
    ///
    /// Pass `registersUndo: false` for the intermediate states of a live drag,
    /// then call once more with `true` (or wrap the drag in
    /// `beginUndoGroup`/`endUndoGroup`) when the mouse comes up.
    func update(_ annotation: Annotation, registersUndo: Bool = true, actionName: String? = nil) {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        if registersUndo {
            snapshotForUndo(actionName: actionName ?? "Edit \(annotation.kind.displayName)")
        }
        annotations[index] = annotation
        markDirty()
    }

    func remove(ids: Set<UUID>, actionName: String = "Delete") {
        guard !ids.isEmpty, annotations.contains(where: { ids.contains($0.id) }) else { return }
        snapshotForUndo(actionName: actionName)
        annotations.removeAll { ids.contains($0.id) }
        selectedIDs.subtract(ids)
        markDirty()
    }

    func remove(_ annotation: Annotation) {
        remove(ids: [annotation.id], actionName: "Delete \(annotation.kind.displayName)")
    }

    func removeSelected() {
        remove(ids: selectedIDs)
    }

    /// Wholesale replacement, used by paste and by tools that reorder.
    func setAnnotations(_ newAnnotations: [Annotation], actionName: String = "Change Annotations") {
        snapshotForUndo(actionName: actionName)
        annotations = newAnnotations
        selectedIDs = selectedIDs.intersection(Set(newAnnotations.map(\.id)))
        markDirty()
    }

    /// `nil` clears the crop.
    func setCrop(_ rect: CGRect?, actionName: String = "Crop") {
        snapshotForUndo(actionName: actionName)
        if let rect = rect {
            let clamped = rect.standardized.intersection(imageRect)
            cropRect = (clamped.isNull || clamped.isEmpty) ? nil : clamped.integral
        } else {
            cropRect = nil
        }
        markDirty()
    }

    // MARK: Badges

    /// Hands out the next badge number without consuming it. Tools should build
    /// the annotation with this and let `add` bump the counter.
    func peekNextBadgeNumber() -> Int { nextBadgeNumber }

    /// Re-sequences every badge by its position in the draw order, starting at
    /// 1. Deleting a badge leaves a gap on purpose (Greenshot behaviour); this
    /// is the explicit fix-up.
    func renumberBadges(actionName: String = "Renumber Badges") {
        let badgeIndexes = annotations.indices.filter { annotations[$0].badgeNumber != nil }
        guard !badgeIndexes.isEmpty else { return }

        var rebuilt = annotations
        for (offset, index) in badgeIndexes.enumerated() {
            rebuilt[index] = rebuilt[index].withBadgeNumber(offset + 1)
        }
        guard rebuilt != annotations else { return }

        snapshotForUndo(actionName: actionName)
        annotations = rebuilt
        nextBadgeNumber = badgeIndexes.count + 1
        markDirty()
    }

    // MARK: Undo plumbing

    private struct Snapshot {
        var annotations: [Annotation]
        var cropRect: CGRect?
        var nextBadgeNumber: Int
        var selectedIDs: Set<UUID>
        var hasUnsavedChanges: Bool
    }

    private var currentSnapshot: Snapshot {
        Snapshot(annotations: annotations,
                 cropRect: cropRect,
                 nextBadgeNumber: nextBadgeNumber,
                 selectedIDs: selectedIDs,
                 hasUnsavedChanges: hasUnsavedChanges)
    }

    private func apply(_ snapshot: Snapshot) {
        // Register the inverse first so redo works.
        let inverse = currentSnapshot
        undoManager.registerUndo(withTarget: self) { document in
            document.apply(inverse)
        }
        annotations = snapshot.annotations
        cropRect = snapshot.cropRect
        nextBadgeNumber = snapshot.nextBadgeNumber
        selectedIDs = snapshot.selectedIDs.intersection(Set(snapshot.annotations.map(\.id)))
        hasUnsavedChanges = snapshot.hasUnsavedChanges
    }

    /// Depth of the caller-opened groups from `beginUndoGroup`.
    @ObservationIgnored private var explicitGroupDepth = 0

    private func snapshotForUndo(actionName: String) {
        let snapshot = currentSnapshot

        // `groupsByEvent` is off (see init) so undo steps are deterministic
        // rather than depending on run loop turns, which also keeps unit tests
        // honest. That means every registration needs a group of its own,
        // unless a caller already opened one for a drag, or unless we are
        // inside the manager's own undo/redo group.
        let needsGroup = explicitGroupDepth == 0
            && !undoManager.isUndoing
            && !undoManager.isRedoing

        if needsGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { document in
            document.apply(snapshot)
        }
        undoManager.setActionName(actionName)
        if needsGroup { undoManager.endUndoGrouping() }
    }

    private func markDirty() {
        hasUnsavedChanges = true
    }

    /// Groups a run of mutations (a whole drag, say) into one undo step.
    /// Must be balanced by `endUndoGroup()`.
    func beginUndoGroup(actionName: String) {
        undoManager.beginUndoGrouping()
        undoManager.setActionName(actionName)
        explicitGroupDepth += 1
    }

    func endUndoGroup() {
        guard explicitGroupDepth > 0 else { return }
        explicitGroupDepth -= 1
        undoManager.endUndoGrouping()
    }

    /// Called by the exporter once the document has been written somewhere.
    func markSaved() {
        hasUnsavedChanges = false
    }
}
