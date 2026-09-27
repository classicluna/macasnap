// Draws the Macasnap app icon (a dark window floating on a soft wallpaper) and writes an .icns.
// Usage: swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit
import ImageIO
import UniformTypeIdentifiers

let S: CGFloat = 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824) // macOS icon grid: 824pt body in a 1024 canvas
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func hex(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

/// Apple-style continuous-corner squircle (superellipse, n = 5).
func squircle(_ r: CGRect) -> CGPath {
    let p = CGMutablePath(), n = 5.0, a = r.width / 2, b = r.height / 2
    for i in 0...720 {
        let t = Double(i) / 720 * 2 * .pi
        let c = cos(t), s = sin(t)
        let pt = CGPoint(x: r.midX + a * CGFloat(copysign(pow(abs(c), 2 / n), c)),
                         y: r.midY + b * CGFloat(copysign(pow(abs(s), 2 / n), s)))
        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
    }
    p.closeSubpath()
    return p
}

func rrect(_ r: CGRect, _ radius: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil) }

func radial(_ ctx: CGContext, _ color: CGColor, at c: CGPoint, radius: CGFloat) {
    let g = CGGradient(colorsSpace: sRGB, colors: [color, color.copy(alpha: 0)!] as CFArray, locations: nil)!
    ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: radius, options: [])
}

func drawIcon() -> CGImage {
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Body shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: hex(0, 0.35))
    ctx.addPath(squircle(body)); ctx.setFillColor(hex(0)); ctx.fillPath()
    ctx.restoreGState()

    // Wallpaper: warm vertical gradient with soft colour blooms.
    ctx.saveGState()
    ctx.addPath(squircle(body)); ctx.clip()
    let wall = CGGradient(colorsSpace: sRGB, colors: [hex(0xFFB88C), hex(0xDE6262)] as CFArray, locations: nil)!
    ctx.drawLinearGradient(wall, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])
    radial(ctx, hex(0x8E54E9, 0.9), at: CGPoint(x: 230, y: 250), radius: 520)
    radial(ctx, hex(0x3A7BD5, 0.8), at: CGPoint(x: 900, y: 180), radius: 420)
    radial(ctx, hex(0xFEE140, 0.6), at: CGPoint(x: 820, y: 900), radius: 380)

    // Floating dark window.
    let win = CGRect(x: 205, y: 280, width: 614, height: 464)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 50, color: hex(0, 0.45))
    ctx.addPath(rrect(win, 34)); ctx.setFillColor(hex(0x1E1E24)); ctx.fillPath()
    ctx.restoreGState()
    let bar = win.height * 0.16
    ctx.saveGState()
    ctx.addPath(rrect(win, 34)); ctx.clip()
    ctx.setFillColor(hex(0x2C2C34)); ctx.fill(CGRect(x: win.minX, y: win.maxY - bar, width: win.width, height: bar))
    ctx.restoreGState()
    let dot = bar * 0.34
    for (i, c) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
        ctx.setFillColor(hex(UInt32(c)))
        ctx.fillEllipse(in: CGRect(x: win.minX + bar * 0.45 + CGFloat(i) * dot * 1.6, y: win.maxY - bar / 2 - dot / 2, width: dot, height: dot))
    }
    let lineH = win.height * 0.07, left = win.minX + win.width * 0.1
    for (i, w) in [0.62, 0.8, 0.48, 0.7].enumerated() {
        let y = win.maxY - bar - win.height * 0.14 - CGFloat(i) * lineH * 1.9
        ctx.addPath(rrect(CGRect(x: left, y: y - lineH, width: win.width * 0.8 * w, height: lineH), lineH / 2))
        ctx.setFillColor(hex(0xFFFFFF, 0.22)); ctx.fillPath()
    }
    ctx.restoreGState()

    // Hairline edge.
    ctx.addPath(squircle(body.insetBy(dx: 1, dy: 1)))
    ctx.setStrokeColor(hex(0xFFFFFF, 0.18)); ctx.setLineWidth(2); ctx.strokePath()
    return ctx.makeImage()!
}

func resized(_ image: CGImage, _ px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: px, height: px))
    return ctx.makeImage()!
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: swift scripts/make-icon.swift OUTPUT.icns\n".data(using: .utf8)!)
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

let master = drawIcon()
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
        let dest = CGImageDestinationCreateWithURL(iconset.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, resized(master, size * scale), nil)
        guard CGImageDestinationFinalize(dest) else { exit(1) }
    }
}
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
exit(iconutil.terminationStatus)
