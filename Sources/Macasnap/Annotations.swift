import AppKit
import CoreText
import Vision

// MARK: - Model

/// A markup element. Geometry is in the original capture's pixels, top-left origin, so it stays
/// put when balance or padding change.
struct Annotation: Identifiable, Equatable {
    enum Kind: Equatable {
        case arrow(from: CGPoint, to: CGPoint)
        case box(CGRect)
        case highlight(CGRect)
        case redact(CGRect)
        case text(String, at: CGPoint)
    }

    let id = UUID()
    var kind: Kind
    var color: RGB
}

enum AnnotationTool: String, CaseIterable, Identifiable {
    case none, arrow, box, text, highlight, redact

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .none: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .box: "rectangle"
        case .text: "textformat"
        case .highlight: "highlighter"
        case .redact: "square.grid.3x3.fill"
        }
    }

    var label: String {
        switch self {
        case .none: "Move (drag the image out)"
        case .arrow: "Arrow"
        case .box: "Box"
        case .text: "Text"
        case .highlight: "Highlighter"
        case .redact: "Redact (pixelate)"
        }
    }
}

enum AnnotationPalette {
    static let colors: [RGB] = [
        RGB(0xFF3B30), RGB(0xFF9500), RGB(0xFFCC00), RGB(0x34C759),
        RGB(0x007AFF), RGB(0xAF52DE), RGB(0xFFFFFF), RGB(0x000000),
    ]

    /// Stroke width in pixels for a capture of the given pixel density.
    static func lineWidth(scale: CGFloat) -> CGFloat { 3 * scale }
    static func fontSize(scale: CGFloat) -> CGFloat { 20 * scale }
}

// MARK: - Flattening

enum Annotator {
    /// Draws the annotations onto a copy of `image`.
    static func flatten(_ image: CGImage, annotations: [Annotation], scale: CGFloat) -> CGImage {
        guard !annotations.isEmpty else { return image }
        let w = image.width, h = image.height
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.draw(image, in: full)

        // Redactions sample the untouched capture and sit beneath all other markup.
        for case .redact(let rect) in annotations.map(\.kind) {
            pixelate(image, rect: rect, into: ctx, scale: scale)
        }

        // Everything else is drawn with a top-left origin to match the stored geometry.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        let lw = AnnotationPalette.lineWidth(scale: scale)
        for annotation in annotations {
            let color = annotation.color.cgColor
            switch annotation.kind {
            case .redact:
                continue
            case .highlight(let rect):
                ctx.setFillColor(color.copy(alpha: 0.35) ?? color)
                ctx.fill(rect)
            case .box(let rect):
                ctx.setStrokeColor(color)
                ctx.setLineWidth(lw)
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: lw * 1.5, cornerHeight: lw * 1.5, transform: nil))
                ctx.strokePath()
            case .arrow(let from, let to):
                ctx.setStrokeColor(color)
                ctx.setFillColor(color)
                ctx.addPath(arrowPath(from: from, to: to, lineWidth: lw))
                ctx.fillPath()
            case .text(let string, let origin):
                drawText(string, at: origin, color: annotation.color, scale: scale, ctx: ctx)
            }
        }
        return ctx.makeImage() ?? image
    }

    /// Filled arrow outline (shaft plus head) so it renders identically in CG and SwiftUI.
    static func arrowPath(from: CGPoint, to: CGPoint, lineWidth lw: CGFloat) -> CGPath {
        let dx = to.x - from.x, dy = to.y - from.y
        let length = max(hypot(dx, dy), 0.001)
        let ux = dx / length, uy = dy / length // along the arrow
        let px = -uy, py = ux                  // perpendicular
        let headLength = min(lw * 5, length * 0.6)
        let headHalf = headLength * 0.55
        let base = CGPoint(x: to.x - ux * headLength, y: to.y - uy * headLength)

        let path = CGMutablePath()
        path.move(to: CGPoint(x: from.x + px * lw / 2, y: from.y + py * lw / 2))
        path.addLine(to: CGPoint(x: base.x + px * lw / 2, y: base.y + py * lw / 2))
        path.addLine(to: CGPoint(x: base.x + px * headHalf, y: base.y + py * headHalf))
        path.addLine(to: to)
        path.addLine(to: CGPoint(x: base.x - px * headHalf, y: base.y - py * headHalf))
        path.addLine(to: CGPoint(x: base.x - px * lw / 2, y: base.y - py * lw / 2))
        path.addLine(to: CGPoint(x: from.x - px * lw / 2, y: from.y - py * lw / 2))
        path.closeSubpath()
        return path
    }

    static func textAttributes(color: RGB, scale: CGFloat) -> [NSAttributedString.Key: Any] {
        let base = NSFont.systemFont(ofSize: AnnotationPalette.fontSize(scale: scale), weight: .bold)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: base.pointSize) } ?? base
        return [.font: font, .foregroundColor: color.nsColor]
    }

    private static func drawText(_ string: String, at origin: CGPoint, color: RGB, scale: CGFloat, ctx: CGContext) {
        let attributed = NSAttributedString(string: string, attributes: textAttributes(color: color, scale: scale))
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, nil, nil)
        ctx.saveGState()
        // A dark halo lifts coloured text off busy UI; near-black text gets a light one instead.
        let luminance = 0.299 * color.r + 0.587 * color.g + 0.114 * color.b
        ctx.setShadow(offset: .zero, blur: 3 * scale, color: CGColor(gray: luminance < 0.15 ? 1 : 0, alpha: 0.6))
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: origin.x, y: origin.y + ascent)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// Mosaic of the region: unrecoverable, unlike a blur.
    private static func pixelate(_ image: CGImage, rect: CGRect, into ctx: CGContext, scale: CGFloat) {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let r = rect.standardized.integral.intersection(bounds)
        guard r.width >= 1, r.height >= 1, let patch = image.cropping(to: r) else { return }
        let block = max(8, 7 * scale)
        let sw = max(1, Int((r.width / block).rounded(.up))), sh = max(1, Int((r.height / block).rounded(.up)))
        guard let small = CGContext(data: nil, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        small.interpolationQuality = .medium
        small.draw(patch, in: CGRect(x: 0, y: 0, width: sw, height: sh))
        guard let mosaic = small.makeImage() else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .none
        // The context is still bottom-left here.
        ctx.draw(mosaic, in: CGRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height))
        ctx.restoreGState()
    }
}

