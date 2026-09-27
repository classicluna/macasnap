import AppKit

@MainActor enum ThumbnailPanel {
    private static var panel: NSPanel?

    /// Shows a floating preview of a finished capture in the bottom-right of the screen with the mouse, replacing any current one.
    static func show(image: CGImage, scale: CGFloat, onOpen: @escaping () -> Void) {
        dismiss()

        let view = ThumbnailView(image: image, scale: scale, onOpen: onOpen)
        let panel = NSPanel(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = view
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        self.panel = panel

        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 20, y: visible.minY + 20))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(NSPoint(x: panel.frame.minX, y: panel.frame.minY + 8))
        }
        view.startTimer()
    }

    static func dismiss() {
        guard let current = panel else { return }
        (current.contentView as? ThumbnailView)?.stopTimer()
        panel = nil
        current.contentView = nil
        current.close()
    }
}

@MainActor private final class ThumbnailView: NSView, NSDraggingSource {
    private let image: NSImage
    private let captureImage: CGImage
    private let scale: CGFloat
    private let onOpen: () -> Void
    private var timer: Timer?
    private var tracking: NSTrackingArea?
    private var mouseDownPoint: NSPoint?
    private var closeButton: NSButton!
    private let imageRect: CGRect

    init(image: CGImage, scale: CGFloat, onOpen: @escaping () -> Void) {
        self.captureImage = image
        self.scale = scale
        self.image = Renderer.nsImage(image, scale: scale)
        self.onOpen = onOpen
        let size = self.image.size
        let width: CGFloat = 220
        let height = max(110, width * size.height / max(1, size.width))
        self.imageRect = CGRect(x: 0, y: 0, width: width, height: height)
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        closeButton = NSButton(title: "x", target: self, action: #selector(closePreview))
        closeButton.bezelStyle = .circular
        closeButton.isBordered = false
        closeButton.font = .systemFont(ofSize: 12, weight: .bold)
        closeButton.contentTintColor = .white
        closeButton.wantsLayer = true
        closeButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        closeButton.isHidden = true
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        closeButton.frame = CGRect(x: bounds.maxX - 28, y: bounds.maxY - 28, width: 20, height: 20)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking!)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1)
    }

    func startTimer() {
        resetTimer()
    }
    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func resetTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { _ in
            MainActor.assumeIsolated { ThumbnailPanel.dismiss() }
        }
    }

    override func mouseEntered(with event: NSEvent) {
        timer?.invalidate()
        timer = nil
        closeButton.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        closeButton.isHidden = true
        resetTimer()
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 4,
              let png = Renderer.pngData(captureImage, scale: scale) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(Output.defaultFileName())
        do {
            try png.write(to: url, options: .atomic)
        } catch {
            NSLog("Macasnap: thumbnail drag image failed: \(error)")
            mouseDownPoint = nil
            return
        }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        timer?.invalidate()
        timer = nil
        beginDraggingSession(with: [item], event: event, source: self)
        mouseDownPoint = nil
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        mouseDownPoint = nil
        let point = convert(event.locationInWindow, from: nil)
        if hypot(point.x - start.x, point.y - start.y) <= 4, !closeButton.frame.contains(point) {
            onOpen()
            ThumbnailPanel.dismiss()
        }
    }

    @objc private func closePreview() {
        ThumbnailPanel.dismiss()
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation != [] { ThumbnailPanel.dismiss() } else { resetTimer() }
    }
}
