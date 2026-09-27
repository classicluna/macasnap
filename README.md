# Macasnap

Menu bar screenshot beautifier that replaces Cmd-Shift-4.

Press Cmd-Shift-4 and drag out an area (Space switches to window mode, Esc or right-click
cancels). The snippet is centred on a gradient or macOS wallpaper with padding, rounded corners
and a drop shadow, copied to the clipboard, and shown as a floating thumbnail in the corner.
Drag the thumbnail into any app, or click it to open the editor.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/classicluna/macasnap/main/install.sh | bash
```

Installs to `~/Applications/Macasnap.app` and opens it. A setup window then walks through
Screen Recording access, taking over Cmd-Shift-4, launch at login, and the save folder.
Apple Silicon only.

If nothing opens, run the diagnostic and send the output (it is also copied to the clipboard):

```sh
curl -fsSL https://raw.githubusercontent.com/classicluna/macasnap/main/diagnose.sh | bash
```

Macasnap checks GitHub for a new release at launch and every 12 hours. When one exists, the
menu bar icon gets a red dot, the menu shows "Update to Macasnap X...", and the editor shows an
Update button. Updating downloads the release, checks it is signed by the same certificate as the
running app, swaps it in and relaunches; permissions carry over.

## Features

- **Capture**: area or window, frozen-screen overlay with size readout, shutter sound.
- **Balance**: if the snippet has a uniform-colour border, uneven blank margins are trimmed so
  the content sits evenly.
- **Backgrounds**: 14 gradients, the current desktop picture, every still in
  `/System/Library/Desktop Pictures`, any image file, a solid colour, or transparent.
- **Layout**: padding, corner radius, shadow, aspect ratio (Auto, 16:9, 4:3, 3:2, 1:1, 9:16).
- **Markup**: arrows, boxes, text, highlighter and pixelate-redaction, 8 colours, undo (Cmd-Z).
  The wand runs on-device text recognition and redacts emails, phone numbers, card numbers,
  IP addresses and API-key-like tokens.
- **Output**: the clipboard (and the auto-saved file, if enabled) follow every edit. Cmd-C copies,
  Cmd-S saves to the screenshot folder, Cmd-Shift-S saves elsewhere, or drag the preview out.
  PNGs keep the display's pixel density.
- **Menu**: clipboard / auto-save toggles, thumbnail or editor after capture, Cmd-Shift-4
  takeover, launch at login, setup guide.

Saves go to the system screenshot folder (`defaults read com.apple.screencapture location`,
Desktop if unset), so Macasnap and Cmd-Shift-5 agree.

## Development

Requires the Xcode Command Line Tools (Swift 6), macOS 14+. SwiftUI macros (`@State`,
`@Observable`) are unavailable without Xcode; use `ObservableObject`/`@Published`.

```sh
./scripts/build-app.sh            # build/Macasnap.app
./scripts/build-app.sh --install  # copy to ~/Applications and launch
./scripts/release.sh 1.2.0        # bump VERSION, build, tag, publish GitHub release
```

Builds are signed with a self-signed "Macasnap Self-Signed" identity that
`scripts/make-signing-cert.sh` creates on first build in
`~/Library/Keychains/macasnap-signing.keychain-db`. macOS ties the Screen Recording grant and the
updater's signature check to that certificate, so **every release must be signed with the same
one**. Losing it means users must reinstall with the one-liner and grant Screen Recording again.
`scripts/backup-signing-cert.sh` stores it in Bitwarden (secure note with the `.p12` and its
password); `scripts/make-signing-cert.sh --restore FILE.p12` installs a backup on a new machine.

If captures fail although Screen Recording shows as enabled, reset the stale grant with
`tccutil reset ScreenCapture com.evan.macasnap`, relaunch, and grant again.

`Macasnap.app/Contents/MacOS/Macasnap --render in.png out.png` renders a file with the saved style.
