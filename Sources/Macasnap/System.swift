import AppKit
import Carbon.HIToolbox
import ServiceManagement

// MARK: - Global hotkey (Carbon, needs no Accessibility permission)

final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var eventHandlerInstalled = false

    private var ref: EventHotKeyRef?
    private let id: UInt32

    init(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        Self.installEventHandler()
        id = Self.nextID
        Self.nextID += 1
        Self.handlers[id] = handler
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D534E50), id: id) // 'MSNP'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { NSLog("Macasnap: RegisterEventHotKey failed (\(status))") }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.handlers[id] = nil
    }

    private static func installEventHandler() {
        guard !eventHandlerInstalled else { return }
        eventHandlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            HotKey.handlers[hotKeyID.id]?()
            return noErr
        }, 1, &spec, nil, nil)
    }
}

// MARK: - System Cmd-Shift-4 shortcut

/// The system "Save picture of selected area as a file" shortcut (symbolic hotkey 30) swallows
/// Cmd-Shift-4 before any app sees it, so Macasnap can only own the combo while it is disabled.
enum SystemShortcut {
    private static let domain = "com.apple.symbolichotkeys"
    private static let areaToFile = "30"

    static var isAreaCaptureEnabled: Bool {
        let all = UserDefaults(suiteName: domain)?.dictionary(forKey: "AppleSymbolicHotKeys")
        let entry = all?[areaToFile] as? [String: Any]
        return (entry?["enabled"] as? Bool) ?? true
    }

    static func setAreaCaptureEnabled(_ enabled: Bool) {
        // 52 = '4', 21 = kVK_ANSI_4, 1179648 = Cmd+Shift.
        let entry = """
        <dict><key>enabled</key><\(enabled)/><key>value</key><dict><key>parameters</key>\
        <array><integer>52</integer><integer>21</integer><integer>1179648</integer></array>\
        <key>type</key><string>standard</string></dict></dict>
        """
        run("/usr/bin/defaults", ["write", domain, "AppleSymbolicHotKeys", "-dict-add", areaToFile, entry])
        run("/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings", ["-u"])
    }

    private static func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            NSLog("Macasnap: \(path) failed: \(error)")
        }
    }
}

// MARK: - Preferences

enum Prefs {
    private static let d = UserDefaults.standard

    static func register() {
        d.register(defaults: ["copyOnCapture": true, "saveOnCapture": false, "openEditor": true])
    }

    static var copyOnCapture: Bool {
        get { d.bool(forKey: "copyOnCapture") }
        set { d.set(newValue, forKey: "copyOnCapture") }
    }

    static var saveOnCapture: Bool {
        get { d.bool(forKey: "saveOnCapture") }
        set { d.set(newValue, forKey: "saveOnCapture") }
    }

    static var openEditor: Bool {
        get { d.bool(forKey: "openEditor") }
        set { d.set(newValue, forKey: "openEditor") }
    }

    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Macasnap: launch at login: \(error)")
            }
        }
    }
}

// MARK: - Output

enum Output {
    /// Same folder the system screenshot tool uses (defaults to the Desktop).
    static var saveFolder: URL {
        if let path = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return url }
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    static func defaultFileName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Macasnap \(f.string(from: Date())).png"
    }

    static func copy(_ image: CGImage, scale: CGFloat) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        if let png = Renderer.pngData(image, scale: scale) { item.setData(png, forType: .png) }
        if let tiff = Renderer.nsImage(image, scale: scale).tiffRepresentation { item.setData(tiff, forType: .tiff) }
        pb.writeObjects([item])
    }

    @discardableResult
    static func save(_ image: CGImage, scale: CGFloat, to url: URL? = nil) -> URL? {
        let dest = url ?? saveFolder.appendingPathComponent(defaultFileName())
        guard let data = Renderer.pngData(image, scale: scale) else { return nil }
        do {
            try data.write(to: dest)
            return dest
        } catch {
            NSLog("Macasnap: save failed: \(error)")
            return nil
        }
    }
}
