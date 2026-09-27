# Macasnap

Menu bar screenshot beautifier (Xnapper-style) meant to replace Cmd-Shift-4.

Press Cmd-Shift-4, select an area (Space switches to window mode, Esc cancels). The snippet is
centred on a gradient or macOS wallpaper with padding, rounded corners and a drop shadow, copied
to the clipboard, and opened in an editor where you can tweak it.

- **Balance**: if the snippet has a uniform-colour border, uneven blank margins are trimmed to the
  smallest one so the content sits evenly.
- **Backgrounds**: 14 gradients, the current desktop picture, every still in
  `/System/Library/Desktop Pictures`, any image file, a solid colour, or transparent.
- **Editor**: padding, corner radius, shadow, aspect ratio (Auto, 16:9, 4:3, 3:2, 1:1, 9:16).
  Copy (Cmd-C), Save to the screenshot folder (Cmd-S), Save As (Cmd-Shift-S), drag the preview out,
  Esc to close. The last-used style becomes the default for the next capture.
- **Output**: PNG at the display's pixel density (Retina captures stay 2x).

## Build and install

Requires the Xcode Command Line Tools (Swift 6), macOS 14+.

```sh
./scripts/build-app.sh            # build/Macasnap.app
./scripts/build-app.sh --install  # copy to ~/Applications and launch
```

## First run

1. Grant **Screen Recording** when prompted (System Settings > Privacy & Security), then quit and
   relaunch Macasnap. The build is ad-hoc signed, so macOS asks again after each rebuild.
2. In the menu bar icon, enable **Use Cmd-Shift-4 for Macasnap**. This turns off the system
   "Save picture of selected area as a file" shortcut, which otherwise intercepts the key first.
   Unchecking it restores the system shortcut.
3. Optionally enable **Launch at Login**.

Menu toggles also control whether a capture is copied to the clipboard, saved to the screenshot
folder, and whether the editor opens.

## CLI

```sh
Macasnap.app/Contents/MacOS/Macasnap --render in.png out.png
```

Renders a file with the saved style, no UI.
