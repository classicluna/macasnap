import AppKit
import ScreenCaptureKit

/// In-process replacement for `screencapture -i`: freezes every display with ScreenCaptureKit,
/// shows a full-screen overlay to drag out an area (Space toggles window mode, Esc cancels),
/// then crops the frozen frame or captures the picked window on its own.
@MainActor
final class CaptureSession {
    enum Mode { case area, window }
    enum Outcome {
        case captured(Snapshot)
        case cancelled
        case failed(Error)
    }

    private static var current: CaptureSession?

    static var isActive: Bool { current != nil }

    static func start(_ mode: Mode, completion: @escaping (Outcome) -> Void) {
        guard current == nil else { return }
        let session = CaptureSession(mode: mode, completion: completion)
        current = session
        Task { await session.begin() }
    }

    fileprivate(set) var mode: Mode
    fileprivate var hovered: WindowTarget?
    private let completion: (Outcome) -> Void
    private var overlays: [NSWindow] = []
    private var views: [OverlayView] = []
    private var targets: [WindowTarget] = [] // front to back
    private var scWindows: [CGWindowID: SCWindow] = [:]

    struct WindowTarget: Equatable {
        let id: CGWindowID
        /// Global display coordinates, top-left origin.
        let frame: CGRect
    }

    private init(mode: Mode, completion: @escaping (Outcome) -> Void) {
        self.mode = mode
        self.completion = completion
    }

    private func begin() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            scWindows = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
            targets = Self.orderedWindowTargets().filter { scWindows[$0.id] != nil }

