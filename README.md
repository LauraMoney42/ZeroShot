# ZeroShot

A small, native macOS menu bar screenshot tool in the spirit of Greenshot. Press **Cmd+0**, pick a region with Apple's own picker, and an editor window opens where you crop, draw shapes, add text, and drop auto-numbered badges for documentation. The result goes to the clipboard and a folder.

ZeroShot lives in the menu bar only: no Dock icon, no main window until you take a capture.

## Install

```bash
Scripts/build-release.sh
```

This regenerates the Xcode project, builds a Release binary, and installs it to `/Applications/ZeroShot.app`, quitting any running copy first. Launch it from Spotlight or `open -a ZeroShot`, or add it to your login items so it starts automatically.

## First run

The first time you press Cmd+0, macOS asks for **Screen Recording** permission for ZeroShot. Grant it in **System Settings > Privacy & Security > Screen Recording**, then press Cmd+0 again. Until permission is granted, Cmd+0 quietly does nothing (indistinguishable from pressing Esc).

ZeroShot is signed with a stable Apple Development identity, so this permission survives rebuilds and future installs from `Scripts/build-release.sh`.

## Editor shortcuts

| Key | Action |
|---|---|
| V | Select tool |
| C | Crop tool |
| R | Rectangle |
| E | Ellipse |
| A | Arrow |
| L | Line |
| T | Text |
| N | Number badge |
| H | Highlighter |
| B | Blur / pixelate |
| P | Freehand pen |
| Delete | Remove selection |
| Cmd+Z / Shift+Cmd+Z | Undo / redo |
| Cmd+Return | Done (flatten, copy, save, close) |
| Cmd+Shift+S | Save As... |
| Cmd+Shift+C | Copy only |
| Cmd+1 | Actual size |
| Cmd+9 | Fit to window |
| Esc | Deselect, then close the window |

Shift constrains shapes to squares/circles and arrows to 45 degree steps. Arrow keys nudge the selection 1 px, Shift+arrow 10 px.

Cmd+0 is deliberately not a zoom shortcut inside the editor: it is the global capture hotkey, changeable in Preferences.

## Where files go

Screenshots save to **~/Desktop** by default. Change the destination folder, add favorite folders, and edit the filename pattern in **Preferences** (from the menu bar icon). The "Save to..." menu in the editor also offers Save As..., Copy Only, and Open in Preview for one-off destinations.

## Known limits

- No scrolling capture, video recording, OCR, cloud upload, or sharing sheets.
- Full-screen capture grabs the main display only; use the interactive picker (Cmd+0) for multi-monitor setups.
- Not sandboxed and not distributed through the App Store, because it shells out to `/usr/sbin/screencapture` and writes PNGs into user-chosen folders.
- Cmd+0 conflicts with "Actual Size" in browsers and other editors while ZeroShot is running; rebind it in Preferences if that collides with your workflow.