// MARK: - Auto-redact

enum Redactor {
    /// Rectangles (pixels, top-left origin) around emails, phone numbers, card numbers, IP
    /// addresses and API-key-like tokens found by on-device text recognition.
    static func sensitiveRegions(in image: CGImage) async -> [CGRect] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: detect(in: image))
            }
        }
    }

    private static func detect(in image: CGImage) -> [CGRect] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            NSLog("Macasnap: text recognition failed: \(error)")
            return []
        }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        var rects: [CGRect] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            for range in sensitiveRanges(in: candidate.string) {
                guard let box = try? candidate.boundingBox(for: range)?.boundingBox else { continue }
                let rect = CGRect(x: box.minX * w, y: (1 - box.maxY) * h, width: box.width * w, height: box.height * h)
                rects.append(rect.insetBy(dx: -rect.height * 0.15, dy: -rect.height * 0.2))
            }
        }
        return rects
    }

    private static let patterns: [NSRegularExpression] = [
        #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,                                     // email
        #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#,                                              // IPv4
        #"\b(?=[A-Za-z0-9_\-]*\d)(?=[A-Za-z0-9_\-]*[A-Za-z])[A-Za-z0-9_\-]{24,}\b"#,  // tokens / keys
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    private static let cardPattern = try! NSRegularExpression(pattern: #"\b(?:\d[ -]?){13,19}\b"#)
    private static let phoneDetector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue)

    static func sensitiveRanges(in string: String) -> [Range<String.Index>] {
        let whole = NSRange(string.startIndex..., in: string)
        var found: [NSRange] = []
        for regex in patterns {
            found += regex.matches(in: string, range: whole).map(\.range)
        }
        found += cardPattern.matches(in: string, range: whole).map(\.range).filter { range in
            luhnValid(((string as NSString).substring(with: range)).filter(\.isNumber))
        }
        found += phoneDetector.matches(in: string, range: whole).map(\.range)
        return found.compactMap { Range($0, in: string) }
    }

    private static func luhnValid(_ digits: String) -> Bool {
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (i, ch) in digits.reversed().enumerated() {
            guard var d = ch.wholeNumberValue else { return false }
            if i % 2 == 1 { d *= 2; if d > 9 { d -= 9 } }
            sum += d
        }
        return sum % 10 == 0
    }
}
