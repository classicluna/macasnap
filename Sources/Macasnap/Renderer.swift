import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A captured image plus its pixel density (pixels per point).
struct Snapshot {
    let image: CGImage
    let scale: CGFloat

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
    }

    init?(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        self.init(image: image, scale: max(1, CGFloat(dpi / 72).rounded()))
    }
}

enum Renderer {
    // MARK: Balance

    /// If the snippet has a uniform-colour border, crops it so the content has equal margins on
    /// every side (the smallest of the four original margins). Otherwise returns the image as is.
    static func balanced(_ image: CGImage) -> CGImage {
        let w = image.width, h = image.height
        guard w > 8, h > 8 else { return image }

        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
        let drawn = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return image }

        // Row 0 of the buffer is the top of the image.
        @inline(__always) func px(_ x: Int, _ y: Int) -> (Int, Int, Int, Int) {
            let i = y * bytesPerRow + x * 4
            return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]), Int(pixels[i + 3]))
        }

        // Most common (quantised) border colour.
        var counts: [Int: Int] = [:]
        var sums: [Int: (Int, Int, Int)] = [:]
        var borderCount = 0
        func sample(_ x: Int, _ y: Int) {
            let (r, g, b, a) = px(x, y)
            borderCount += 1
            guard a == 255 else { return } // transparent edges (window captures) never balance
            let key = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)
            counts[key, default: 0] += 1
            let s = sums[key] ?? (0, 0, 0)
            sums[key] = (s.0 + r, s.1 + g, s.2 + b)
        }
        for x in 0..<w { sample(x, 0); sample(x, h - 1) }
        for y in 1..<(h - 1) { sample(0, y); sample(w - 1, y) }

        guard let (key, count) = counts.max(by: { $0.value < $1.value }),
              Double(count) / Double(borderCount) >= 0.9 else { return image }
        let s = sums[key]!
        let bg = (s.0 / count, s.1 / count, s.2 / count)
        let tolerance = 20

        @inline(__always) func isContent(_ x: Int, _ y: Int) -> Bool {
            let (r, g, b, _) = px(x, y)
            return abs(r - bg.0) > tolerance || abs(g - bg.1) > tolerance || abs(b - bg.2) > tolerance
        }

        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h {
            for x in 0..<w where isContent(x, y) {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                maxY = y
            }
        }
        guard maxX >= 0 else { return image } // blank selection

        let margins = [minX, w - 1 - maxX, minY, h - 1 - maxY]
        let m = margins.min()!
        guard margins.max()! - m > 2 else { return image } // already balanced

        let rect = CGRect(x: minX - m, y: minY - m, width: maxX - minX + 1 + 2 * m, height: maxY - minY + 1 + 2 * m)
        return image.cropping(to: rect) ?? image
    }

    // MARK: Compose

    static func render(_ snap: Snapshot, style: Style, wallpaper: CGImage?) -> CGImage? {
        let image = snap.image
        let scale = snap.scale
        let w = CGFloat(image.width), h = CGFloat(image.height)

        let pad = (style.padding * (w + h) / 2).rounded()
        var canvasW = w + 2 * pad, canvasH = h + 2 * pad
        if let ratio = style.aspect.value {
            if canvasW / canvasH < ratio { canvasW = canvasH * ratio } else { canvasH = canvasW / ratio }
        }
        canvasW = canvasW.rounded()
        canvasH = canvasH.rounded()

        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: Int(canvasW), height: Int(canvasH), bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        let canvas = CGRect(x: 0, y: 0, width: canvasW, height: canvasH)

        drawBackground(style.background, wallpaper: wallpaper, in: canvas, ctx: ctx)

        let snipRect = CGRect(x: ((canvasW - w) / 2).rounded(), y: ((canvasH - h) / 2).rounded(), width: w, height: h)
        let radius = min(style.cornerRadius * scale, min(w, h) / 2)

        ctx.saveGState()
        if style.shadow > 0 {
            let s = style.shadow
            ctx.setShadow(
                offset: CGSize(width: 0, height: -(2 + 14 * s) * scale),
                blur: (6 + 44 * s) * scale,
                color: CGColor(gray: 0, alpha: 0.2 + 0.4 * s)
            )
        }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.addPath(CGPath(roundedRect: snipRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
        ctx.draw(image, in: snipRect)
        ctx.endTransparencyLayer()
        ctx.restoreGState()

        return ctx.makeImage()
    }

    private static func drawBackground(_ background: Background, wallpaper: CGImage?, in rect: CGRect, ctx: CGContext) {
        switch background {
        case .none:
            break
        case .solid(let color):
            ctx.setFillColor(color.cgColor)
            ctx.fill(rect)
        case .gradient(let index):
            let preset = GradientPreset.all[min(max(index, 0), GradientPreset.all.count - 1)]
            let colors = preset.colors.map(\.cgColor) as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: nil) else { return }
            let a = preset.angle * .pi / 180
            let dir = CGPoint(x: cos(a), y: sin(a))
            let half = abs(rect.width / 2 * dir.x) + abs(rect.height / 2 * dir.y)
            let c = CGPoint(x: rect.midX, y: rect.midY)
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: c.x - dir.x * half, y: c.y - dir.y * half),
                end: CGPoint(x: c.x + dir.x * half, y: c.y + dir.y * half),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        case .wallpaper, .desktop:
            guard let wallpaper else {
                ctx.setFillColor(CGColor(gray: 0.2, alpha: 1))
                ctx.fill(rect)
                return
            }
            // Aspect fill.
            let iw = CGFloat(wallpaper.width), ih = CGFloat(wallpaper.height)
            let f = max(rect.width / iw, rect.height / ih)
            let size = CGSize(width: iw * f, height: ih * f)
            ctx.draw(wallpaper, in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
        }
    }

    // MARK: Output

    static func pngData(_ image: CGImage, scale: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        let dpi = 72 * scale
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func nsImage(_ image: CGImage, scale: CGFloat) -> NSImage {
        NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
    }
}
