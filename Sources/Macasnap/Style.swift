import AppKit

struct RGB: Codable, Hashable {
    var r: Double
    var g: Double
    var b: Double

    init(_ hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .black
        self.init(r: c.redComponent, g: c.greenComponent, b: c.blueComponent)
    }

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
}

struct GradientPreset: Hashable {
    let name: String
    let colors: [RGB]
    /// Direction in degrees; 0 = left to right, 90 = bottom to top.
    let angle: Double

    static let all: [GradientPreset] = [
        .init(name: "Sunset", colors: [RGB(0xFF7E5F), RGB(0xFEB47B)], angle: 315),
        .init(name: "Candy", colors: [RGB(0xF093FB), RGB(0xF5576C)], angle: 315),
        .init(name: "Ocean", colors: [RGB(0x4FACFE), RGB(0x00F2FE)], angle: 315),
        .init(name: "Mint", colors: [RGB(0x43E97B), RGB(0x38F9D7)], angle: 315),
        .init(name: "Grape", colors: [RGB(0x667EEA), RGB(0x764BA2)], angle: 315),
        .init(name: "Peach", colors: [RGB(0xFFECD2), RGB(0xFCB69F)], angle: 315),
        .init(name: "Aurora", colors: [RGB(0x00C6FB), RGB(0x005BEA)], angle: 270),
        .init(name: "Flamingo", colors: [RGB(0xFA709A), RGB(0xFEE140)], angle: 315),
        .init(name: "Lavender", colors: [RGB(0xA18CD1), RGB(0xFBC2EB)], angle: 315),
        .init(name: "Sonoma", colors: [RGB(0x3A7BD5), RGB(0x8E54E9), RGB(0xF77062)], angle: 315),
        .init(name: "Forest", colors: [RGB(0x134E5E), RGB(0x71B280)], angle: 315),
        .init(name: "Midnight", colors: [RGB(0x232526), RGB(0x414345)], angle: 315),
        .init(name: "Cloud", colors: [RGB(0xE0EAFC), RGB(0xCFDEF3)], angle: 270),
        .init(name: "Fire", colors: [RGB(0xF83600), RGB(0xF9D423)], angle: 315),
    ]
}

enum Background: Codable, Hashable {
    case gradient(Int)
    case wallpaper(String)
    case desktop
    case solid(RGB)
    case none
}

enum AspectRatio: String, Codable, CaseIterable, Identifiable {
    case auto = "Auto"
    case r16x9 = "16:9"
    case r4x3 = "4:3"
    case r3x2 = "3:2"
    case r1x1 = "1:1"
    case r9x16 = "9:16"

    var id: String { rawValue }

    /// width / height, nil for auto.
    var value: Double? {
        switch self {
        case .auto: nil
        case .r16x9: 16.0 / 9
        case .r4x3: 4.0 / 3
        case .r3x2: 3.0 / 2
        case .r1x1: 1
        case .r9x16: 9.0 / 16
        }
    }
}

struct Style: Codable, Hashable {
    var background: Background = .gradient(4)
    /// Padding as a fraction of the average snippet side.
    var padding: Double = 0.12
    /// Corner radius in points.
    var cornerRadius: Double = 12
    /// Shadow strength, 0...1.
    var shadow: Double = 0.5
    /// Trim uneven uniform-colour margins so the content sits evenly inside the snippet.
    var balance: Bool = true
    var aspect: AspectRatio = .auto

    private static let key = "style.v1"

    static func load() -> Style {
        guard let data = UserDefaults.standard.data(forKey: key),
              let style = try? JSONDecoder().decode(Style.self, from: data) else { return Style() }
        return style
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
