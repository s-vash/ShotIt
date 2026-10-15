import AppKit

/// Always-on-top floating screenshot.
/// Drag to move · scroll to resize · ⌥-scroll for opacity · double-click or Esc to close · right-click for more.
final class PinWindowController: NSWindowController, NSWindowDelegate {
    private static var pins: [PinWindowController] = []

    let shot: Screenshot
    private var zoom: CGFloat = 1

    static func pin(_ shot: Screenshot, at origin: CGPoint? = nil) {
        let wc = PinWindowController(shot: shot, origin: origin)
        pins.append(wc)
        wc.window?.orderFrontRegardless()
        wc.window?.makeKey()
    }

    static func closeAll() { for p in pins { p.close() } }

    init(shot: Screenshot, origin: CGPoint?) {
        self.shot = shot
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        // Large captures start scaled down so they fit comfortably.
        let fit = shot.pointSize.fitting(in: CGSize(width: vf.width * 0.6, height: vf.height * 0.6))
        let o = origin ?? CGPoint(x: vf.midX - fit.width / 2, y: vf.midY - fit.height / 2)
        let window = PinWindow(contentRect: CGRect(origin: o, size: fit), styleMask: [.borderless, .resizable],
                               backing: .buffered, defer: false)
        window.level = .floating
        window.hasShadow = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.contentAspectRatio = shot.pointSize
        super.init(window: window)
        window.delegate = self
        zoom = fit.width / shot.pointSize.width

        let view = PinView(frame: CGRect(origin: .zero, size: fit))
        view.image = shot.nsImage
        view.autoresizingMask = [.width, .height]
        view.controller = self
        window.contentView = view
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        PinWindowController.pins.removeAll { $0 === self }
    }

    func resize(by factor: CGFloat) {
        guard let window else { return }
        let newZoom = min(max(zoom * factor, 0.1), 4)
        let size = CGSize(width: shot.pointSize.width * newZoom, height: shot.pointSize.height * newZoom)
        guard size.width >= 40, size.height >= 30 else { return }
        zoom = newZoom
        let f = window.frame
        // Keep the top-left corner anchored.
        window.setFrame(CGRect(x: f.minX, y: f.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    func setZoom(_ z: CGFloat) { resize(by: z / zoom) }

    func adjustOpacity(by delta: CGFloat) {
        guard let window else { return }
        window.alphaValue = min(1, max(0.15, window.alphaValue + delta))
    }

    @objc func copyImage(_ sender: Any?) {
        Exporter.copy(shot.image, scale: shot.scale)
        Toast.show("Copied to the clipboard")
    }

    @objc func saveImage(_ sender: Any?) {
        Exporter.saveAs(shot.image, scale: shot.scale, date: shot.date, window: nil)
    }

    @objc func editImage(_ sender: Any?) {
        EditorWindowController.open(shot)
    }

    @objc func setOpacity(_ sender: NSMenuItem) {
        window?.alphaValue = CGFloat(sender.tag) / 100
    }

    @objc func actualSize(_ sender: Any?) { setZoom(1) }

    @objc func closePin(_ sender: Any?) { close() }

    func contextMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(withTitle: "Copy", action: #selector(copyImage(_:)), keyEquivalent: "c").target = self
        m.addItem(withTitle: "Save As…", action: #selector(saveImage(_:)), keyEquivalent: "s").target = self
        m.addItem(withTitle: "Open in Editor", action: #selector(editImage(_:)), keyEquivalent: "e").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Actual Size", action: #selector(actualSize(_:)), keyEquivalent: "0").target = self
        let opacity = NSMenu()
        for v in [100, 75, 50, 25] {
            let i = opacity.addItem(withTitle: "\(v)%", action: #selector(setOpacity(_:)), keyEquivalent: "")
            i.tag = v
            i.target = self
            i.state = Int(((window?.alphaValue ?? 1) * 100).rounded()) == v ? .on : .off
        }
        let oi = m.addItem(withTitle: "Opacity", action: nil, keyEquivalent: "")
        m.setSubmenu(opacity, for: oi)
        m.addItem(.separator())
        m.addItem(withTitle: "Close", action: #selector(closePin(_:)), keyEquivalent: "w").target = self
        return m
    }
}

private final class PinWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class PinView: NSView {
    weak var controller: PinWindowController?
    var image: NSImage?
    private var hover = false
    private var area: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .high
        image?.draw(in: bounds)
        if hover {
            NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
            let p = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
            p.lineWidth = 1
            p.stroke()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        if event.clickCount == 2 { controller?.close(); return }
        window?.performDrag(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 50 : event.scrollingDeltaY / 5
        guard dy != 0 else { return }
        if event.modifierFlags.contains(.option) {
            controller?.adjustOpacity(by: dy * 0.1)
        } else {
            controller?.resize(by: 1 + max(-0.3, min(0.3, dy * 0.1)))
        }
    }

    override func magnify(with event: NSEvent) { controller?.resize(by: 1 + event.magnification) }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = controller?.contextMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (flags, event.charactersIgnoringModifiers?.lowercased() ?? "") {
        case (.command, "c"): controller?.copyImage(nil)
        case (.command, "s"): controller?.saveImage(nil)
        case (.command, "e"): controller?.editImage(nil)
        case (.command, "w"): controller?.close()
        case (.command, "0"): controller?.actualSize(nil)
        default:
            if event.keyCode == 53 { controller?.close() } else { super.keyDown(with: event) }
        }
    }
}
