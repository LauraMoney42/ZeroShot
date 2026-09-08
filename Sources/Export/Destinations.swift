//
//  Destinations.swift
//  ZeroShot
//
//  Greenshot-style export destinations, all funneled through one controller so
//  the toolbar (ExportToolbarItems) stays a thin, self-contained view. Every
//  entry point handles its own errors with an NSAlert; nothing here throws
//  out to a caller.
//

import AppKit
import Foundation

@MainActor
final class ExportController {

    static let shared = ExportController()

    private init() {}

    /// The "Done" button: copy to clipboard (if enabled) and save to the
    /// default folder (if enabled), record the result on AppState, and hand
    /// back the saved URL (nil when saving is off or failed).
    ///
    /// Always marks the document saved on the way out, even when both
    /// destinations are turned off or the folder write fails: "Done" means the
    /// user is finished with this capture, so the unsaved-changes prompt in
    /// `EditorWindowController.windowShouldClose` must not fire afterward.
    @discardableResult
    func performDefault(document: EditorDocument, preferences: Preferences = .shared) -> URL? {
        defer { document.markSaved() }

        if preferences.copyToClipboard {
            Exporter.copyToClipboard(document: document)
        }

        guard preferences.saveToFolder else { return nil }

        do {
            let url = try Exporter.save(document: document, to: preferences.defaultSaveFolder, preferences: preferences)
            AppState.shared.lastSavedURL = url
            return url
        } catch {
            present(error)
            return nil
        }
    }

    /// Standard save panel, pre-filled with the pattern-expanded name and
    /// starting in the default folder.
    func saveAs(document: EditorDocument, preferences: Preferences = .shared) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.directoryURL = preferences.defaultSaveFolder
        panel.nameFieldStringValue = FilenamePattern.expand(preferences.filenamePattern,
                                                             pixelSize: Renderer.outputPixelSize(for: document))

        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let data = Exporter.pngData(for: document) else {
            present(ExportError.renderFailed)
            return
        }

        do {
            try data.write(to: url, options: .atomic)
            document.markSaved()
            AppState.shared.lastSavedURL = url
        } catch {
            present(ExportError.writeFailed(underlying: error))
        }
    }

    /// Save to a favorite (or default) folder chosen from the "Save to..."
    /// menu, outside the copy/save-folder toggles that gate "Done".
    @discardableResult
    func saveToFavorite(document: EditorDocument, folder: URL, preferences: Preferences = .shared) -> URL? {
        do {
            let url = try Exporter.save(document: document, to: folder, preferences: preferences)
            AppState.shared.lastSavedURL = url
            return url
        } catch {
            present(error)
            return nil
        }
    }

    /// Clipboard only, regardless of the copyToClipboard preference.
    func copyOnly(document: EditorDocument) {
        if !Exporter.copyToClipboard(document: document) {
            present(ExportError.renderFailed)
        }
    }

    /// Writes a temp PNG and opens it in Preview, without touching the
    /// document's saved state or the default/favorite folders.
    func openInPreview(document: EditorDocument) {
        guard let data = Exporter.pngData(for: document) else {
            present(ExportError.renderFailed)
            return
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZeroShot-Preview-\(UUID().uuidString).png")

        do {
            try data.write(to: tempURL, options: .atomic)
        } catch {
            present(ExportError.writeFailed(underlying: error))
            return
        }

        if let previewAppURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([tempURL], withApplicationAt: previewAppURL, configuration: configuration) { _, error in
                if let error {
                    Task { @MainActor in self.present(error) }
                }
            }
        } else {
            // Preview is not installed or not discoverable by bundle id; fall
            // back to whatever the user has set as the default PNG viewer.
            NSWorkspace.shared.open(tempURL)
        }
    }

    // MARK: Errors

    private func present(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could Not Export"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
