import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model

@MainActor
final class EditorModel: ObservableObject {
    @Published var style: Style {
        didSet {
            guard style != oldValue else { return }
            style.save()
            rerender()
        }
    }
    @Published private(set) var rendered: CGImage?
    @Published var toast: String?

    private(set) var snapshot: Snapshot
    private var balancedImage: CGImage?
    private var renderTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    init(snapshot: Snapshot, style: Style) {
        self.snapshot = snapshot
        self.style = style
        rendered = Self.render(snapshot, balanced: &balancedImage, style: style)
    }

    var scale: CGFloat { snapshot.scale }

    /// Full pipeline: optional balance crop, then background composition.
    nonisolated static func render(_ snap: Snapshot, balanced: inout CGImage?, style: Style) -> CGImage? {
        var input = snap
        if style.balance {
            if balanced == nil { balanced = Renderer.balanced(snap.image) }
            input = Snapshot(image: balanced!, scale: snap.scale)
        }
        let wallpaper = Wallpapers.url(for: style.background).flatMap { Wallpapers.image(at: $0, maxPixel: 4096) }
        return Renderer.render(input, style: style, wallpaper: wallpaper)
    }

    private func rerender() {
        renderTask?.cancel()
        let snap = snapshot, style = style, cachedBalance = balancedImage
        renderTask = Task.detached(priority: .userInitiated) { [weak self] in
            var balanced = cachedBalance
            let image = EditorModel.render(snap, balanced: &balanced, style: style)
            await self?.finishRender(image, balanced: balanced)
        }
    }

    private func finishRender(_ image: CGImage?, balanced: CGImage?) {
        guard !Task.isCancelled else { return }
        balancedImage = balanced
        rendered = image
    }

    func copy() {
        guard let rendered else { return }
        Output.copy(rendered, scale: scale)
        show("Copied to clipboard")
    }

    func save() {
        guard let rendered else { return }
        if let url = Output.save(rendered, scale: scale) { show("Saved to \(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)") }
    }

    func saveAs() {
        guard let rendered else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = Output.defaultFileName()
        panel.directoryURL = Output.saveFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if Output.save(rendered, scale: scale, to: url) != nil { show("Saved") }
    }

    func chooseWallpaper() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        style.background = .wallpaper(url.path)
    }

    /// A temp PNG for dragging the result into other apps / Finder.
    func dragProvider() -> NSItemProvider {
        guard let rendered, let data = Renderer.pngData(rendered, scale: scale) else { return NSItemProvider() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(Output.defaultFileName())
        try? data.write(to: url)
        return NSItemProvider(contentsOf: url) ?? NSItemProvider()
    }

    private func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}

// MARK: - Window

final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let model: EditorModel
    var onClose: (() -> Void)?

    init(model: EditorModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "Macasnap"
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 760, height: 480)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: EditorView(model: model, close: { [weak window] in window?.close() }))
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) { onClose?() }
}

// MARK: - Views

struct EditorView: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            preview
            Divider()
            Sidebar(model: model, close: close)
                .frame(width: 300)
        }
        .frame(minWidth: 760, minHeight: 480)
    }

    private var preview: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            if let image = model.rendered {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .shadow(color: .black.opacity(0.15), radius: 8)
                    .padding(32)
                    .onDrag { model.dragProvider() }
            }
            if let toast = model.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 20)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.toast)
    }
}

