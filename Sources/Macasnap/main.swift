import AppKit
import Carbon.HIToolbox
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem!
    private var hotKeys: [HotKey] = []
    private var editor: EditorWindowController?
    private var updateObserver: AnyCancellable?
    /// The system screenshot shutter; kept alive so playback isn't cut off.
    private let shutter = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif",
        byReference: true
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.register()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Cmd-Shift-4: area capture (Space switches to window mode, like the system tool).
        hotKeys.append(HotKey(keyCode: kVK_ANSI_4, modifiers: cmdKey | shiftKey) { [weak self] in self?.capture(.area) })

        updateObserver = Updater.shared.$available.sink { [weak self] release in
            self?.statusItem.button?.image = Self.statusImage(badged: release != nil)
        }
        Updater.shared.start()
        Onboarding.showIfNeeded()
    }

    /// Menu bar icon, with a dot when an update is waiting.
    private static func statusImage(badged: Bool) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Macasnap") else { return nil }
        guard badged else { return symbol }
        let size = symbol.size
        // Not a template (the dot must stay red), so tint the glyph for the menu bar's appearance at draw time.
        let image = NSImage(size: size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor.labelColor.set()
            rect.fill(using: .sourceAtop)
            NSColor.systemRed.setFill()
            let d = size.width * 0.38
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - d, y: rect.maxY - d, width: d, height: d)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    // Rebuilt on open so toggles reflect current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let release = Updater.shared.available {
            menu.addItem(item("Update to Macasnap \(release.version)...", #selector(installUpdate)))
            menu.addItem(.separator())
        }
        let area = item("Capture Area", #selector(captureArea), key: "4")
        area.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(area)
        menu.addItem(item("Capture Window", #selector(captureWindow)))
        if editor != nil { menu.addItem(item("Show Editor", #selector(showEditor))) }
        menu.addItem(.separator())

        menu.addItem(toggle("Copy to Clipboard After Capture", Prefs.copyOnCapture, #selector(toggleCopy)))
        menu.addItem(toggle("Save to \(Output.saveFolder.lastPathComponent) After Capture", Prefs.saveOnCapture, #selector(toggleSave)))
        menu.addItem(toggle("Show Thumbnail After Capture", Prefs.afterCapture == .thumbnail, #selector(afterCaptureThumbnail)))
        menu.addItem(toggle("Open Editor After Capture", Prefs.afterCapture == .editor, #selector(afterCaptureEditor)))
        menu.addItem(.separator())

        menu.addItem(toggle("Use Cmd-Shift-4 for Macasnap", !SystemShortcut.isAreaCaptureEnabled, #selector(toggleSystemShortcut)))
        menu.addItem(toggle("Launch at Login", Prefs.launchAtLogin, #selector(toggleLaunchAtLogin)))
        menu.addItem(item("Setup Guide...", #selector(showSetupGuide)))
        menu.addItem(item(Updater.shared.isChecking ? "Checking for Updates..." : "Check for Updates...", #selector(checkForUpdates)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Macasnap", #selector(NSApplication.terminate(_:)), key: "q"))
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates) {
            return !Updater.shared.isChecking && !Updater.shared.isInstalling
        }
        return true
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = action == #selector(NSApplication.terminate(_:)) ? NSApp : self
        return item
    }

    private func toggle(_ title: String, _ on: Bool, _ action: Selector) -> NSMenuItem {
        let item = item(title, action)
        item.state = on ? .on : .off
        return item
    }

    @objc private func captureArea() { capture(.area) }
    @objc private func captureWindow() { capture(.window) }
    @objc private func toggleCopy() { Prefs.copyOnCapture.toggle() }
    @objc private func toggleSave() { Prefs.saveOnCapture.toggle() }
    @objc private func afterCaptureThumbnail() { Prefs.afterCapture = .thumbnail }
    @objc private func afterCaptureEditor() { Prefs.afterCapture = .editor }
    @objc private func showSetupGuide() { Onboarding.show() }
    @objc private func installUpdate() { Updater.shared.installAvailable() }
    @objc private func checkForUpdates() { Task { await Updater.shared.checkNow(manual: true) } }
    @objc private func toggleLaunchAtLogin() { Prefs.launchAtLogin.toggle() }
    @objc private func toggleSystemShortcut() {
        SystemShortcut.setAreaCaptureEnabled(!SystemShortcut.isAreaCaptureEnabled)
    }

    @objc private func showEditor() {
        NSApp.activate(ignoringOtherApps: true)
        editor?.showWindow(nil)
        editor?.window?.makeKeyAndOrderFront(nil)
    }

    private func capture(_ mode: CaptureSession.Mode) {
        guard CGPreflightScreenCaptureAccess() else { return showPermissionAlert() }
        CaptureSession.start(mode) { [weak self] outcome in
            switch outcome {
            case .captured(let snap):
                self?.playShutter()
                self?.handle(snap)
            case .cancelled: break
            case .failed(let error):
                NSLog("Macasnap: capture failed: \(error)")
                self?.showPermissionAlert()
            }
        }
    }

    /// Same as the system tool: silent when "Play user interface sound effects" is off.
    private func playShutter() {
        let uiSounds = UserDefaults(suiteName: "com.apple.systemsound")?.object(forKey: "com.apple.sound.uiaudio.enabled") as? Int
        guard uiSounds != 0 else { return }
        shutter?.stop()
        shutter?.play()
    }

    private func showPermissionAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Macasnap needs Screen Recording access"
        alert.informativeText = "Turn on Macasnap in System Settings > Privacy & Security > Screen & System Audio Recording, then relaunch Macasnap. macOS only applies the permission after a relaunch."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Relaunch Macasnap")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            CGRequestScreenCaptureAccess()
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        case .alertSecondButtonReturn:
            relaunch()
        default:
            break
        }
    }

    private func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }

    private func handle(_ snap: Snapshot) {
        let model = EditorModel(snapshot: snap, style: Style.load())
        model.deliverInitial()
        switch Prefs.afterCapture {
        case .editor:
            openEditor(model)
        case .thumbnail:
            guard let image = model.rendered else { return }
            ThumbnailPanel.show(image: image, scale: snap.scale) { [weak self] in self?.openEditor(model) }
        }
    }

    private func openEditor(_ model: EditorModel) {
        ThumbnailPanel.dismiss()
        editor?.onClose = nil
        editor?.close()
        let controller = EditorWindowController(model: model)
        controller.onClose = { [weak self] in self?.editor = nil }
        editor = controller
        showEditor()
    }
}

// `Macasnap --render <in.png> <out.png>` renders a file with the saved style (no UI).
let args = CommandLine.arguments
if args.count == 4, args[1] == "--render" {
    guard let snap = Snapshot(url: URL(fileURLWithPath: args[2])) else {
        FileHandle.standardError.write("cannot read \(args[2])\n".data(using: .utf8)!)
        exit(1)
    }
    var crop: CGRect??
    guard let image = EditorModel.render(snap, crop: &crop, annotations: [], style: Style.load())?.image,
          Output.save(image, scale: snap.scale, to: URL(fileURLWithPath: args[3])) != nil else { exit(1) }
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