            var frozen: [(NSScreen, CGImage)] = []
            for screen in NSScreen.screens {
                guard let id = screen.displayID, let display = content.displays.first(where: { $0.displayID == id }) else { continue }
                let config = SCStreamConfiguration()
                config.width = Int(CGFloat(display.width) * screen.backingScaleFactor)
                config.height = Int(CGFloat(display.height) * screen.backingScaleFactor)
                config.showsCursor = false
                let filter = SCContentFilter(display: display, excludingWindows: [])
                frozen.append((screen, try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)))
            }
            guard !frozen.isEmpty else { return finish(.cancelled) }
            showOverlays(frozen)
        } catch {
            finish(.failed(error))
        }
    }

    /// On-screen normal windows (layer 0) of other apps, front to back.
    private static func orderedWindowTargets() -> [WindowTarget] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return info.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                  ((w[kCGWindowAlpha as String] as? Double) ?? 1) > 0,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict),
                  frame.width > 40, frame.height > 40 else { return nil }
            return WindowTarget(id: id, frame: frame)
        }
    }

    private func showOverlays(_ frozen: [(NSScreen, CGImage)]) {
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        for (screen, image) in frozen {
            let view = OverlayView(session: self, screen: screen, image: image)
            let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: false)
            window.level = .screenSaver
            window.isOpaque = true
            window.hasShadow = false
            window.animationBehavior = .none
            window.isReleasedWhenClosed = false
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.contentView = view
            window.orderFrontRegardless()
            if screen.frame.contains(mouse) {
                window.makeKey()
                window.makeFirstResponder(view)
            }
            overlays.append(window)
            views.append(view)
        }
        if NSApp.keyWindow == nil, let first = overlays.first {
            first.makeKey()
            first.makeFirstResponder(first.contentView)
        }
        updateHover(globalPoint: Self.globalTopLeft(mouse))
        applyCursor()
    }

    // MARK: Events from overlay views

    fileprivate func toggleMode() {
        mode = mode == .area ? .window : .area
        views.forEach { $0.selection = nil }
        updateHover(globalPoint: Self.globalTopLeft(NSEvent.mouseLocation))
        applyCursor()
        redraw()
    }

    fileprivate func updateHover(globalPoint: CGPoint) {
        let target = mode == .window ? targets.first { $0.frame.contains(globalPoint) } : nil
        if target != hovered {
            hovered = target
            redraw()
        }
    }

    fileprivate func applyCursor() {
        (mode == .area ? NSCursor.crosshair : NSCursor.pointingHand).set()
    }

    fileprivate func redraw() { views.forEach { $0.needsDisplay = true } }

    fileprivate func cancel() { finish(.cancelled) }

    fileprivate func captured(_ image: CGImage, scale: CGFloat) {
        finish(.captured(Snapshot(image: image, scale: scale)))
    }

    fileprivate func captureHoveredWindow() {
        guard let target = hovered, let window = scWindows[target.id] else { return }
        closeOverlays()
        Task {
            do {
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let scale = CGFloat(filter.pointPixelScale)
                let config = SCStreamConfiguration()
                config.width = Int(filter.contentRect.width * scale)
                config.height = Int(filter.contentRect.height * scale)
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                finish(.captured(Snapshot(image: image, scale: scale)))
            } catch {
                finish(.failed(error))
            }
        }
    }

    private func closeOverlays() {
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        views.removeAll()
        NSCursor.arrow.set()
    }

    private func finish(_ outcome: Outcome) {
        closeOverlays()
        Self.current = nil
        completion(outcome)
    }

    /// Cocoa global point (bottom-left origin) to CG global point (top-left origin).
    static func globalTopLeft(_ p: NSPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: primaryHeight - p.y)
    }
}

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class OverlayView: NSView {
    unowned let session: CaptureSession
    let screen: NSScreen
    let image: CGImage
    var selection: NSRect? { didSet { needsDisplay = true } }
    private var dragStart: NSPoint?

    init(session: CaptureSession, screen: NSScreen, image: CGImage) {
        self.session = session
        self.screen = screen
        self.image = image
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    private func global(_ local: NSPoint) -> CGPoint {
        CaptureSession.globalTopLeft(NSPoint(x: screen.frame.minX + local.x, y: screen.frame.minY + local.y))
    }

    /// CG global rect (top-left origin) to this view's coordinates.
    private func local(_ rect: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoaY = primaryHeight - rect.maxY
        return NSRect(x: rect.minX - screen.frame.minX, y: cocoaY - screen.frame.minY, width: rect.width, height: rect.height)
    }

    override func mouseEntered(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        session.applyCursor()
    }

    override func mouseMoved(with event: NSEvent) {
        session.applyCursor()
        session.updateHover(globalPoint: global(convert(event.locationInWindow, from: nil)))
    }

    override func mouseDown(with event: NSEvent) {
        guard session.mode == .area else { return }
        dragStart = clamp(convert(event.locationInWindow, from: nil))
        selection = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard session.mode == .area, let start = dragStart else { return }
        let p = clamp(convert(event.locationInWindow, from: nil))
        selection = NSRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
    }

    override func mouseUp(with event: NSEvent) {
        switch session.mode {
        case .window:
            session.captureHoveredWindow()
        case .area:
            defer { dragStart = nil }
            guard let rect = selection?.integral, rect.width >= 4, rect.height >= 4 else {
                selection = nil
                return
            }
            let scale = screen.backingScaleFactor
            let pixelRect = CGRect(x: rect.minX * scale, y: (bounds.height - rect.maxY) * scale,
                                   width: rect.width * scale, height: rect.height * scale).integral
            guard let cropped = image.cropping(to: pixelRect) else { return session.cancel() }
            session.captured(cropped, scale: scale)
        }
    }

    override func rightMouseDown(with event: NSEvent) { session.cancel() }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: session.cancel() // Esc
        case 49 where dragStart == nil: session.toggleMode() // Space
        default: break
        }
    }

    private func clamp(_ p: NSPoint) -> NSPoint {
        NSPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: bounds)

        switch session.mode {
        case .area:
            guard let rect = selection else { return }
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
            ctx.addRect(bounds)
            ctx.addRect(rect)
            ctx.fillPath(using: .evenOdd)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(rect.insetBy(dx: -0.5, dy: -0.5))
            drawLabel("\(Int(rect.width)) \u{00D7} \(Int(rect.height))", near: rect)
        case .window:
            // Dim everything except the hovered window, which gets a blue tint like the system tool.
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.2).cgColor)
            ctx.addRect(bounds)
            if let target = session.hovered { ctx.addRect(local(target.frame)) }
            ctx.fillPath(using: .evenOdd)
            if let target = session.hovered {
                ctx.setFillColor(NSColor.systemBlue.withAlphaComponent(0.25).cgColor)
                ctx.fill(local(target.frame))
            }
        }
    }

    private func drawLabel(_ text: String, near rect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let pad: CGFloat = 6
        var origin = NSPoint(x: rect.maxX - size.width - 2 * pad, y: rect.minY - size.height - 2 * pad - 6)
        if origin.y < 0 { origin.y = rect.minY + 6 }
        origin.x = max(origin.x, 0)
        let box = NSRect(x: origin.x, y: origin.y, width: size.width + 2 * pad, height: size.height + 2 * pad)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(at: NSPoint(x: box.minX + pad, y: box.minY + pad), withAttributes: attrs)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
