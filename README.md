# ZeroShot

A small, native macOS menu bar screenshot tool in the spirit of Greenshot. Press **Cmd+0** to grab the full screen you're currently on, or **Cmd+1** to pick a region with Apple's own picker, and an editor window opens where you crop, draw shapes, add text, and drop auto-numbered badges for documentation. The result goes to the clipboard and a folder.

ZeroShot lives in the menu bar only: no Dock icon, no main window until you take a capture.

## Install

```bash
Scripts/build-release.sh
```

This regenerates the Xcode project, builds a Release binary, and installs it to `/Applications/ZeroShot.app`, quitting any running copy first. Launch it from Spotlight or `open -a ZeroShot`, or add it to your login items so it starts automatically.

## First run

The first time you press Cmd+0 or Cmd+1, macOS asks for **Screen Recording** permission for ZeroShot. Grant it in **System Settings > Privacy & Security > Screen Recording**, then press it again. Until permission is granted, both quietly do nothing (indistinguishable from pressing Esc).

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
| Cmd+2 | Actual size |
| Cmd+9 | Fit to window |
| Esc | Deselect, then close the window |

Shift constrains shapes to squares/circles and arrows to 45 degree steps. Arrow keys nudge the selection 1 px, Shift+arrow 10 px.

Cmd+0 and Cmd+1 are deliberately not zoom shortcuts inside the editor: they are the two global capture hotkeys (Full Screen, Region), both changeable in Preferences.

## Where files go

Screenshots save to **~/Desktop** by default. Change the destination folder, add favorite folders, and edit the filename pattern in **Preferences** (from the menu bar icon). The "Save to..." menu in the editor also offers Save As..., Copy Only, and Open in Preview for one-off destinations.

## Known limits

- No scrolling capture, video recording, OCR, cloud upload, or sharing sheets.
- Full-screen capture (Cmd+0) grabs whichever single display currently has the mouse pointer; use the interactive picker (Cmd+1) if you need to select a region on a specific monitor.
- Not sandboxed and not distributed through the App Store, because it shells out to `/usr/sbin/screencapture` and writes PNGs into user-chosen folders.
- Cmd+0 conflicts with "Actual Size" in browsers and other editors, and Cmd+1 often conflicts with "first tab", while ZeroShot is running; rebind either in Preferences if that collides with your workflow.
