//
//  ExportToolbarItems.swift
//  ZeroShot
//
//  Self-contained SwiftUI view for the editor toolbar's right-hand side: the
//  prominent "Done" button and the "Save to..." destination menu. The editor
//  window (owned by another agent) drops this in at its "// EXPORT SLOT"
//  comment, so this view only needs a document and a completion closure and
//  otherwise reads straight from Preferences.shared / ExportController.shared.
//

import SwiftUI

struct ExportToolbarItems: View {

    let document: EditorDocument
    let onDone: () -> Void

    private var controller: ExportController { .shared }

    var body: some View {
        HStack(spacing: 8) {
            saveToMenu
            doneButton
        }
    }

    // MARK: Done

    private var doneButton: some View {
        Button("Done") {
            controller.performDefault(document: document)
            onDone()
        }
        .keyboardShortcut(.return, modifiers: .command)
        .buttonStyle(.borderedProminent)
    }

    // MARK: Save to...

    private var saveToMenu: some View {
        Menu("Save to...") {
            Button(defaultFolderLabel) {
                controller.saveToFavorite(document: document, folder: Preferences.shared.defaultSaveFolder)
            }

            let favorites = Preferences.shared.favoriteFolders
            if !favorites.isEmpty {
                ForEach(favorites, id: \.self) { folder in
                    Button(folder.lastPathComponent) {
                        controller.saveToFavorite(document: document, folder: folder)
                    }
                }
            }

            Divider()

            Button("Save As...") {
                controller.saveAs(document: document)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Button("Copy Only") {
                controller.copyOnly(document: document)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])

            Button("Open in Preview") {
                controller.openInPreview(document: document)
            }

            Divider()

            Button("Add Current Folder to Favorites") {
                addDefaultFolderToFavorites()
            }

            Button("Manage Favorites...") {
                AppState.shared.showPreferences()
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var defaultFolderLabel: String {
        "Default Folder (\(Preferences.shared.defaultSaveFolder.lastPathComponent))"
    }

    /// "Current folder" here means the configured default save folder, which
    /// is the only folder concept the toolbar itself knows about; per-save
    /// destination tracking would need more state than this view carries.
    private func addDefaultFolderToFavorites() {
        var favorites = Preferences.shared.favoriteFolders
        let folder = Preferences.shared.defaultSaveFolder
        guard !favorites.contains(folder) else { return }
        favorites.append(folder)
        Preferences.shared.favoriteFolders = favorites
    }
}
