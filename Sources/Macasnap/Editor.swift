import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model

@MainActor
final class EditorModel: ObservableObject {
    /// Where the capture sits inside the rendered canvas, for mapping preview clicks to capture pixels.
    struct Geometry {
        var canvas: CGSize
        /// Snippet rect in canvas pixels, bottom-left origin.
        var snip: CGRect
        /// Top-left of the balance crop within the original capture.
        var cropOrigin: CGPoint

        /// Point in a view of `viewSize` showing the whole canvas (top-left origin) to capture pixels.
        func capturePoint(_ p: CGPoint, viewSize: CGSize) -> CGPoint {
            let k = canvas.width / max(viewSize.width, 1)
            let snipTop = canvas.height - snip.maxY
            return CGPoint(x: p.x * k - snip.minX + cropOrigin.x, y: p.y * k - snipTop + cropOrigin.y)
        }

        func viewPoint(_ c: CGPoint, viewSize: CGSize) -> CGPoint {
            let k = max(viewSize.width, 1) / canvas.width
            let snipTop = canvas.height - snip.maxY
            return CGPoint(x: (c.x - cropOrigin.x + snip.minX) * k, y: (c.y - cropOrigin.y + snipTop) * k)
        }

        func viewRect(_ r: CGRect, viewSize: CGSize) -> CGRect {
            let a = viewPoint(r.origin, viewSize: viewSize), b = viewPoint(CGPoint(x: r.maxX, y: r.maxY), viewSize: viewSize)
            return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
        }
    }

    struct RenderResult {
        let image: CGImage
        let geometry: Geometry
    }

    /// A text annotation being typed; `id` gives each entry field its own identity.
    struct PendingText: Equatable {
        let id = UUID()
        let point: CGPoint
    }

