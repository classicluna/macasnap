import AppKit
import ImageIO

enum Wallpapers {
    /// Full-resolution stills shipped with macOS (the .madesktop entries are only thumbnails).
    static let builtIn: [URL] = {
        let dir = URL(fileURLWithPath: "/System/Library/Desktop Pictures")
        let exts: Set<String> = ["heic", "jpg", "jpeg", "png"]
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return files.filter { exts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }()

    static var currentDesktop: URL? {
        guard let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return url
    }

    static func url(for background: Background) -> URL? {
        switch background {
        case .wallpaper(let path): URL(fileURLWithPath: path)
        case .desktop: currentDesktop
        default: nil
        }
    }

    private static let cache = NSCache<NSString, CGImage>()
    private static let lock = NSLock()

    /// Decodes (and downsamples) an image; safe to call off the main thread.
    static func image(at url: URL, maxPixel: Int) -> CGImage? {
        let key = "\(url.path)#\(maxPixel)" as NSString
        lock.lock()
        let cached = cache.object(forKey: key)
        lock.unlock()
        if let cached { return cached }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        lock.lock()
        cache.setObject(image, forKey: key)
        lock.unlock()
        return image
    }
}
