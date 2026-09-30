import AppKit
import Combine
import Security

@MainActor
final class Updater: NSObject, ObservableObject {
    static let shared = Updater()
    static let repo = "classicluna/macasnap"

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    struct Release: Equatable {
        let version: String
        let zipURL: URL
        let pageURL: URL
    }

    @Published private(set) var available: Release?
    @Published private(set) var isInstalling = false
    @Published private(set) var lastError: String?

    private var timer: Timer?
    private var started = false
    /// Version already announced this session; "Later" leaves only the menu bar dot until the next launch.
    private var promptedVersion: String?
    private var updateAlert: NSAlert?

    private override init() {}

    func start() {
        guard !started, Bundle.main.bundleURL.pathExtension == "app" else { return }
        started = true
        Task { await checkNow() }
        timer = Timer.scheduledTimer(withTimeInterval: 12 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkNow() }
        }
    }

    func checkNow() async {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest") else { return }

        do {
            // GitHub marks this response cacheable for 60 s; a fresh release must show up immediately.
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Macasnap Updater", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else {
                throw UpdaterError.invalidResponse
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let page = json["html_url"] as? String,
                  let assets = json["assets"] as? [[String: Any]],
                  let asset = assets.first(where: { $0["name"] as? String == "Macasnap.zip" }),
                  let zip = asset["browser_download_url"] as? String,
                  let zipURL = URL(string: zip), let pageURL = URL(string: page) else {
                throw UpdaterError.invalidRelease
            }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            available = Self.isNewer(version, than: Self.currentVersion)
                ? Release(version: version, zipURL: zipURL, pageURL: pageURL) : nil
            lastError = nil
            if let release = available, release.version != promptedVersion {
                promptedVersion = release.version
                promptToInstall(release)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func installAvailable() {
        guard let release = available, !isInstalling else { return }
        isInstalling = true
        Task { await install(release) }
    }

    /// Floats the alert without activating Macasnap, so keystrokes meant for the frontmost app can't press a button,
    /// and without a modal loop, so captures keep working while it is ignored.
    private func promptToInstall(_ release: Release) {
        closeUpdateAlert()
        let alert = NSAlert()
        alert.messageText = "Macasnap \(release.version) is available"
        alert.informativeText = "You have \(Self.currentVersion). Macasnap will restart to finish updating. You can also update later from the menu bar icon."
        let install = alert.addButton(withTitle: "Install Update")
        install.target = self
        install.action = #selector(installFromAlert)
        let later = alert.addButton(withTitle: "Later")
        later.target = self
        later.action = #selector(closeUpdateAlert)
        alert.layout()
        alert.window.level = .floating
        alert.window.center()
        alert.window.orderFrontRegardless()
        updateAlert = alert
    }

    @objc private func installFromAlert() {
        closeUpdateAlert()
        installAvailable()
    }

    @objc private func closeUpdateAlert() {
        updateAlert?.window.orderOut(nil)
        updateAlert = nil
    }

    private func install(_ release: Release) async {
        defer { isInstalling = false }
        let manager = FileManager.default
        let temp = manager.temporaryDirectory.appendingPathComponent("Macasnap-update-\(UUID().uuidString)")
        do {
            try manager.createDirectory(at: temp, withIntermediateDirectories: true)
            let (archive, response) = try await URLSession.shared.download(from: release.zipURL)
            guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else {
                throw UpdaterError.invalidResponse
            }
            let localArchive = temp.appendingPathComponent("Macasnap.zip")
            try manager.moveItem(at: archive, to: localArchive)
            try Self.run("/usr/bin/ditto", ["-x", "-k", localArchive.path, temp.path])

            guard let enumerator = manager.enumerator(at: temp, includingPropertiesForKeys: [.isDirectoryKey]),
                  let newBundle = enumerator.allObjects.compactMap({ $0 as? URL }).first(where: {
                      $0.lastPathComponent == "Macasnap.app"
                  }) else { throw UpdaterError.bundleNotFound }
            try Self.verify(newBundle)

            let oldBundle = Bundle.main.bundleURL
            let backup = temp.appendingPathComponent("Macasnap-old.app")
            try manager.moveItem(at: oldBundle, to: backup)
            do {
                try manager.moveItem(at: newBundle, to: oldBundle)
            } catch {
                do { try manager.moveItem(at: backup, to: oldBundle) }
                catch { throw UpdaterError.restoreFailed(error.localizedDescription) }
                throw error
            }
            _ = try? Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", oldBundle.path], allowFailure: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", oldBundle.path]
            try process.run()
            NSApp.terminate(nil)
        } catch {
            lastError = error.localizedDescription
            Self.showInstallError(error.localizedDescription)
        }
        try? manager.removeItem(at: temp)
    }

    private static func verify(_ bundle: URL) throws {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else { throw UpdaterError.signature("Could not read the downloaded app signature.") }
        var runningCode: SecCode?
        var runningStatic: SecStaticCode?
        guard SecCodeCopySelf(SecCSFlags(), &runningCode) == errSecSuccess, let runningCode,
              SecCodeCopyStaticCode(runningCode, SecCSFlags(), &runningStatic) == errSecSuccess, let runningStatic else {
            throw UpdaterError.signature("Could not read the running app signature.")
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(runningStatic, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement else { throw UpdaterError.signature("Could not read the app signing requirement.") }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        let result = SecStaticCodeCheckValidity(staticCode, flags, requirement)
        guard result == errSecSuccess else {
            throw UpdaterError.signature("The downloaded app does not match this app's signature (\(result)).")
        }
    }

    private static func run(_ path: String, _ arguments: [String], allowFailure: Bool = false) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 && !allowFailure { throw UpdaterError.commandFailed(path) }
    }

    private static func showInstallError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Macasnap could not install the update"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private enum UpdaterError: LocalizedError {
        case invalidResponse
        case invalidRelease
        case bundleNotFound
        case commandFailed(String)
        case signature(String)
        case restoreFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "The update server returned an invalid response."
            case .invalidRelease: return "The latest release is missing required information."
            case .bundleNotFound: return "The downloaded archive does not contain Macasnap.app."
            case .commandFailed(let command): return "The command failed: \(command)."
            case .signature(let message): return message
            case .restoreFailed(let message): return "The update failed and the previous app could not be restored: \(message)"
            }
        }
    }
}
