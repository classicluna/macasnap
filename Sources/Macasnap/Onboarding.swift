import AppKit
import CoreGraphics
import SwiftUI

@MainActor enum Onboarding {
    private static let key = "onboardingComplete"
    private static var controller: OnboardingWindowController?

    static var isComplete: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func showIfNeeded() {
        guard !isComplete else { return }
        show()
    }

    static func show() {
        if controller == nil { controller = OnboardingWindowController() }
        controller?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor private final class OnboardingModel: ObservableObject {
    @Published var screenRecording = CGPreflightScreenCaptureAccess()
    @Published var shortcutAvailable = !SystemShortcut.isAreaCaptureEnabled
    @Published var launchAtLogin = Prefs.launchAtLogin
    @Published var saveFolderConfigured = true
    @Published var saveFolderPath = Output.saveFolder.path
    /// Set once Grant was pressed: macOS may only report the grant after a relaunch.
    @Published var relaunchNeeded = false

    private var timer: Timer?

    func startPolling() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshScreenRecording() }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func refreshScreenRecording() {
        screenRecording = CGPreflightScreenCaptureAccess()
    }

    func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        relaunchNeeded = true
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        refreshScreenRecording()
    }

    func relaunch() {
        let path = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            NSLog("Macasnap: relaunch failed: \(error)")
        }
    }

    func setShortcutAvailable(_ enabled: Bool) {
        shortcutAvailable = enabled
        SystemShortcut.setAreaCaptureEnabled(!enabled)
        shortcutAvailable = !SystemShortcut.isAreaCaptureEnabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        Prefs.launchAtLogin = enabled
        launchAtLogin = Prefs.launchAtLogin
    }

    func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = Output.saveFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["write", "com.apple.screencapture", "location", url.path]
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                saveFolderConfigured = true
                saveFolderPath = url.path
            }
        } catch {
            NSLog("Macasnap: screenshot folder update failed: \(error)")
        }
    }
}

@MainActor private final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let model = OnboardingModel()

    init() {
        let content = OnboardingView(model: model)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Welcome to Macasnap"
        let hosting = NSHostingView(rootView: content)
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        model.startPolling()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model.stopPolling()
        if model.screenRecording && model.shortcutAvailable { Onboarding.isComplete = true }
        return true
    }
}

@MainActor private struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Macasnap").font(.system(size: 28, weight: .bold))
                Text("Beautiful screenshots on Cmd-Shift-4.").font(.system(size: 14)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 13) {
                stepRow(done: model.screenRecording, title: "Screen Recording access", detail: "Allow Macasnap to capture your screen.") {
                    if model.screenRecording {
                        Text("Granted").foregroundStyle(.secondary)
                    } else {
                        Button(model.relaunchNeeded ? "Grant Again" : "Grant Access") { model.requestScreenRecording() }
                        if model.relaunchNeeded { Button("Relaunch") { model.relaunch() } }
                    }
                }
                stepRow(done: model.shortcutAvailable, title: "Use Cmd-Shift-4 for Macasnap", detail: "Disable the system shortcut to give Macasnap the keys.") {
                    Toggle("Enabled", isOn: Binding(get: { model.shortcutAvailable }, set: { model.setShortcutAvailable($0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                stepRow(done: model.launchAtLogin, title: "Launch at login", detail: "Start Macasnap automatically when you log in.") {
                    Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                stepRow(done: model.saveFolderConfigured, title: "Save folder", detail: abbreviatedPath(model.saveFolderPath)) {
                    Button("Change...") { model.chooseSaveFolder() }
                }
            }
            Spacer(minLength: 0)
            HStack {
                Text("Press Cmd-Shift-4 to capture. Space switches to window mode, Esc cancels.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 10)
                Button("Done") {
                    Onboarding.isComplete = true
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func stepRow<Actions: View>(done: Bool, title: String, detail: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.green : Color.secondary)
                .font(.system(size: 19))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            HStack(spacing: 8, content: actions)
        }
        .frame(minHeight: 48)
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path == home ? "~" : (path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path)
    }
}