private struct Sidebar: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void

    private let columns = Array(repeating: GridItem(.fixed(56), spacing: 8), count: 4)

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("Gradients") {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(GradientPreset.all.indices, id: \.self) { i in
                                swatch(.gradient(i)) { GradientSwatch(preset: GradientPreset.all[i]) }
                                    .help(GradientPreset.all[i].name)
                            }
                        }
                    }

                    section("Wallpapers") {
                        LazyVGrid(columns: columns, spacing: 8) {
                            swatch(.desktop) {
                                ZStack {
                                    if let url = Wallpapers.currentDesktop { Thumbnail(url: url) } else { Color.gray }
                                    Image(systemName: "desktopcomputer").font(.title3).foregroundStyle(.white).shadow(radius: 2)
                                }
                            }
                            .help("Current desktop picture")
                            ForEach(wallpaperPaths, id: \.self) { path in
                                swatch(.wallpaper(path)) { Thumbnail(url: URL(fileURLWithPath: path)) }
                                    .help(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
                            }
                            Button(action: model.chooseWallpaper) {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4]))
                                    .foregroundStyle(.secondary)
                                    .overlay(Image(systemName: "plus").foregroundStyle(.secondary))
                                    .frame(width: 56, height: 40)
                            }
                            .buttonStyle(.plain)
                            .help("Choose an image...")
                        }
                    }

                    section("Solid") {
                        HStack(spacing: 8) {
                            swatch(.solid(solidColor)) { Color(nsColor: solidColor.nsColor) }
                            ColorPicker("", selection: solidBinding, supportsOpacity: false).labelsHidden()
                            swatch(.none) { Checkerboard() }
                                .help("Transparent")
                        }
                    }

                    Divider()

                    slider("Padding", value: $model.style.padding, range: 0...0.4, format: { "\(Int($0 * 100))%" })
                    slider("Corner radius", value: $model.style.cornerRadius, range: 0...40, format: { "\(Int($0)) pt" })
                    slider("Shadow", value: $model.style.shadow, range: 0...1, format: { "\(Int($0 * 100))%" })

                    Toggle("Balance", isOn: $model.style.balance)
                        .help("Trim uneven blank margins so the content sits centred")

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Aspect ratio").font(.subheadline).foregroundStyle(.secondary)
                        Picker("", selection: $model.style.aspect) {
                            ForEach(AspectRatio.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                }
                .padding(16)
                .padding(.top, 20)
            }

            Divider()
            HStack {
                Button("Done", action: close).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save", action: model.save).keyboardShortcut("s")
                Button("Copy", action: model.copy)
                    .keyboardShortcut("c")
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
            // Cmd-Shift-S: Save As.
            .background(Button("", action: model.saveAs).keyboardShortcut("s", modifiers: [.command, .shift]).hidden())
        }
    }

    private var wallpaperPaths: [String] {
        var paths = Wallpapers.builtIn.map(\.path)
        if case .wallpaper(let custom) = model.style.background, !paths.contains(custom) { paths.insert(custom, at: 0) }
        return paths
    }

    private var solidColor: RGB {
        if case .solid(let c) = model.style.background { return c }
        return UserDefaults.standard.data(forKey: "lastSolid").flatMap { try? JSONDecoder().decode(RGB.self, from: $0) } ?? RGB(0x1E1E1E)
    }

    private var solidBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: solidColor.nsColor) },
            set: { color in
                let rgb = RGB(NSColor(color))
                UserDefaults.standard.set(try? JSONEncoder().encode(rgb), forKey: "lastSolid")
                model.style.background = .solid(rgb)
            }
        )
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            content()
        }
    }

    private func swatch<Content: View>(_ background: Background, @ViewBuilder content: () -> Content) -> some View {
        let selected = model.style.background == background
        return Button { model.style.background = background } label: {
            content()
                .frame(width: 56, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 2.5 : 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text(format(value.wrappedValue)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }
}

private struct GradientSwatch: View {
    let preset: GradientPreset

    var body: some View {
        let a = preset.angle * .pi / 180
        // SwiftUI's y axis points down; the preset angle is counter-clockwise from +x.
        LinearGradient(
            colors: preset.colors.map { Color(nsColor: $0.nsColor) },
            startPoint: UnitPoint(x: 0.5 - cos(a) / 2, y: 0.5 + sin(a) / 2),
            endPoint: UnitPoint(x: 0.5 + cos(a) / 2, y: 0.5 - sin(a) / 2)
        )
    }
}

/// Command Line Tools ship without the SwiftUI macro plugin, so `@State` is unavailable; use a loader object.
private final class ThumbnailLoader: ObservableObject {
    @Published var image: CGImage?

    func load(_ url: URL) async {
        let image = await Task.detached(priority: .utility) { Wallpapers.image(at: url, maxPixel: 160) }.value
        await MainActor.run { self.image = image }
    }
}

private struct Thumbnail: View {
    let url: URL
    @StateObject private var loader = ThumbnailLoader()

    var body: some View {
        ZStack {
            Color.gray.opacity(0.2)
            if let image = loader.image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            }
        }
        .task(id: url) { await loader.load(url) }
    }
}

private struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 8
            for row in 0..<Int(ceil(size.height / s)) {
                for col in 0..<Int(ceil(size.width / s)) where (row + col).isMultiple(of: 2) {
                    ctx.fill(Path(CGRect(x: CGFloat(col) * s, y: CGFloat(row) * s, width: s, height: s)), with: .color(.gray.opacity(0.35)))
                }
            }
        }
        .background(Color.white)
    }
}