    @Published var style: Style {
        didSet {
            guard style != oldValue else { return }
            style.save()
            rerender()
        }
    }
    @Published private(set) var annotations: [Annotation] = [] {
        didSet { if annotations != oldValue { rerender() } }
    }
    @Published private(set) var undoStack: [[Annotation]] = []
    @Published var tool: AnnotationTool = .none {
        didSet { if tool != oldValue { finishText() } }
    }
    @Published var color: RGB {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(color), forKey: "annotationColor") }
    }
    @Published private(set) var draft: Annotation?
    @Published private(set) var pendingText: PendingText?
    @Published private(set) var result: RenderResult?
    @Published private(set) var isRedacting = false
    @Published var toast: String?

    let snapshot: Snapshot
    /// Balance crop, computed once from the unannotated capture (outer nil = not computed yet).
    private var crop: CGRect??
    /// Live contents of the text field, so clicking elsewhere still commits it (and the field can grow).
    @Published var textDraft = ""
    /// File written by "Save After Capture"; later edits overwrite it.
    private var autoSavedURL: URL?
    private var renderTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    init(snapshot: Snapshot, style: Style) {
        self.snapshot = snapshot
        self.style = style
        color = UserDefaults.standard.data(forKey: "annotationColor").flatMap { try? JSONDecoder().decode(RGB.self, from: $0) }
            ?? AnnotationPalette.colors[0]
        result = Self.render(snapshot, crop: &crop, annotations: [], style: style)
    }

    var scale: CGFloat { snapshot.scale }
    var rendered: CGImage? { result?.image }

    /// Full pipeline: annotations, optional balance crop, then background composition.
    nonisolated static func render(_ snap: Snapshot, crop: inout CGRect??, annotations: [Annotation], style: Style) -> RenderResult? {
        var image = Annotator.flatten(snap.image, annotations: annotations, scale: snap.scale)
        var origin = CGPoint.zero
        if style.balance {
            if crop == nil { crop = .some(Renderer.balanceRect(snap.image)) }
            if case .some(.some(let rect)) = crop, let cropped = image.cropping(to: rect) {
                image = cropped
                origin = rect.origin
            }
        }
        let wallpaper = Wallpapers.url(for: style.background).flatMap { Wallpapers.image(at: $0, maxPixel: 4096) }
        guard let output = Renderer.render(Snapshot(image: image, scale: snap.scale), style: style, wallpaper: wallpaper) else { return nil }
        let layout = Renderer.layout(snippet: CGSize(width: image.width, height: image.height), style: style)
        return RenderResult(image: output, geometry: Geometry(canvas: layout.canvas, snip: layout.snip, cropOrigin: origin))
    }

    private func rerender() {
        renderTask?.cancel()
        let snap = snapshot, style = style, annotations = annotations, cachedCrop = crop
        renderTask = Task.detached(priority: .userInitiated) { [weak self] in
            var crop = cachedCrop
            let result = EditorModel.render(snap, crop: &crop, annotations: annotations, style: style)
            await self?.finishRender(result, crop: crop)
        }
    }

    private func finishRender(_ result: RenderResult?, crop: CGRect??) {
        guard !Task.isCancelled else { return }
        self.crop = crop
        self.result = result
        scheduleSync()
    }

    // MARK: Delivery

    /// Clipboard and auto-save for a fresh capture.
    func deliverInitial() {
        guard let rendered else { return }
        if Prefs.copyOnCapture { Output.copy(rendered, scale: scale) }
        if Prefs.saveOnCapture { autoSavedURL = Output.save(rendered, scale: scale) }
    }

    /// Keeps the clipboard and the auto-saved file in step with edits (debounced).
    private func scheduleSync() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self, let rendered = self.rendered else { return }
            if Prefs.copyOnCapture { Output.copy(rendered, scale: self.scale) }
            if let url = self.autoSavedURL { Output.save(rendered, scale: self.scale, to: url) }
        }
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

    // MARK: Annotation editing

    private func commit(_ new: [Annotation]) {
        guard !new.isEmpty else { return }
        undoStack.append(annotations)
        annotations += new
    }

    func undo() {
        finishText()
        guard let previous = undoStack.popLast() else { return }
        annotations = previous
    }

    func clearAnnotations() {
        guard !annotations.isEmpty else { return }
        undoStack.append(annotations)
        annotations = []
    }

    /// Drag in capture pixels from `start` to `current` with the current tool.
    func dragChanged(from start: CGPoint, to current: CGPoint) {
        let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                          width: abs(current.x - start.x), height: abs(current.y - start.y))
        let kind: Annotation.Kind
        switch tool {
        case .none, .text: return
        case .arrow: kind = .arrow(from: start, to: current)
        case .box: kind = .box(rect)
        case .highlight: kind = .highlight(rect)
        case .redact: kind = .redact(rect)
        }
        draft = Annotation(kind: kind, color: color)
    }

    func dragEnded(at point: CGPoint) {
        if tool == .text {
            finishText()
            textDraft = ""
            pendingText = PendingText(point: point)
            return
        }
        defer { draft = nil }
        guard let draft else { return }
        let minSize = 4 * scale
        switch draft.kind {
        case .arrow(let a, let b) where hypot(b.x - a.x, b.y - a.y) < minSize: return
        case .box(let r), .highlight(let r), .redact(let r):
            if r.width < minSize || r.height < minSize { return }
        default: break
        }
        commit([draft])
    }

    /// Commits the text being typed, if any.
    func finishText() {
        guard let pending = pendingText else { return }
        pendingText = nil
        let text = textDraft.trimmingCharacters(in: .whitespaces)
        textDraft = ""
        if !text.isEmpty { commit([Annotation(kind: .text(text, at: pending.point), color: color)]) }
    }

    func cancelText() {
        pendingText = nil
        textDraft = ""
    }

    func autoRedact() {
        guard !isRedacting else { return }
        finishText()
        isRedacting = true
        let image = snapshot.image
        Task { [weak self] in
            let rects = await Redactor.sensitiveRegions(in: image)
            guard let self else { return }
            self.isRedacting = false
            self.commit(rects.map { Annotation(kind: .redact($0), color: self.color) })
            self.show(rects.isEmpty ? "Nothing sensitive found" : "Redacted \(rects.count) item\(rects.count == 1 ? "" : "s")")
        }
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
            if let result = model.result {
                let image = Image(decorative: result.image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                Group {
                    if model.tool == .none {
                        image.onDrag { model.dragProvider() }
                    } else {
                        image.overlay(AnnotationCanvas(model: model, geometry: result.geometry))
                    }
                }
                .shadow(color: .black.opacity(0.15), radius: 8)
                .padding(EdgeInsets(top: 72, leading: 32, bottom: 32, trailing: 32))
            }
            VStack {
                AnnotationToolbar(model: model).padding(.top, 30)
                Spacer()
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

// MARK: - Annotation views

private struct AnnotationToolbar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AnnotationTool.allCases) { tool in
                Button { model.tool = tool } label: {
                    Image(systemName: tool.symbol)
                        .frame(width: 30, height: 24)
                        .background(model.tool == tool ? Color.accentColor.opacity(0.3) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tool.label)
            }
            Divider().frame(height: 18).padding(.horizontal, 4)
            ForEach(AnnotationPalette.colors, id: \.self) { c in
                Button { model.color = c } label: {
                    Circle()
                        .fill(Color(nsColor: c.nsColor))
                        .frame(width: 14, height: 14)
                        .overlay(Circle().strokeBorder(model.color == c ? Color.accentColor : Color.primary.opacity(0.3), lineWidth: model.color == c ? 2 : 1))
                        .frame(width: 20, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider().frame(height: 18).padding(.horizontal, 4)
            Button(action: model.autoRedact) {
                Group {
                    if model.isRedacting { ProgressView().controlSize(.small) } else { Image(systemName: "wand.and.stars") }
                }
                .frame(width: 30, height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Auto-redact emails, phone numbers, card numbers, IPs and keys")
            Button(action: model.undo) {
                Image(systemName: "arrow.uturn.backward").frame(width: 30, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("z")
            .disabled(model.undoStack.isEmpty)
            .help("Undo (Cmd-Z)")
            Button(action: model.clearAnnotations) {
                Image(systemName: "trash").frame(width: 30, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.annotations.isEmpty)
            .help("Remove all markup")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// Transparent layer over the preview that turns drags into annotations.
private struct AnnotationCanvas: View {
    @ObservedObject var model: EditorModel
    let geometry: EditorModel.Geometry

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                model.dragChanged(from: geometry.capturePoint(v.startLocation, viewSize: geo.size),
                                                  to: geometry.capturePoint(v.location, viewSize: geo.size))
                            }
                            .onEnded { v in model.dragEnded(at: geometry.capturePoint(v.location, viewSize: geo.size)) }
                    )
                if let draft = model.draft {
                    DraftView(annotation: draft, geometry: geometry, viewSize: geo.size, scale: model.scale)
                        .allowsHitTesting(false)
                }
                if let pending = model.pendingText {
                    let k = geo.size.width / geometry.canvas.width
                    let p = geometry.viewPoint(pending.point, viewSize: geo.size)
                    TextEntryField(model: model, zoom: k)
                        .id(pending.id)
                        .frame(width: textFieldWidth(zoom: k), alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .offset(x: p.x - 2, y: p.y - 2)
                }
            }
        }
        .onHover { inside in
            if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
        }
    }

    private func textFieldWidth(zoom: CGFloat) -> CGFloat {
        guard let font = Annotator.textAttributes(color: model.color, scale: model.scale)[.font] as? NSFont else { return 200 }
        let scaled = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * zoom) ?? font
        let text = model.textDraft.isEmpty ? "Type, then Return" : model.textDraft
        return (text as NSString).size(withAttributes: [.font: scaled]).width + 24
    }
}

/// Live preview of the annotation being dragged out.
private struct DraftView: View {
    let annotation: Annotation
    let geometry: EditorModel.Geometry
    let viewSize: CGSize
    let scale: CGFloat

    var body: some View {
        let color = Color(nsColor: annotation.color.nsColor)
        let k = viewSize.width / geometry.canvas.width
        let lw = AnnotationPalette.lineWidth(scale: scale) * k
        switch annotation.kind {
        case .arrow(let from, let to):
            Path(Annotator.arrowPath(from: geometry.viewPoint(from, viewSize: viewSize),
                                     to: geometry.viewPoint(to, viewSize: viewSize), lineWidth: lw))
                .fill(color)
        case .box(let r):
            Path(roundedRect: geometry.viewRect(r, viewSize: viewSize), cornerRadius: lw * 1.5)
                .stroke(color, lineWidth: lw)
        case .highlight(let r):
            Path(geometry.viewRect(r, viewSize: viewSize)).fill(color.opacity(0.35))
        case .redact(let r):
            let rect = geometry.viewRect(r, viewSize: viewSize)
            Path(rect).fill(Color.gray.opacity(0.6))
            Path(rect).stroke(Color.white, style: StrokeStyle(lineWidth: 1, dash: [4]))
        case .text:
            EmptyView()
        }
    }
}

/// Borderless text field that grabs focus when it appears. Return commits, Esc cancels,
/// clicking elsewhere commits.
private struct TextEntryField: NSViewRepresentable {
    let model: EditorModel
    let zoom: CGFloat

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.black.withAlphaComponent(0.25)
        field.focusRingType = .none
        field.placeholderString = "Type, then Return"
        field.delegate = context.coordinator
        apply(to: field)
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.model = model
        apply(to: field)
    }

    private func apply(to field: NSTextField) {
        let attrs = Annotator.textAttributes(color: model.color, scale: model.scale)
        if let font = attrs[.font] as? NSFont {
            field.font = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * zoom)
        }
        field.textColor = model.color.nsColor
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var model: EditorModel

        init(model: EditorModel) { self.model = model }

        func controlTextDidChange(_ notification: Notification) {
            model.textDraft = (notification.object as? NSTextField)?.stringValue ?? ""
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                model.finishText()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                model.cancelText()
                return true
            default:
                return false
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) { model.finishText() }
    }
}

private struct Sidebar: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var updater = Updater.shared
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

            if let release = updater.available {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
                    Text("Macasnap \(release.version) is available").font(.callout)
                    Spacer()
                    Button(updater.isInstalling ? "Updating..." : "Update", action: updater.installAvailable)
                        .disabled(updater.isInstalling)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.08))
            }
            Divider()
            HStack {
                // Esc belongs to the text field while typing a label.
                Button("Done", action: close).keyboardShortcut(.cancelAction).disabled(model.pendingText != nil)
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
